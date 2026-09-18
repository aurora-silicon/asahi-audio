# MacBook Neo J700 — speakers, headphones and microphones

This addition needs the matching J700 UCM entries from alsa-ucm-conf-asahi.
It is built from upstream f5b118a8a2fb150b145cb667b4738cdab0304eb0.

## Speakers

`hw:AppleJ700,1` is the raw speaker device (one MAX98360A per channel on the
AOP's LEAP serializer, S32LE at 48 kHz only).  As on every other Mac the
generic rule renames it `alsa_output.platform-sound.RawSpeakers` and the
`node.software-dsp` rule wraps it in `firs/j700/graph.json`, which is the
user-visible "MacBook Neo J700 Speakers" sink.  The graph has the usual shape
(bankstown bass extension, equal-loudness compensation carrying the sink
volume, a convolver per channel, the woofer band compressor and the final
limiter).  `firs/j700/48.wav` is a first correction measured on the
machine: an exponential sine sweep (100 Hz - 7.5 kHz, -50 dBFS on the wire)
recorded by the internal low-power microphone and deconvolved; only the
broad presence peaks (1.6 kHz, 2.5-3.2 kHz) and the mild rise above 5 kHz
are corrected, by a few dB, as a minimum-phase 2048-tap IR.  The internal
microphone is not a listener position, so this is deliberately gentle and
should be replaced by a measurement in front of the laptop; the
bankstown/compressor settings are provisional for the same reason.  The
graph only lists 48 kHz because the hardware path is fixed at that rate.

The kernel limits the raw device to -20 dBFS on the wire and holds its
"Speaker Playback Volume" 20 dB lower until a speaker-protection daemon
takes the volume lock; that control is not a PipeWire route volume and is
never touched by this configuration.

`conf/j700.conf` is strict JSON, which is a subset of WirePlumber's SPA-JSON
configuration format. `make core` installs it as `99-asahi-j700.conf` next to
the existing Asahi configuration. The file adds only exact J700/NeoMic matches.

The headphone **device route** initial volume is 10^(-50/20), or -50 dB relative
to jack full scale. This is `device.routes.default-sink-volume`, not the stream
property `state.default-volume`. Existing saved user volumes take precedence;
the profile does not impose a headphone ceiling or erase user state.
See https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/settings.html
and https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/modifying_configuration.html .

The jack hardware uses ALSA S24_LE (24 valid low bits in each 32-bit word),
which is PipeWire S24_32LE, at 48 kHz: stereo output and mono headset input.
The separate `AppleJ700LPAI` card (the low-power microphone) uses S32LE at 16 kHz with two channels. Its measured
geometry and actual ALSA long name come from the J700 kernel and hb44 capture.
No gain, beamforming or speaker DSP has been invented for the uncalibrated paths.

The UCM profile enables the headset ADC HPF and leaves boost off. A user who
needs extra microphone gain can explicitly enable `Jack ADC Boost Switch`;
UCM restores boost off when re-enabling the headset/HiFi route.

Target acceptance, when transport returns:

1. With an isolated test user's WirePlumber state, load the matching UCM and
   this configuration from tmpfs; do not alter the read-only installed root.
2. Inspect `alsaucm -c hw:AppleJ700 dump text` and `alsaucm -c hw:AppleJ700LPAI dump text`.
3. Start PipeWire/WirePlumber with no application playback. Check `wpctl status`
   and `pw-dump`: headphones, headset microphone and internal microphone only;
   no speaker route. Confirm ALSA path, format, channels and rate on each node.
4. Confirm headphone initial effective volume is -50 dB and the saved-volume
   behavior works across a route switch. Inspect the HPF/boost mixer controls.
5. Check jack unplug/replug routing and capture both microphones. Audible tests
   remain separate, attended tests with the established low-level source files.

Do not claim this profile is deployed or hardware-validated until these pass.
