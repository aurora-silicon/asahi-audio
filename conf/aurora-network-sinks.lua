-- SPDX-License-Identifier: MIT
--
-- A network sink becomes the default sink only while it is the one chosen.
--
-- WirePlumber picks the default sink from the sink chosen last, then from
-- every sink chosen before it, newest first, then by priority. A network
-- sink, such as an AirPlay receiver that PipeWire's RAOP discovery adds,
-- comes and goes with the network. Once chosen, it stays in that history:
-- whenever the chosen sink was missing (headphones unplugged) and the
-- receiver was announced again, it became the default and took the
-- playback of every application off the Mac's own outputs. A receiver that
-- refuses the stream (RTSP 403) unloads its sink and is announced again,
-- so playback kept dropping. macOS never moves its output to an AirPlay
-- receiver by itself either.
--
-- Leave the sinks that set node.network = true out of the candidates,
-- unless one is the sink chosen now, or no other sink is left. Choosing a
-- network sink still makes it the default, as before.

log = Log.open_topic ("s-default-nodes")

local function chosen (source)
  local om = source:call ("get-object-manager", "metadata")
  local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
  local value = metadata and metadata:find (0, "default.configured.audio.sink")
  local parsed = value and Json.Raw (value):parse ()
  return type (parsed) == "table" and parsed.name or nil
end

SimpleEventHook {
  name = "default-nodes/aurora-network-sinks",
  before = { "default-nodes/find-selected-default-node",
             "default-nodes/find-stored-default-node",
             "default-nodes/find-best-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
      Constraint { "default-node.type", "=", "audio.sink" },
    },
  },
  execute = function (event)
    local available = event:get_data ("available-nodes")
    available = available and available:parse ()
    if not available then
      return
    end

    local name = chosen (event:get_source ())
    local kept, left_out = {}, {}
    for _, props in ipairs (available) do
      if props ["node.network"] == "true" and props ["node.name"] ~= name then
        table.insert (left_out, tostring (props ["node.name"]))
      else
        table.insert (kept, Json.Object (props))
      end
    end
    if #left_out == 0 or #kept == 0 then
      return
    end

    log:info ("network sinks are the default only when chosen: leaving out "
        .. table.concat (left_out, ", "))
    event:set_data ("available-nodes", Json.Array (kept))
  end
}:register ()
