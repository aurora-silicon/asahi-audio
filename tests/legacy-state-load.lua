-- SPDX-License-Identifier: MIT
-- Checks that the renamed scripts still read the state file written under the
-- old name, and prefer the new one once it holds data.
-- LEGACY-ASAHI(2027-02-28): remove with the fallback it tests.
-- Run: lua tests/legacy-state-load.lua conf/aurora-restore-volume.lua
local files = {}
State = function (name)
  return { name = name, load = function () return files [name] or {} end,
           save_after_timeout = function () end }
end
package.preload ["common-utils"] = function ()
  return { parseParam = function (p) return p end }
end
Log = { open_topic = function () return { notice = function () end, info = function () end } end }
Settings = { get_boolean = function () return false end }
GLib = { get_monotonic_time = function () return 10000000 end }
Interest = function (o) return o end
ObjectManager = function () return { connect = function () end, activate = function () end } end
EventInterest = function (o) return o end
Constraint = function (...) return {...} end
SimpleEventHook = function (o) o.register = function () end return o end
Core = { timeout_add = function () return { destroy = function () end } end }

files ["asahi-restore-volume"] = { ["k"] = "old" }
dofile (arg[1] or 'conf/aurora-restore-volume.lua')
assert (state_table ["k"] == "old", "legacy state not read")
print ("PASS empty new state falls back to the legacy file")

files ["aurora-restore-volume"] = { ["k"] = "new" }
local _, t = aurora_legacy_state_load ("aurora-restore-volume", "asahi-restore-volume")
assert (t ["k"] == "new", "new state not preferred")
print ("PASS new state wins once it holds data")
