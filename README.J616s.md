# J616s audio evidence and device names

This is a development reference for Mac16,7 / J616sAP, chip 0x6040,
board 6. No J616s Linux boot, audio card, PCM or mixer ABI has been qualified.

## Observed devices and routes

The native macOS inventory captured on 2026-10-08 names these devices:

| Native display name | Direction | Observed role |
| --- | --- | --- |
| MacBook Pro Microphone | Input | Internal microphone array |
| External Microphone | Input | Headset microphone |
| External Headphones | Output | Headphone jack |
| MacBook Pro Speakers | Output | Internal speakers |

These are macOS display names, not Linux ALSA card IDs or PCM names.
The saved ADT identifies the jack codec as `audio-control,cs42l84` at
`i2c2/audio-codec-output`, address 0x4b.

The master `audio-speaker` links six `audio-control,sn012776` amplifiers
in this native provider order:

| Index | Native speaker role | Bus/address | Audible proxy evidence |
| --- | --- | --- | --- |
| 0 | Left woofer 1 | i2c1:0x38 | Separate pulse and paired five-second playback |
| 1 | Right woofer 1 | i2c3:0x3b | Separate pulse and paired five-second playback |
| 2 | Left woofer 2 | i2c1:0x39 | Not tested acoustically |
| 3 | Right woofer 2 | i2c3:0x3c | Not tested acoustically |
| 4 | Left tweeter | i2c1:0x3a | Not tested acoustically |
| 5 | Right tweeter | i2c3:0x3d | Not tested acoustically |

The index is a native provider index, not an ALSA channel assignment.
All six passed identity reads and native protected shutdown configuration;
neither result qualifies protection efficacy or all-six acoustic output.

## Qualified proxy evidence

These are separate bounded proxy tests, not Linux streaming tests:

| Route | Observed contract and result |
| --- | --- |
| High-power internal microphone, `hpai` | Three-channel Float32LE, nominal 48 kHz; completed 2 MiB and 6 MiB captures with user-recognized audio |
| Low-power internal microphone, `lpai` | Producer reports use 12-byte frames; a reconstructed normalized preview contains recognizable speech, with snapshot-boundary integrity still unqualified |
| Headset microphone, `cin ` | Mono 24-bit samples in 32-bit slots, nominal 48 kHz; completed capture with recognizable audio |
| Headphones, `cout` | Stereo 24-bit samples in 32-bit slots, nominal 48 kHz; finite left/right tones heard, with codec/controller restoration passing |
| Speakers, `spkr` | Six 24-bit playback samples in 32-bit slots, nominal 48 kHz; first left/right woofers heard separately and together for five seconds |

The trailing space in `cin ` is part of the firmware identifier.
Nominal rates are profile values, not measurements of clock accuracy.
Preserve the original HQ float samples; a normalized mono preview is not
calibration or beamforming. LP reconstruction does not establish three
independent microphones.

Speaker playback uses MCA group 0 / `ms00`, ADMAC TX0 and mapper stream 8.
Feedback is described as twelve 16-bit slots on RX1, but its native
sample-width field is zero. Signedness, packing, I/V channel mapping,
scales and feedback frame integrity have not been qualified. Slot width
alone does not establish an ALSA sample format or a speakersafetyd model.

The separate first-woofer pulses passed their bounded transfer and cleanup.
The paired five-second test completed its matching DMA report with zero
residue and DART faults; both post-report mute writes and TX configuration
restoration passed. A later I2C STOP-completion timeout in amplifier shutdown
prevented complete cleanup. Resources were retained until validated watchdog
recovery. Audible paired playback does not qualify reliable repeated cleanup
or continuous streaming. The observed codec-control midpoint is not a
calibrated macOS or Linux volume-slider percentage.

## Linux test admission

Collect these from the first working J616s Linux audio driver before
writing runtime configuration:

- Exact kernel, firmware and device-tree revisions; successful probe logs
  and relevant deferred-probe, I2C, DMA and IOMMU faults.
- ALSA card ID and driver, playback/capture PCM names and indices, supported
  formats, rates and channel counts, and each route's channel order.
- Full mixer control names, types, ranges, dB metadata and jack event behavior.
- Separate input and headphone tests with bounded stop/restart checks;
  concurrency needs its own evidence.
- For speakers, all-six routing and reliable stop/shutdown, qualified I/V
  feedback, measured protection parameters and a working kernel/daemon
  volume interlock before a speaker profile can be enabled.

Listing `/proc/asound/cards`, `/proc/asound/pcm`, `aplay -l`,
`arecord -l` and mixer contents is inventory collection, not audio
qualification. Read the mixer only after selecting an observed card ID.
Do not infer PCM indices from proxy ADMAC channels.

J700's card IDs, two-channel microphone processing, MAX98360A speaker path
and feed-forward speakerguardd model do not describe J616s. Existing
six-speaker configurations also have their own provider/channel ordering
and calibration; their geometry does not qualify J616s.

## Sources and implementation boundary

Published proxy evidence:
[bring-up](https://github.com/aurora-silicon/m1n1/blob/2480cc5f7def1b7124ffd5d25d56305f57462942/docs/j616s-bringup.md)
and
[driver contracts](https://github.com/aurora-silicon/m1n1/blob/2480cc5f7def1b7124ffd5d25d56305f57462942/docs/j616s-driver-contracts.md),
retained in [m1n1 draft PR 20](https://github.com/aurora-silicon/m1n1/pull/20).
The native display names and codec topology come from the local 2026-10-08
macOS inventory and saved J616s ADT reviewed for this draft; the underlying
native capture is not included here.

This reference stages the evidence and acceptance checklist for DSP work.
It adds no supported-device entry, WirePlumber match, filter graph, gain, EQ,
impulse response or protection setting. A J616s microphone graph must first
preserve the proven three-channel float input, then use measured processing.
Speaker EQ, crossover and Bankstown settings require measured response,
headroom and distortion with qualified speaker protection; an audible
300 Hz tone does not supply those measurements.
