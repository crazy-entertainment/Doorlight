`voice-aac-lc.m4a` is a generated one-second 440 Hz sine wave, encoded as
mono 48 kHz AAC-LC at a requested 96 kbit/s. It contains no recorded speech.
It exercises the voice validator against an independently written M4A file,
including AAC priming, roll recovery and final-frame padding.

Generated with FFmpeg 2026-08-09 git-6bbc22dc09 (gyan full build):

```text
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=1 -ac 1 -c:a aac -b:a 96k -map_metadata -1 voice-aac-lc.m4a
```

FFmpeg is a development fixture generator, not an application recording or
transcoding dependency. Actual Windows and Android recorder outputs still need
platform acceptance checks.
