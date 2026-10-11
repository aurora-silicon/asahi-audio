-- SPDX-License-Identifier: MIT
--
-- Restore a node's volume and mute state, and log every change to them.
--
-- For nodes that set asahi.restore-props = true, this script stores and
-- restores the channel volumes and mute state in place of WirePlumber's
-- stream state, which the node turns off with state.restore-props = false.
--
-- Each time such a node is created, it gets its stored channel volumes and
-- mute state as they are.  The first time, it uses the ones WirePlumber's
-- stream state had stored for the node.  A stored volume that is missing,
-- has the wrong number of channels or holds a value that is not a number
-- from 0 to 1 is ignored, and the node gets state.default-volume instead.
--
-- Every change to the volume or mute state of such a node is logged as one
-- notice line per burst of changes (changes less than half a second apart):
-- the values before and after, and where the change came from.  PipeWire
-- does not say which client set a parameter.  The line says whether this
-- script's restore made the change; otherwise it lists the PipeWire clients
-- that connected shortly before, which names one-shot tools (wpctl, pactl,
-- scripts).  A change made through a long-running client, such as a desktop
-- shell talking to pipewire-pulse, shows no new client.
-- External changes that return to their starting values still log their
-- count and peak volume. A burst with restore and external changes names
-- both origins; only unchanged bursts entirely due to restore are silent.

cutils = require ("common-utils")
log = Log.open_topic ("s-node")

ENABLE_PROP = "asahi.restore-props"
FALLBACK_DEFAULT = 0.027   -- 30 % on a cubic volume slider
BURST_MS = 500             -- changes closer than this are one log line
RECENT_CLIENT_US = 3000000 -- clients that connected this long before a change

state = State ("asahi-restore-volume")
state_table = state:load ()

-- per node id: { volumes, mute } last seen, the pending log line, and
-- whether this script's own restore is in flight
last_seen = {}
bursts = {}
restoring = {}

-- recently connected PipeWire clients: { time, name, pid }
recent_clients = {}

function restoreEnabled ()
  return Settings.get_boolean ("node.stream.restore-props")
end

function nodeKey (node)
  return node.properties ["node.name"]
end

function isVolume (v)
  return type (v) == "number" and v == v and v >= 0.0 and v <= 1.0
end

function parseRecord (value)
  local json = value and Json.Raw (value)
  if json and json:is_object () then
    return json:parse ()
  end
  return nil
end

function getStored (key)
  return key and parseRecord (state_table [key])
end

-- The record WirePlumber's stream state stored for the node before this
-- script took it over (same key as node/state-stream.lua).
wp_stream_state = nil

function getWirePlumberStored (node)
  if wp_stream_state == nil then
    wp_stream_state = State ("stream-properties"):load ()
  end
  local props = node.properties
  local class = (props ["media.class"] or ""):gsub ("^Stream/", "")
  for _, k in ipairs ({ "application.id", "application.name", "media.name",
      "node.name" }) do
    if props [k] then
      return parseRecord (wp_stream_state [class .. ":" .. k .. ":" .. props [k]])
    end
  end
  return nil
end

function channelCount (node, record)
  local n = tonumber (node.properties ["audio.channels"])
  if n and n >= 1 then
    return math.floor (n)
  end
  if record and type (record.channelVolumes) == "table" and
      #record.channelVolumes > 0 then
    return #record.channelVolumes
  end
  return 2
end

-- the record's channel volumes if they are usable for n channels, else nil
function validVolumes (record, n)
  local vols = record and record.channelVolumes
  if type (vols) ~= "table" or #vols ~= n then
    return nil
  end
  local out = {}
  for i = 1, n do
    if not isVolume (vols [i]) then
      return nil
    end
    out [i] = vols [i]
  end
  return out
end

-- channel volumes and mute state of the node as it reports them: the first
-- Props object with channel volumes is the converter's, which holds the
-- node's volume (the adapter lists it before the follower's)
function currentProps (node)
  for p in node:iterate_params ("Props") do
    local props = cutils.parseParam (p, "Props")
    if props and type (props.channelVolumes) == "table" and
        #props.channelVolumes > 0 then
      local vols = {}
      for _, v in ipairs (props.channelVolumes) do
        table.insert (vols, v)
      end
      return vols, props.mute
    end
  end
  return nil, nil
end

function volumeText (vols)
  if type (vols) ~= "table" or #vols == 0 then
    return "?"
  end
  local parts = {}
  for _, v in ipairs (vols) do
    -- linear channel volume as a desktop (cubic) slider shows it
    table.insert (parts, string.format ("%.2f", math.max (v, 0.0) ^ (1 / 3)))
  end
  local first = parts [1]
  for _, p in ipairs (parts) do
    if p ~= first then
      return table.concat (parts, "/")
    end
  end
  return first
end

function sameVolumes (a, b)
  if type (a) ~= "table" or type (b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if type (a [i]) ~= "number" or type (b [i]) ~= "number" or
        math.abs (a [i] - b [i]) > 1e-6 then
      return false
    end
  end
  return true
end

function valuesText (values)
  if type (values) ~= "table" then
    return tostring (values)
  end
  local parts = {}
  for _, v in ipairs (values) do
    table.insert (parts, tostring (v))
  end
  return "[" .. table.concat (parts, ", ") .. "]"
end

MAX_CLIENTS_LISTED = 6

function recentClientsText (since)
  local names = {}
  for _, c in ipairs (recent_clients) do
    if c.time >= since then
      table.insert (names, string.format ("%s (pid %s)", c.name, c.pid))
    end
  end
  if #names == 0 then
    return "no client connected just before"
  end
  -- the most recent ones
  while #names > MAX_CLIENTS_LISTED do
    table.remove (names, 1)
  end
  return "clients connected just before: " .. table.concat (names, ", ")
end

function flushBurst (id, label)
  local b = bursts [id]
  bursts [id] = nil
  local now = last_seen [id]
  if not b or not now then
    return
  end
  if b.external_count == 0 and sameVolumes (b.vols, now.vols) and
      b.mute == now.mute then
    return
  end
  local origin
  if b.external_count == 0 then
    origin = "this script's restore"
  elseif b.internal_count > 0 then
    origin = "restore and another client; " ..
        recentClientsText (b.start - RECENT_CLIENT_US)
  else
    origin = "another client; " .. recentClientsText (b.start - RECENT_CLIENT_US)
  end
  log:notice (string.format ("%s: volume %s -> %s, mute %s -> %s (%d change%s; %s; peak volume %s)",
      label, volumeText (b.vols), volumeText (now.vols), tostring (b.mute),
      tostring (now.mute), b.count, b.count == 1 and "" or "s", origin, volumeText (b.peak)))
end

-- clients that exist when the script starts did not just connect
clients_ready = false
clients_om = ObjectManager {
  Interest { type = "client" },
}
clients_om:connect ("installed", function ()
  clients_ready = true
end)
clients_om:connect ("object-added", function (_, client)
  local props = client.properties
  if not clients_ready or props ["wireplumber.daemon"] == "true" then
    return
  end
  local now = GLib.get_monotonic_time ()
  table.insert (recent_clients, {
    time = now,
    name = props ["application.name"] or props ["application.process.binary"] or "?",
    pid = props ["application.process.id"] or props ["pipewire.sec.pid"] or "?",
  })
  -- keep only what a burst can still refer to
  while #recent_clients > 0 and
      recent_clients [1].time < now - 2 * RECENT_CLIENT_US do
    table.remove (recent_clients, 1)
  end
end)
clients_om:activate ()

SimpleEventHook {
  name = "node/asahi-restore-volume",
  after = "node/restore-stream",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { ENABLE_PROP, "=", "true" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local key = nodeKey (node)
    local default = tonumber (node.properties ["state.default-volume"])
    if not isVolume (default) then
      default = FALLBACK_DEFAULT
    end

    local record = nil
    local source = "default (nothing stored)"
    if restoreEnabled () then
      record = getStored (key)
      source = "stored"
      if record == nil then
        record = getWirePlumberStored (node)
        source = "adopted from WirePlumber's stream state"
      end
      if record == nil then
        source = "default (nothing stored)"
      end
    end

    local n = channelCount (node, record)
    local vols = validVolumes (record, n)
    if vols == nil then
      if record ~= nil then
        log:notice (node, string.format (
            "%s: ignoring unusable stored volume %s", tostring (key),
            valuesText (record.channelVolumes)))
        source = "default (stored volume unusable)"
      end
      vols = {}
      for i = 1, n do
        vols [i] = default
      end
    end

    local props = {
      "Spa:Pod:Object:Param:Props", "Props",
      channelVolumes = Pod.Array ({ "Spa:Float", table.unpack (vols) }),
    }
    local mute = record and record.mute
    if type (mute) == "boolean" then
      props.mute = mute
    end

    log:info (node, string.format ("restoring %s: volume %s, mute %s (%s)",
        tostring (key), volumeText (vols), tostring (mute), source))
    -- what the node is about to report; a report of anything else before
    -- the restore lands is part of the restore's burst, which logs nothing
    -- when it ends where it started
    last_seen [node.id] = { vols = vols, mute = type (mute) == "boolean" and mute or false }
    restoring [node.id] = true
    node:set_param ("Props", Pod.Object (props))
  end
}:register ()

SimpleEventHook {
  name = "node/asahi-store-volume",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-params-changed" },
      Constraint { "event.subject.param-id", "=", "Props" },
      Constraint { ENABLE_PROP, "=", "true" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local key = nodeKey (node)
    local vols, mute = currentProps (node)
    if not key or not vols then
      return
    end

    -- log: one line per burst of changes
    local id = node.id
    local prev = last_seen [id]
    last_seen [id] = { vols = vols, mute = mute }
    if prev and not (sameVolumes (prev.vols, vols) and prev.mute == mute) then
      local b = bursts [id]
      if not b then
        b = { vols = prev.vols, mute = prev.mute, count = 0,
              start = GLib.get_monotonic_time (), internal_count = 0,
              external_count = 0, peak = { table.unpack (prev.vols) } }
        bursts [id] = b
      else
        b.source:destroy ()
      end
      b.count = b.count + 1
      if restoring [id] == true then
        b.internal_count = b.internal_count + 1
      else
        b.external_count = b.external_count + 1
      end
      for i, v in ipairs (vols) do
        b.peak [i] = math.max (b.peak [i] or v, v)
      end
      b.source = Core.timeout_add (BURST_MS, function ()
        flushBurst (id, key)
      end)
    end
    restoring [id] = nil

    -- store
    if not restoreEnabled () then
      return
    end
    local stored = getStored (key) or {}
    if sameVolumes (stored.channelVolumes, vols) and
        (type (mute) ~= "boolean" or mute == stored.mute) then
      return
    end
    local value = { channelVolumes = Json.Array (vols) }
    if type (mute) == "boolean" then
      value.mute = mute
    end
    state_table [key] = Json.Object (value):to_string ()
    state:save_after_timeout (state_table)
  end
}:register ()

SimpleEventHook {
  name = "node/asahi-forget-volume-log",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { ENABLE_PROP, "=", "true" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local b = bursts [node.id]
    if b then
      b.source:destroy ()
      flushBurst (node.id, nodeKey (node))
    end
    last_seen [node.id] = nil
    restoring [node.id] = nil
  end
}:register ()
