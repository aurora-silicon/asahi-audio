-- SPDX-License-Identifier: MIT
--
-- Give an unplugged output its volume at startup.
--
-- WirePlumber selects only routes that are available (or of unknown
-- availability).  An output whose only route is unplugged, such as a
-- headphone jack with nothing in it when the profile is selected, is left
-- without a route: its node then reports the ALSA layer's initial volume,
-- 100 %, until something is plugged in, and a volume set on it in the
-- meantime is not stored.
--
-- For devices that set asahi.routes.select-unplugged = true, select the
-- best unplugged output route for such an output.  The route props are
-- then applied as for any other route: the stored ones, or the device's
-- device.routes.default-sink-volume.  The node starts at the volume the
-- output will have once it is used, and plugging in selects the route again
-- as usual.

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
