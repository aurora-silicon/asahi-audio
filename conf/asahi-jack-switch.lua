-- SPDX-License-Identifier: MIT
--
-- Make a built-in headphone jack the default sink (and a headset microphone
-- the default source) when something is plugged into it.
--
-- WirePlumber keeps a default chosen by hand (default.configured.*) for as
-- long as that node is available, whatever the priorities. On a Mac whose
-- speakers are speakerguardd v2's voicing sink, the speakers and the jack are
-- two separate nodes, so plugging in headphones would leave the sound on the
-- speakers. For nodes that set asahi.jack.switch-on-plug = true, select the
-- node as the configured default on the transition from unplugged to
-- plugged (the jack's EnumRoute becoming available), and at its creation if
-- it is already plugged. On unplug nothing is set: WirePlumber's stored
-- defaults fall back to the previous choice (the speakers).

cutils = require ("common-utils")
log = Log.open_topic ("s-default-nodes")

-- node.name -> true while its jack route is plugged (as last seen)
plugged = {}

nodes_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "asahi.jack.switch-on-plug", "=", "true", type = "pw" },
  }
}
nodes_om:activate ()

function jackPlugged (device, node)
  local cpd = tonumber (node.properties ["card.profile.device"])
  local want = node.properties ["media.class"] == "Audio/Sink" and "Output" or "Input"
  if not cpd then
    return false
  end
  for p in device:iterate_params ("EnumRoute") do
    local route = cutils.parseParam (p, "EnumRoute")
    if route and route.direction == want and type (route.devices) == "table" and
        cutils.arrayContains (route.devices, cpd) and route.available == "yes" then
      return true
    end
  end
  return false
end

function setDefault (node)
  local metadata = cutils.get_default_metadata_object ()
  local name = node.properties ["node.name"]
  local key = node.properties ["media.class"] == "Audio/Sink" and
      "default.configured.audio.sink" or "default.configured.audio.source"
  if not metadata or not name then
    return
  end
  log:notice (node, "jack plugged: " .. key .. " = " .. name)
  metadata:set (0, key, "Spa:String:JSON", Json.Object { ["name"] = name }:to_string ())
end

function update (device, node, may_switch)
  local name = node.properties ["node.name"]
  local now = jackPlugged (device, node)
  if now and not plugged [name] and may_switch then
    setDefault (node)
  end
  plugged [name] = now or nil
end

function deviceOf (node)
  local device_id = node.properties ["device.id"]
  if not device_id then
    return nil
  end
  return cutils.get_object_manager ("device"):lookup {
    Constraint { "bound-id", "=", device_id, type = "gobject" },
  }
end

SimpleEventHook {
  name = "default-nodes/asahi-jack-switch-node-added",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "asahi.jack.switch-on-plug", "=", "true" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local device = deviceOf (node)
    if device then
      update (device, node, true)
    end
  end
}:register ()

SimpleEventHook {
  name = "default-nodes/asahi-jack-switch-node-removed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "asahi.jack.switch-on-plug", "=", "true" },
    },
  },
  execute = function (event)
    plugged [event:get_subject ().properties ["node.name"]] = nil
  end
}:register ()

SimpleEventHook {
  name = "default-nodes/asahi-jack-switch-routes",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "EnumRoute" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local id = device ["bound-id"]
    for node in nodes_om:iterate () do
      if tonumber (node.properties ["device.id"]) == id then
        update (device, node, true)
      end
    end
  end
}:register ()
