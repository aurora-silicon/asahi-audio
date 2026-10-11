# MacBook Neo J700 — speakers, headphones and microphones

This addition needs the matching J700 UCM entries from alsa-ucm-conf-asahi.
It is built from upstream f5b118a8a2fb150b145cb667b4738cdab0304eb0.

The J700 is set up like the other Asahi laptops. Users see these devices:

| Device | Node | Available |
|---|---|---|
| "MacBook Neo J700 Speakers" | `audio_effect.j700-convolver` (DSP sink) | always |
| "Built-in Audio Headphones" | UCM `Headphones` on `hw:AppleJ700,0` | while headphones are plugged in |
| "MacBook Neo J700 Microphone" | `effect_output.j700-mic` (DSP source) | always; the default microphone |
| "Built-in Audio Headset Microphone" | UCM `Headset` on `hw:AppleJ700,0` | while a headset is plugged in |

The raw speaker and microphone-array nodes are hidden behind their DSP
filters, the same way as on the other machines. The J700 rules are part of
`conf/wireplumber.conf`; there is no separate J700 configuration file.

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

## Headphones and headset microphone

The 3.5 mm jack is a CS42L83 on `hw:AppleJ700,0`, described by the shared
laptop UCM verb, so the nodes, names and priorities are the stock ones.
The jack uses ALSA S24_LE (PipeWire S24_32LE) at 48 kHz: stereo output and
mono headset input.  The jack-detect controls make both routes available
only while something is plugged in.

The J700-specific part is the initial headphone volume: 0.001, or -60 dB
relative to jack full scale, which desktop volume sliders (cubic scale)
show as 10 %.  It is set with `device.routes.default-sink-volume` on the
card device.  A volume the user has already set takes precedence, and
there is no ceiling.

WirePlumber only selects routes that are available, so with nothing in
the jack the headphone node would get no route and report 100 % until
something is plugged in.  `asahi-unplugged-routes.lua`, enabled for this
card with `asahi.routes.select-unplugged`, selects the unplugged
headphone route anyway, so the node always shows the volume the
headphones will get: the stored one, or the default above.

## Microphones

The microphones are on a second, capture-only card, `AppleJ700AOP` (driver
`t8140-aop-audio`, long name "MacBook Neo J700 AOP Audio"), not on macaudio.

**The microphone array** is PCM 1, `hpai`: two capsules, float32 (PipeWire
F32LE) at 48 kHz only.  It is the card's only UCM device ("Mic").  Like the
`AppleJxxxHPAI` cards of the other laptops, it is renamed
`alsa_input.platform-sound.RawMics`, hidden, and wrapped by the
`node.software-dsp` rule in `firs/j700/mic.json`.  The result is the
"MacBook Neo J700 Microphone" source, at the same priority as the other
machines' microphones.  The filter averages the two capsules, adds +24 dB of
make-up gain in two stages and applies the usual 120 Hz high-pass.  There is
no beamformer for a two-capsule array, and the gain is provisional until it
is calibrated against the other machines.

**The low-power microphone** is PCM 0, `lpai`.  It is not a user device:
it is absent from the UCM verb, and a WirePlumber rule disables any node on
PCM 0 of `AppleJ700AOP`, so no profile of the card (not even pro-audio) shows it.
It exists for developers working on always-on, low-power features such as
wake-word detection.

* ALSA device `hw:AppleJ700AOP,0`, capture only: S32_LE, 16 kHz, two
  channels, in fixed 200 ms periods (3200 frames, a buffer of two to four
  periods), for example:

      arecord -D hw:AppleJ700AOP,0 -f S32_LE -r 16000 -c 2 -d 5 lpmic.wav

* For a PipeWire source, link `firs/j700/lpmic-developer.conf` (installed as
  `/usr/share/asahi-audio/j700/lpmic-developer.conf`) into
  `~/.config/pipewire/pipewire.conf.d/` and restart `pipewire` and
  `wireplumber`; the file has the exact commands.  This adds "Aurora
  Low-Power Microphone (developer)" (`alsa_input.j700-lpmic-developer`) at
  priority 1, so it never becomes the default while the array exists.
  Remove the link to turn it off again.

A WirePlumber state that saved the `pro-audio` profile for the AOP card
bypasses UCM and with it the microphone filter.  Select the card's default
profile (HiFi) again to get the "MacBook Neo J700 Microphone" back.
