# Mac mini J873 (M6): speaker

The AOP's speaker stream has no receive side, so the amplifier's V/I sense
never reaches Linux. The speaker therefore plays only behind speakerguardd
v2's no-sense protect stage (aurora-silicon/speakerguardd#212 and #222), with
the limits the machine itself provides. `firs/j873/graph.json` is a
high-pass and a limiter in front of that protect stage. The WirePlumber rule
matches only the protect stage's node, never the raw speaker PCM, so without
speakerguardd there is no J873 speaker sink and the speaker stays muted.

| Stage | Setting | Why |
|---|---|---|
| downmix | L/2 + R/2 (builtin `mixer`) | the speaker PCM is mono: one 32-bit slot, S24_LE, 48 kHz only |
| high-pass | 4th-order Butterworth at 100 Hz: two `bq_highpass`, Q 0.5412 and 1.3066 | keeps the low bass that only moves the cone off the driver |
| limiter | LSP true-peak limiter at -1 dBFS (`th` 0.891), the settings of the other graphs' final limiters | the high-pass overshoots on full-scale input; nothing reaches the PCM above -1 dBFS |

There is no measurement of the J873 speaker. That is why the graph has no
FIR, no bass extension and no loudness compensation, and why its sink volume
is a plain software gain ahead of the graph (no `capture.volumes`).
- The 100 Hz corner is not tuned to the J873 speaker. At every frequency
  below 100 Hz it drives the speaker less than the J274 graph drives the M1
  Mac mini's. That graph's FIR is -5.3 dB at 70 Hz, -10.8 dB at 50 Hz and
  -20.1 dB at 30 Hz against 1 kHz; this high-pass is -12.6, -24.1 and
  -41.8 dB there.
- Because the volume comes first, the limiter also holds the output at
  -1 dBFS when a desktop sets the sink above 100 %.

## Measured on the J873g

This is the graph's digital output, recorded from its playback stream with
the amplifier muted, for full-scale stereo input at a sink volume of 100 %:

| Input | Output |
|---|---|
| 30 / 50 / 70 / 100 Hz sine | -41.8 / -24.1 / -12.6 / -3.0 dB |
| 150 Hz to 5 kHz sine | peak -1.00 dBFS |
| 200 Hz square wave | peak -1.25 dBFS |
| 1 kHz sine, left channel only | -6.0 dB |

The highest sample of the whole run is -1.00 dBFS.

## No raw speaker node

Do not expose `hw:AppleJ873,1` as a sink yourself (a hand-made PipeWire
node, a pro-audio profile, `aplay`). That path has no protection.
