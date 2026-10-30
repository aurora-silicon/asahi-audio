-- SPDX-License-Identifier: MIT
--
-- Give an unplugged output its volume and mute state, and keep the ones the
-- user sets on it.
--
-- WirePlumber selects only routes that are available (or of unknown
-- availability).  An output whose only route is unplugged, such as a
-- headphone jack with nothing in it when the profile is selected, is left
-- without a route: its node then reports the ALSA layer's initial volume,
-- 100 % and unmuted, until something is plugged in, and a volume or mute
-- set on it in the meantime is not stored.
--
-- For devices that set asahi.routes.select-unplugged = true, select the
-- best unplugged output route for such an output.  The route props are
-- then applied as for any other route: the stored ones, or the device's
-- device.routes.default-sink-volume.  The node starts at the volume the
-- output will have once it is used, and plugging in selects the route again
-- as usual.
--
-- WirePlumber also never stores the props of a route that is unavailable,
-- so a volume or mute the user sets on such a route would be lost at the
-- next start.  For the same devices, store what the user sets on an
-- unavailable route in a state file of its own, and apply it in place of
-- WirePlumber's stored props whenever that route is selected, until the
-- user changes the route again while it is available and WirePlumber
-- stores it itself.

cutils = require ("common-utils")
devinfo = require ("device-info-cache")
log = Log.open_topic ("s-device")

SimpleEventHook {
  name = "device/asahi-select-unplugged-routes",
  after = "device/find-best-routes",
  before = "device/apply-route-props",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-routes" },
      Constraint { "profile.active-device-ids", "is-present" },
      Constraint { "asahi.routes.select-unplugged", "=", "true" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local active_ids = event:get_properties () ["profile.active-device-ids"]
    local selected_routes = event:get_data ("selected-routes") or Properties ()

    local dev_info = devinfo:get_device_info (device)
    if not dev_info then
      return
    end

    for _, device_id in ipairs (Json.Raw (active_ids):parse ()) do
      if selected_routes [tostring (device_id)] then
        goto next_device_id
      end

      local best = nil
      for _, ri in pairs (dev_info.route_infos) do
        if ri.direction == "Output" and ri.available == "no" and
            cutils.arrayContains (ri.devices, device_id) and
            (ri.profiles == nil or
              cutils.arrayContains (ri.profiles, dev_info.active_profile)) and
            (best == nil or ri.priority > best.priority) then
          best = ri
        end
      end

      if best then
        log:info (device, string.format (
            "selecting unplugged route %s of device(%s) for its volume",
            best.name, dev_info.name))
        selected_routes [tostring (device_id)] =
            Json.Object { index = best.index }:to_string ()
      end

      ::next_device_id::
    end

    event:set_data ("selected-routes", selected_routes)
  end
}:register ()

-- The props the user set on unavailable routes, keyed like WirePlumber's
-- default-routes state: <device name>:<direction>:<route name>.
state = nil
state_table = nil

function routeKey (dev_name, route)
  return dev_name .. ":" .. route.direction:lower () .. ":" .. route.name
end

store_hook = SimpleEventHook {
  name = "device/asahi-store-unplugged-route-props",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "Route" },
      Constraint { "asahi.routes.select-unplugged", "=", "true" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local dev_name = device.properties ["device.name"]
    if not dev_name then
      return
    end

    local changed = false
    for p in device:iterate_params ("Route") do
      local route = cutils.parseParam (p, "Route")
      -- only changes a client asked to save: the routes WirePlumber applies
      -- itself have save = false
      if not route or not route.save or not route.props then
        goto next_route
      end

      local key = routeKey (dev_name, route)
      if route.available == "no" then
        local props = route.props.properties
        local value = Json.Object {
          volume = props.volume,
          mute = props.mute,
          channelVolumes = props.channelVolumes and Json.Array (props.channelVolumes),
          channelMap = props.channelMap and Json.Array (props.channelMap),
          latencyOffsetNsec = props.latencyOffsetNsec,
          iec958Codecs = props.iec958Codecs and Json.Array (props.iec958Codecs),
        }:to_string ()
        if state_table [key] ~= value then
          log:info (device, string.format (
              "storing props of unplugged route %s of device(%s)",
              route.name, dev_name))
          state_table [key] = value
          changed = true
        end
      elseif state_table [key] then
        -- WirePlumber stores the props of an available route itself
        state_table [key] = nil
        changed = true
      end

      ::next_route::
    end

    if changed then
      state:save_after_timeout (state_table)
    end
  end
}

apply_hook = SimpleEventHook {
  name = "device/asahi-apply-unplugged-route-props",
  after = "device/apply-route-props",
  before = "device/apply-routes",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-routes" },
      Constraint { "asahi.routes.select-unplugged", "=", "true" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local selected_routes = event:get_data ("selected-routes")
    local dev_info = devinfo:get_device_info (device)
    if not selected_routes or not dev_info then
      return
    end

    local new_selected_routes = {}
    for device_id, route in pairs (selected_routes) do
      new_selected_routes [device_id] = route

      local selected = Json.Raw (route):parse ()
      local route_info = devinfo.find_route_info (dev_info, selected, false)
      local value = route_info and state_table [routeKey (dev_info.name, route_info)]
      local json = value and Json.Raw (value)
      if not json or not json:is_object () then
        goto next_route
      end

      do
        local props = json:parse ()
        if props.channelVolumes then
          props.channelVolumes = Json.Array (props.channelVolumes)
        end
        if props.channelMap then
          props.channelMap = Json.Array (props.channelMap)
        end
        if props.iec958Codecs then
          props.iec958Codecs = Json.Array (props.iec958Codecs)
        end

        log:info (device, string.format (
            "applying the props stored for unplugged route %s of device(%s)",
            route_info.name, dev_info.name))
        new_selected_routes [device_id] = Json.Object {
          index = route_info.index,
          props = Json.Object (props),
        }:to_string ()
      end

      ::next_route::
    end

    event:set_data ("selected-routes", new_selected_routes)
  end
}

-- follow WirePlumber's own switch for storing and restoring route props
function toggleState (enable)
  if enable and not state then
    state = State ("asahi-unplugged-routes")
    state_table = state:load ()
    store_hook:register ()
    apply_hook:register ()
  elseif not enable and state then
    state = nil
    state_table = nil
    store_hook:remove ()
    apply_hook:remove ()
  end
end

Settings.subscribe ("device.restore-routes", function ()
  toggleState (Settings.get_boolean ("device.restore-routes"))
end)
toggleState (Settings.get_boolean ("device.restore-routes"))
