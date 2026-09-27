Pre-generated coaching cues (Tencent Cloud TTS) go here as `<cue-key>.mp3`.

Generate them with:

    cd Server && swift run LaileServer generate-cues --output ../iOS/Laile/Resources/Cues

When a cue file is missing the app falls back to on-device speech synthesis.
