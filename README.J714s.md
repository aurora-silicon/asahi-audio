# MacBook Pro J714s (14", M5 Pro)

## Microphones

The three-microphone array is PCM 0 of the AOP card "MacBook Pro J714 HPAI"
(`hw:AppleJ714HPAI,0`): three float32 channels at 48 kHz, unprocessed and at
unity gain, far below the level desktops expect. Its graph is not shipped
here: it is built on the machine from that Mac's own macOS audio tuning,
which the installer copies to `/lib/firmware/vendor/apple/audio-tuning`
(speakerguardd v2 reads the same bundle for the speakers):

    /usr/lib/asahi-audio/mic-from-tuning --path hw:AppleJ714HPAI,0 --name j714 \
        --description "MacBook Pro J714 Microphone" --card "MacBook Pro J714" \
        --out /var/lib/asahi-audio/j714
    ln -s /var/lib/asahi-audio/j714/wireplumber.conf \
        /etc/wireplumber/wireplumber.conf.d/60-asahi-j714-mic.conf

The tool takes the per-microphone trims, the fixed gains, the DC blocker and
the input volume range of the tuning's default input mode, averages the
microphones and writes the graph and a WirePlumber fragment that attaches it
(and gives the headphone jack the tuning's initial volume). The beamformer,
noise suppression and EQ of macOS are not reproduced. Without a tuning bundle
the array stays raw.

## Headphone jack

The jack is PCM 0 of the built-in card "MacBook Pro J714"; the speakers are
speakerguardd v2's voicing sink, a node of their own. When something is
plugged in, `asahi-jack-switch.lua` makes the jack the default sink (and a
headset microphone the default source); on removal WirePlumber returns to the
previous default.
