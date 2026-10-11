-- SPDX-License-Identifier: MIT
-- Exercise the real parameter-change hook with deterministic event ordering.
-- Run: lua tests/restore-volume-log.lua conf/asahi-restore-volume.lua
local hooks, lines = {}, {}
package.preload['common-utils'] = function ()
  return { parseParam = function (p) return p end }
end
Log = { open_topic = function () return {
  notice = function (_, msg) table.insert (lines, msg) end,
  info = function () end,
} end }
State = function () return { load = function () return {} end } end
Settings = { get_boolean = function () return false end }
GLib = { get_monotonic_time = function () return 10000000 end }
Interest = function (o) return o end
ObjectManager = function () return {
  connect = function () end, activate = function () end,
} end
EventInterest = function (o) return o end
Constraint = function (...) return {...} end
SimpleEventHook = function (o)
  o.register = function () hooks[o.name] = o end
  return o
end
Core = { timeout_add = function () return { destroy = function () end } end }
dofile (arg[1] or 'conf/asahi-restore-volume.lua')
local node = { id = 1, properties = { ['node.name'] = 'audio_effect.j700-convolver' } }
local props
node.iterate_params = function ()
  local used = false
  return function () if not used then used = true; return props end end
end
local event = { get_subject = function () return node end }
local function change (linear, mute)
  props = { channelVolumes = {linear, linear}, mute = mute or false }
  hooks['node/asahi-store-volume'].execute (event)
end
local function reset (linear)
  last_seen[1] = { vols = {linear,linear}, mute = false }
  bursts[1], restoring[1] = nil, nil
  lines = {}
end
local function expect (pattern)
  assert (#lines == 1, 'expected exactly one notice, got ' .. #lines)
  assert (lines[1]:match (pattern), 'unexpected log: ' .. lines[1])
  print ('PASS ' .. lines[1])
end
-- External 10% -> 100% -> 10% must not disappear just because endpoints match.
reset (0.001)
change (1.0); change (0.001); flushBurst (1, node.properties['node.name'])
expect ('volume 0%.10 %-> 0%.10.-%(2 changes; another client;.-peak volume 1%.00%)')
-- A restore-related event followed by external changes in the same burst
-- must retain the external event even when the final values match the start.
reset (0.001); restoring[1] = true
change (0.008); change (1.0); change (0.001)
flushBurst (1, node.properties['node.name'])
expect ('volume 0%.10 %-> 0%.10.-%(3 changes; restore and another client;.-peak volume 1%.00%)')
-- A net-zero restore-only burst remains quiet, as before.
reset (0.001); restoring[1] = true
change (0.008); restoring[1] = true; change (0.001)
flushBurst (1, node.properties['node.name'])
assert (#lines == 0, 'restore-only net-zero burst was logged')
print ('PASS restore-only net-zero burst remains silent')
