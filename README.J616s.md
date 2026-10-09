# J616s audio evidence and device names

This is a development reference for the tested Mac16,7 / J616sAP, chip
0x6040, board 6. It does not add J616s to the supported-device list.

## Observed devices and routes

The native macOS inventory captured on 2026-10-08 names these devices:

| Native display name | Direction | Observed role |
| --- | --- | --- |
| MacBook Pro Microphone | Input | Internal microphone array |
| External Microphone | Input | Headset microphone |
| External Headphones | Output | Headphone jack |
| MacBook Pro Speakers | Output | Internal speakers |

These are observed macOS names, not Linux ALSA card IDs or PCM names.
The saved ADT identifies the jack codec as `audio-control,cs42l84` at
`i2c2/audio-codec-output`, address 0x4b. It describes six speaker nodes
compatible with `audio-control,sn012776`: three on i2c1 at 0x38–0x3a and
three on i2c3 at 0x3b–0x3d. Those compatibility strings and addresses describe
topology; they do not establish an amplifier initialization sequence.

## Qualified capture evidence

The proxy bring-up establishes separate cold captures, not Linux streaming:

| Route | Proven proxy sample contract |
| --- | --- |
| Internal high-power microphone, `hpai` | Three-channel Float32LE, nominal 48 kHz; completed 2 MiB and 6 MiB captures |
| Headset microphone, `cin ` | Mono 24-bit samples in 32-bit slots, nominal 48 kHz; completed 2 MiB capture |

The trailing space in `cin ` is part of the firmware device identifier.
Nominal rates are profile values, not measured clock accuracy. Continuous
streaming, restart, and calibration are not established by these captures.
No working proxy playback or Linux playback is claimed here.

## Sources and implementation boundary

Published proxy evidence: [bring-up](https://github.com/aurora-silicon/m1n1/blob/f898ab3ddeae96e78f7843da41761578e8ba757b/docs/j616s-bringup.md)
and [driver contracts](https://github.com/aurora-silicon/m1n1/blob/f898ab3ddeae96e78f7843da41761578e8ba757b/docs/j616s-driver-contracts.md), as retained in
[m1n1 draft PR 20](https://github.com/aurora-silicon/m1n1/pull/20).
The native display names and codec topology above come from the local
2026-10-08 macOS inventory and saved J616s ADT reviewed for this draft;
the underlying native capture is not included in this repository.

Linux card IDs, driver names, PCM indices, control names, and jack controls
must be observed on a working J616s Linux driver before runtime configuration
can use them. J700's card names, two-channel microphone processing, and
speaker settings are not evidence for J616s.

This document supplies names and capture facts for future DSP work. It adds
no WirePlumber match, filter graph, gain, EQ, impulse response, or speaker
protection setting. Speaker DSP requires separate measured evidence.
