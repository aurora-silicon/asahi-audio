#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the J700 limiter variant against the stock J700 speaker graph.

graph-xlim.json must be graph.json with one node added at the very end of
the signal path, the speakerguard excursion limiter, and nothing else
changed.  Its controls must be the J700 driver's values, and its latency
must stay inside the 352-frame budget.  The WirePlumber drop-in must
select it for the J700 speakers alone and keep the stock microphone rule.

Run: python3 tests/j700-xlim-graph.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
J700 = os.path.join(ROOT, "firs", "j700")
RATE = 48000

# The MacBook Neo's driver values and limits, as speakerguard-xlim's defaults.
FACTS = {
    "Vfs L (V)": 7.30,
    "Vfs R (V)": 7.33,
    "Re (ohm)": 4.3,
    "Bl (T m)": 0.74,
    "Mms (g)": 0.16,
    "Kms (N/m)": 1720.0,
    "Rms (kg/s)": 0.14,
    "Xmax (mm)": 0.565,
    "Vmax (m/s)": 0.0,
    "Peak (FS)": 1.0,
    "Margin": 0.89,
    "Release (ms)": 200.0,
    "Window (ms)": 3.3333,
    "Hold (ms)": 4.0,
}
BUDGET_FRAMES = 352

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(path):
    """The graphs are JSON with trailing commas."""
    with open(path) as f:
        text = f.read()
    return json.loads(re.sub(r",(\s*[\]}])", r"\1", text))


def rules(path):
    """The create-filter rules of a WirePlumber conf: (path match, filter-path)."""
    with open(path) as f:
        text = re.sub(r"#.*", "", f.read())
    return re.findall(r'api\.alsa\.path\s*=\s*"([^"]+)"\s*}\s*]\s*actions\s*=\s*{\s*create-filter\s*=\s*{\s*filter-path\s*=\s*"([^"]+)"', text)


stock = load(os.path.join(J700, "graph.json"))
xlim = load(os.path.join(J700, "graph-xlim.json"))
sg, xg = stock["filter.graph"], xlim["filter.graph"]

# nothing outside the graph's nodes, links and outputs changes
for k in set(stock) | set(xlim):
    if k != "filter.graph":
        check(stock.get(k) == xlim.get(k), f"{k} differs from the stock graph")
for k in set(sg) | set(xg):
    if k not in ("nodes", "links", "outputs"):
        check(sg.get(k) == xg.get(k), f"filter.graph {k} differs from the stock graph")

# the stock nodes, unchanged and in order, then the limiter
check(xg["nodes"][:-1] == sg["nodes"], "the stock nodes changed")
node = xg["nodes"][-1]
check(node.get("type") == "ladspa" and node.get("plugin") == "speakerguard-xlim" and node.get("label") == "speakerguard_xlim",
      f"the last node is not the limiter: {node}")
name = node.get("name")
check(node.get("control") == FACTS, f"the limiter's controls are not the J700's: {node.get('control')}")

# it takes what the stock graph put out, and nothing comes after it
stock_out = sg["outputs"]
check(xg["links"][:len(sg["links"])] == sg["links"], "the stock links changed")
added = xg["links"][len(sg["links"]):]
check(added == [{"output": stock_out[0], "input": f"{name}:in_l"}, {"output": stock_out[1], "input": f"{name}:in_r"}],
      f"the limiter is not fed by the stock outputs: {added}")
check(xg["outputs"] == [f"{name}:out_l", f"{name}:out_r"], f"the outputs are not the limiter's: {xg['outputs']}")
check(not any(link["output"].startswith(name + ":") for link in xg["links"]), "a link leaves the limiter")
check(not any(link["input"].startswith(name + ":") for link in sg["links"]), "the stock graph already feeds a node of that name")

# latency: window + hold - 1 frames at the graph's only rate
rates = xlim["capture.props"].get("audio.allowed-rates")
check(rates == [RATE], f"the graph runs at {rates}, not {RATE} only")
c = node.get("control", {})
lat = round(c.get("Window (ms)", 0) * 1e-3 * RATE) + round(c.get("Hold (ms)", 0) * 1e-3 * RATE) - 1
check(0 < lat <= BUDGET_FRAMES, f"the limiter adds {lat} frames, the budget is {BUDGET_FRAMES}")

# the drop-in: the variant for the speakers, the stock microphone rule
stock_rules = dict(rules(os.path.join(ROOT, "conf", "wireplumber.conf")))
drop = rules(os.path.join(J700, "xlim-wireplumber.conf"))
check(dict(drop) == {"hw:AppleJ700,1": "/usr/share/asahi-audio/j700/graph-xlim.json",
                     "hw:AppleJ700AOP,1": stock_rules.get("hw:AppleJ700AOP,1")} and len(drop) == 2,
      f"the drop-in's rules are {drop}")
check(stock_rules.get("hw:AppleJ700,1") == "/usr/share/asahi-audio/j700/graph.json", "the stock speaker rule moved")
with open(os.path.join(J700, "xlim-wireplumber.conf")) as f:
    check(re.search(r"^override\.node\.software-dsp\.rules\s*=", f.read(), re.M) is not None,
          "the drop-in does not replace the rule list (two speaker filters would be made)")

# with the plugin at hand (XLIM_SO=path/to/speakerguard-xlim.so), every
# control the graph sets and every port it links must be the plugin's
so = os.environ.get("XLIM_SO")
if so:
    import ctypes

    class Desc(ctypes.Structure):
        _fields_ = [("id", ctypes.c_ulong), ("label", ctypes.c_char_p), ("props", ctypes.c_int),
                    ("name", ctypes.c_char_p), ("maker", ctypes.c_char_p), ("copyright", ctypes.c_char_p),
                    ("nports", ctypes.c_ulong), ("pd", ctypes.POINTER(ctypes.c_int)),
                    ("pn", ctypes.POINTER(ctypes.c_char_p))]

    lib = ctypes.CDLL(so)
    lib.ladspa_descriptor.restype = ctypes.POINTER(Desc)
    d = lib.ladspa_descriptor(0).contents
    check(d.label.decode() == node.get("label"), f"the plugin's label is {d.label}")
    ports = {d.pn[i].decode(): d.pd[i] for i in range(d.nports)}
    INPUT, OUTPUT, CONTROL, AUDIO = 1, 2, 4, 8
    for k in node.get("control", {}):
        check(ports.get(k) == INPUT | CONTROL, f"the plugin has no input control {k!r}")
    for p_ in ("in_l", "in_r"):
        check(ports.get(p_) == INPUT | AUDIO, f"the plugin has no audio input {p_}")
    for p_ in ("out_l", "out_r"):
        check(ports.get(p_) == OUTPUT | AUDIO, f"the plugin has no audio output {p_}")
    check(ports.get("latency") == OUTPUT | CONTROL, "the plugin reports no latency")
    print(f"plugin {so}: {d.nports} ports, the graph's names all present" if not failures else f"plugin {so} checked")

for m in failures:
    print("FAIL", m)
print(f"j700 xlim graph: {'FAILED' if failures else 'ok'} ({len(failures)} failures), limiter latency {lat} frames")
sys.exit(1 if failures else 0)
