-- SPDX-License-Identifier: MIT
-- Run the real default-node hook on WirePlumber's select-default-node event.
-- Run: lua tests/network-sinks-default.lua conf/aurora-network-sinks.lua
local hooks = {}
Log = { open_topic = function () return { info = function () end } end }
EventInterest = function (o) return o end
Constraint = function (c) return c end
SimpleEventHook = function (o)
  o.register = function () hooks[o.name] = o end
  return o
end
local function wrap (value) return { parse = function () return value end } end
Json = {
  Raw = function (text) return wrap { name = text:match ('"name"%s*:%s*"([^"]*)"') } end,
  Object = function (props) return props end,
  Array = function (list) return wrap (list) end,
}
dofile (arg[1] or 'conf/aurora-network-sinks.lua')
local hook = hooks['default-nodes/aurora-network-sinks']

local SPEAKERS = { ['node.name'] = 'sgv2.voicing.j316', ['media.class'] = 'Audio/Sink' }
local HEADPHONES = { ['node.name'] = 'alsa_output.jack', ['media.class'] = 'Audio/Sink' }
local AIRPLAY = { ['node.name'] = 'raop_sink.living-room.local.192.0.2.10.7000',
                  ['media.class'] = 'Audio/Sink', ['node.network'] = 'true' }

-- The select-default-node event for the sinks present, with `configured`
-- as the chosen sink. Returns the names the later hooks get to choose from.
local function select (configured, ...)
  local data = { ['available-nodes'] = Json.Array ({...}) }
  local metadata = { find = function (_, subject, key)
    assert (subject == 0 and key == 'default.configured.audio.sink')
    return configured and ('{ "name": "' .. configured .. '" }')
  end }
  local source = { call = function (_, method, kind)
    assert (method == 'get-object-manager' and kind == 'metadata')
    return { lookup = function () return metadata end }
  end }
  hook.execute {
    get_data = function (_, key) return data[key] end,
    set_data = function (_, key, value) data[key] = value end,
    get_source = function () return source end,
  }
  local names = {}
  for _, props in ipairs (data['available-nodes']:parse ()) do
    table.insert (names, props['node.name'])
  end
  return table.concat (names, ' ')
end

local function expect (got, want, what)
  assert (got == want, what .. ': got "' .. got .. '", want "' .. want .. '"')
  print ('PASS ' .. what)
end

-- Only audio.sink selection, ahead of every hook that picks a node.
local constraints = {}
for _, c in ipairs (hook.interests[1]) do constraints[c[1]] = c[3] end
assert (constraints['event.type'] == 'select-default-node')
assert (constraints['default-node.type'] == 'audio.sink')
for _, name in ipairs { 'find-selected-default-node', 'find-stored-default-node',
                        'find-best-default-node' } do
  local found = false
  for _, before in ipairs (hook.before) do found = found or before == 'default-nodes/' .. name end
  assert (found, 'not before ' .. name)
end

-- The chosen headphones are unplugged and the receiver is announced again:
-- the Mac's own sink stays the default.
expect (select (HEADPHONES['node.name'], SPEAKERS, AIRPLAY), SPEAKERS['node.name'],
        'a network sink that is not chosen is left out')
expect (select (nil, AIRPLAY, SPEAKERS), SPEAKERS['node.name'],
        'nothing chosen: the network sink is left out')
expect (select (AIRPLAY['node.name'], SPEAKERS, AIRPLAY),
        SPEAKERS['node.name'] .. ' ' .. AIRPLAY['node.name'], 'a chosen network sink stays')
expect (select (HEADPHONES['node.name'], AIRPLAY), AIRPLAY['node.name'],
        'a network sink stays when it is the only sink')
expect (select (nil, HEADPHONES, SPEAKERS), HEADPHONES['node.name'] .. ' ' .. SPEAKERS['node.name'],
        'other sinks are untouched')
