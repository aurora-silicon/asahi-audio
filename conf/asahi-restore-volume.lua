-- SPDX-License-Identifier: MIT
--
-- Restore a node's volume with a ceiling.
--
-- For nodes that set asahi.restore-props.max-volume (a linear channel
-- volume, like channelVolumes), this script stores and restores the
-- volume and mute state in place of WirePlumber's stream state, which
-- the node turns off with state.restore-props = false.
--
-- Every time such a node is created, it gets its stored channel volumes,
-- each lowered to asahi.restore-props.max-volume when above it, and its
-- stored mute state.  The first time, the volume and mute that WirePlumber's
-- stream state stored for the node are used.  Without a stored volume it
-- gets state.default-volume (or the ceiling), again no higher than the
-- ceiling.  A volume set while
-- the node exists is stored as usual and is not limited; it only starts
-- no higher than the ceiling the next time the node is created.
--
-- A stored volume is not proof that the user chose it: a volume stored
-- by any client, at any time, would otherwise come back at the next
-- boot, before anyone is listening.

cutils = require ("common-utils")
log = Log.open_topic ("s-node")

MAX_PROP = "asahi.restore-props.max-volume"

state = State ("asahi-restore-volume")
state_table = state:load ()

function restoreEnabled ()
  return Settings.get_boolean ("node.stream.restore-props")
end

function nodeKey (node)
  return node.properties ["node.name"]
end

function getStored (key)
  local value = key and state_table [key]
  if not value then
    return {}
  end
  local json = Json.Raw (value)
  if not json or not json:is_object () then
    return {}
  end
  return json:parse ()
end

-- The volume and mute that WirePlumber's stream state stored for the node
-- before this script took it over (same key as node/state-stream.lua), so
-- that a quieter volume or mute survives the switch.  It is read once and
-- is subject to the same ceiling.
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
      local value = wp_stream_state [class .. ":" .. k .. ":" .. props [k]]
      local json = value and Json.Raw (value)
      if json and json:is_object () then
        return json:parse ()
      end
      return {}
    end
  end
  return {}
end

function toNumber (value)
  local n = tonumber (value)
  if n == nil or n ~= n or n < 0.0 then
    return nil
  end
  return n
end

function channelCount (node, stored_volumes)
  local n = tonumber (node.properties ["audio.channels"])
  if n and n >= 1 then
    return math.floor (n)
  end
  if type (stored_volumes) == "table" and #stored_volumes > 0 then
    return #stored_volumes
  end
  return 2
end

-- The first Props object that carries channel volumes is the converter's,
-- which holds the node's volume (the adapter lists it before the
-- follower's).
function currentProps (node)
  for p in node:iterate_params ("Props") do
    local props = cutils.parseParam (p, "Props")
    if props and type (props.channelVolumes) == "table" and
        #props.channelVolumes > 0 then
      return props
    end
  end
  return nil
end

SimpleEventHook {
  name = "node/asahi-restore-volume",
  after = "node/restore-stream",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { MAX_PROP, "is-present" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local max = toNumber (node.properties [MAX_PROP])
    if max == nil then
      log:warning (node, "ignoring invalid " .. MAX_PROP .. " = " ..
          tostring (node.properties [MAX_PROP]))
      return
    end

    local default = toNumber (node.properties ["state.default-volume"]) or max
    local stored = {}
    local source = "none"
    if restoreEnabled () then
      stored = getStored (nodeKey (node))
      source = "stored"
      if type (stored.channelVolumes) ~= "table" then
        stored = getWirePlumberStored (node)
        source = "adopted from WirePlumber's stream state"
      end
    end
    local stored_volumes = stored.channelVolumes

    local volumes = { "Spa:Float" }
    for i = 1, channelCount (node, stored_volumes) do
      local v = type (stored_volumes) == "table" and
          toNumber (stored_volumes [i]) or default
      table.insert (volumes, math.min (v, max))
    end

    local props = {
      "Spa:Pod:Object:Param:Props", "Props",
      channelVolumes = Pod.Array (volumes),
    }
    if type (stored.mute) == "boolean" then
      props.mute = stored.mute
    end

    log:info (node, string.format ("restoring %s: volume %s (%s %s, ceiling %s)",
        tostring (nodeKey (node)), tostring (volumes [2]), source,
        tostring (type (stored_volumes) == "table" and stored_volumes [1] or "none"),
        tostring (max)))
    node:set_param ("Props", Pod.Object (props))
  end
}:register ()

SimpleEventHook {
  name = "node/asahi-store-volume",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-params-changed" },
      Constraint { "event.subject.param-id", "=", "Props" },
      Constraint { MAX_PROP, "is-present" },
    },
  },
  execute = function (event)
    if not restoreEnabled () then
      return
    end

    local node = event:get_subject ()
    local key = nodeKey (node)
    local props = currentProps (node)
    if not key or not props then
      return
    end

    local volumes = {}
    for _, v in ipairs (props.channelVolumes) do
      table.insert (volumes, v)
    end

    local stored = getStored (key)
    local changed = type (props.mute) == "boolean" and props.mute ~= stored.mute
    if type (stored.channelVolumes) ~= "table" or
        #stored.channelVolumes ~= #volumes then
      changed = true
    else
      for i, v in ipairs (volumes) do
        if math.abs (v - (tonumber (stored.channelVolumes [i]) or -1)) > 1e-6 then
          changed = true
        end
      end
    end
    if not changed then
      return
    end

    local value = { channelVolumes = Json.Array (volumes) }
    if type (props.mute) == "boolean" then
      value.mute = props.mute
    end
    log:info (node, "saving volume of " .. key)
    state_table [key] = Json.Object (value):to_string ()
    state:save_after_timeout (state_table)
  end
}:register ()
