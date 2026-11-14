#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 The Aurora Silicon Contributors
"""Build a Mac's built-in microphone graph from its own macOS tuning.

The installer copies this Mac's own audio tuning bundle (the AID<n> folder of
its system volume, see aurora-installer's audio_tuning) to the vendor
firmware; nothing of it is shipped here. This tool reads the bundle's default
("General") input graph for the Built-in Microphone and turns the parts a
PipeWire filter-chain can reproduce with builtins into a graph:

  * the per-microphone trims (the gain boxes on each channel after the
    channel split),
  * the fixed gains after them (every other gain box of the graph except the
    one the user's input volume drives),
  * the DC blocker's corner, when the graph has one,
  * the input volume range: the graph is built for the top of the range, and
    the source starts at the range's initial value.

The microphones are averaged; the beamformer, noise suppression and EQ of the
macOS graph are not reproduced. The level of a voice in front of the Mac is
then macOS's at the same input volume.

It writes <out>/mic.json and <out>/wireplumber.conf (the filter rule for the
array's ALSA path, and the headphone jack's initial volume from the same
tuning when the card is given). Install the latter as a WirePlumber fragment.

usage: mic-from-tuning.py --path hw:AppleJ714HPAI,0 --name j714
           --description "MacBook Pro J714 Microphone" [--card "MacBook Pro J714"]
           [--tuning DIR] --out DIR
"""
import argparse, json, math, os, plistlib, re, struct, sys

SEARCH = ["/lib/firmware/vendor/apple/audio-tuning",
          "/var/lib/speakerguardd-tuning/audio-tuning"]
MIXER_MAX = 10.0      # the builtin mixer's gain control stops at 10
GENERAL = 0           # cdes kind of the default input mode


def die(msg):
    sys.exit("mic-from-tuning: " + msg)


def find_bundle(arg):
    for d in ([arg] if arg else SEARCH):
        if d and os.path.isfile(os.path.join(d, "manifest.json")):
            return d
    die("no tuning bundle (looked in %s)" % ", ".join([arg] if arg else SEARCH))


def bundle_file(root, rel):
    """A path of the tuning folder, as the DSP database names it."""
    for cand in (rel, rel.split("/Tunings/", 1)[-1]):
        p = os.path.join(root, cand.lstrip("/"))
        if os.path.isfile(p):
            return p
    die("the bundle has no %s" % rel)


def preset_params(data):
    """An AU preset's parameter block: big-endian scope, element, count, then
    count (id, float32) pairs."""
    if not data or len(data) < 12:
        return {}
    n = struct.unpack(">I", data[8:12])[0]
    out = {}
    for i in range(n):
        off = 12 + 8 * i
        if off + 8 > len(data):
            break
        pid, val = struct.unpack(">If", data[off:off + 8])
        out[pid] = val
    return out


def parse_graph(text):
    boxes, split_wires, params = {}, {}, {}
    for line in text.splitlines():
        line = line.split(";", 1)[0].strip()
        m = re.match(r"box\s+(\S+)\s+(\(.*?\)|\S+)", line)
        if m:
            boxes[m.group(1)] = m.group(2)
            continue
        m = re.match(r"wire\s+\((\S+)\s+(\d+)\)\s+(\S+)", line)
        if m:
            split_wires.setdefault(m.group(1), {})[int(m.group(2))] = m.group(3)
            continue
        m = re.match(r"wireGraphParam\s+(\S+)\s+\((\S+)\s+\d+\)", line)
        if m:
            params[m.group(1)] = m.group(2)
    return boxes, split_wires, params


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuning")
    ap.add_argument("--path", required=True, help="the array's api.alsa.path")
    ap.add_argument("--name", required=True, help="board, for the node names")
    ap.add_argument("--description", required=True)
    ap.add_argument("--card", help="the built-in card's name, for the jack's initial volume")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    root = find_bundle(a.tuning)
    man = json.load(open(os.path.join(root, "manifest.json")))
    aid = man.get("aid") or die("manifest names no aid")
    dbrel = man.get("device_dsp_database") or man.get("device_dsp_database_source") or die("manifest names no DSP database")
    db = plistlib.load(open(bundle_file(root, dbrel), "rb"))
    db = db.get(aid, db)
    mic = db.get("Built-in Microphone") or die("no Built-in Microphone in the DSP database")
    mode = None
    for v in mic.values():
        props = {d.get("Selector"): d.get("Value") for d in v.get("DSPDeviceProperties", [])}
        cdes = props.get("cdes") or {}
        if cdes.get("kind") == GENERAL and "mode" not in cdes:
            mode = v
    mode or die("no General input mode for the Built-in Microphone")
    hw = [h for x in mode.get("Input", []) for h in x.get("Hardware", [])]
    gpath = next((h["Path"] for h in hw if h.get("Type") == "DSPGraph"), None) or die("no input graph")
    spath = next((h["Path"] for h in hw if h.get("Type") == "AUStrip"), None) or die("no input strip")

    boxes, split_wires, gparams = parse_graph(open(bundle_file(root, gpath)).read())
    strip = plistlib.load(open(bundle_file(root, spath), "rb"))
    eff = {e["displayname"]: e for s in strip.get("strips", []) for e in s.get("effects", [])}

    def kind(box):
        t = boxes.get(box, "")
        return "gain" if t == "gain" else "dbgn" if t == "dbgn" else t

    def value(box):
        p = preset_params(eff.get(box, {}).get("aupreset", {}).get("data"))
        if 0 not in p:
            die("the strip has no value for %s" % box)
        return p[0]

    user = gparams.get("mvol")
    # per-channel trims: the gain boxes fed by the channel splitter
    chans = None
    for src, wires in split_wires.items():
        if boxes.get(src) == "split" and wires and all(kind(b) in ("gain", "dbgn") for b in wires.values()):
            chans = [wires[i] for i in sorted(wires)]
    chans or die("no per-microphone trims after a channel split")
    trims = [value(b) if kind(b) == "gain" else 10 ** (value(b) / 20) for b in chans]
    fixed = 1.0
    for b in boxes:
        if b in chans or b == user or kind(b) not in ("gain", "dbgn"):
            continue
        fixed *= value(b) if kind(b) == "gain" else 10 ** (value(b) / 20)
    dcb = next((b for b, t in boxes.items() if "dccb" in t), None)
    dc_hz = value(dcb) if dcb else None
    if dc_hz is not None and not 5 <= dc_hz <= 200:
        dc_hz = None

    cfg = plistlib.load(open(bundle_file(root, man["config"]), "rb")).get("DSP Devices", {})
    mp = cfg.get("Built-in Microphone", {}).get("Parameters", {})
    vmax = float(mp.get("InputVolumeMax", 0.0))
    vinit = float(mp.get("InputVolumeInitial", vmax))
    hp_init = cfg.get("Built-in Headphone", {}).get("Parameters", {}).get("OutputVolumeInitial")

    n = len(chans)
    total = fixed * 10 ** (vmax / 20)
    stages = max(1, math.ceil(math.log(total) / math.log(MIXER_MAX) - 1e-9)) if total > 1 else 1
    sg = total ** (1 / stages)

    nodes = [{"type": "builtin", "label": "mixer", "name": "mix",
              "control": {"Gain %d" % (i + 1): round(t / n, 6) for i, t in enumerate(trims)}}]
    chain = ["mix"]
    if dc_hz:
        nodes.append({"type": "builtin", "label": "bq_highpass", "name": "dcblock",
                      "control": {"Freq": round(dc_hz, 3), "Gain": 1, "Q": 0.707}})
        chain.append("dcblock")
    for i in range(stages):
        nodes.append({"type": "builtin", "label": "mixer", "name": "gain%d" % i,
                      "control": {"Gain 1": round(sg, 6)}})
        chain.append("gain%d" % i)

    def port(node, out):
        if node.startswith("gain") or node == "mix":
            return node + (":Out" if out else ":In 1")
        return node + (":Out" if out else ":In")

    graph = {
        "node.description": a.description,
        "media.name": a.description,
        "filter.graph": {
            "nodes": nodes,
            "links": [{"output": port(x, True), "input": port(y, False)} for x, y in zip(chain, chain[1:])],
            "inputs": ["mix:In %d" % (i + 1) for i in range(n)],
            "outputs": [port(chain[-1], True)],
        },
        "capture.props": {
            "node.name": "audio_effect.%s-mic" % a.name,
            "audio.channels": str(n),
            "audio.position": ["AUX%d" % i for i in range(n)],
            "audio.allowed-rates": [48000],
            "node.virtual": "false",
            "state.default-volume": 1.0,
            "device.icon-name": "audio-microphone",
            "target.object": "alsa_input.platform-sound.RawMics",
            "node.dont-fallback": "true",
            "node.passive": "true",
        },
        "playback.props": {
            "node.name": "effect_output.%s-mic" % a.name,
            "media.class": "Audio/Source",
            "priority.session": 2005,
            "node.passive": "true",
            "audio.channels": "1",
            "node.virtual": "false",
            "state.default-volume": round(10 ** ((vinit - vmax) / 20), 6),
            "audio.allowed-rates": [8000, 11025, 16000, 22050, 44100, 48000],
            "audio.position": ["MONO"],
        },
    }
    os.makedirs(a.out, exist_ok=True)
    gfile = os.path.join(os.path.abspath(a.out), "mic.json")
    with open(gfile, "w") as f:
        json.dump(graph, f, indent=2)
        f.write("\n")

    wp = ["# Generated by asahi-audio's mic-from-tuning from this Mac's own tuning (%s); do not edit." % aid,
          "monitor.alsa.rules = ["]
    wp += ["    {", "        matches = [ { api.alsa.path = \"%s\" } ]" % a.path,
           "        actions = { update-props = {",
           "            node.name = \"alsa_input.platform-sound.RawMics\"",
           "            node.description = \"Raw Mic Device (do not use)\"",
           "            node.nick = \"RawMics\"", "        } }", "    }"]
    if a.card and hp_init is not None:
        wp += ["    {", "        matches = [ { device.name = \"~alsa_card.*\", api.alsa.card.name = \"%s\" } ]" % a.card,
               "        actions = { update-props = { device.routes.default-sink-volume = %s } }"
               % round(10 ** (float(hp_init) / 20), 6), "    }"]
    wp += ["]", "node.software-dsp.rules = [", "    {",
           "        matches = [ { api.alsa.path = \"%s\" } ]" % a.path,
           "        actions = { create-filter = { filter-path = \"%s\", hide-parent = true } }" % gfile,
           "    }", "]",
           "wireplumber.profiles = { main = { node.software-dsp = required } }", ""]
    with open(os.path.join(a.out, "wireplumber.conf"), "w") as f:
        f.write("\n".join(wp))
    print("mic-from-tuning: %s: %d microphones, graph in %s" % (aid, n, a.out))


if __name__ == "__main__":
    main()
