#!/usr/bin/env python3
"""Rebuilds vibeScroll's bundled alert sounds from their source.

Not part of the build: the finished .wav files are committed. This exists so the
provenance of binary assets in the repository is legible and reproducible —
where they came from, under what licence, and exactly which part was kept.

    python3 scripts/make-sounds.py

Requires ffmpeg, only for the WebM decode that CoreAudio will not do.

## Source

https://commons.wikimedia.org/wiki/File:Farting_sound_effects.webm
Uploaded by Atsme, dedicated under the Creative Commons CC0 1.0 Universal
Public Domain Dedication: no attribution required, no share-alike obligation.

CC0 specifically, not merely "free". The CC BY-SA fart recordings on Commons
would carry share-alike into an asset compiled inside an application, and
trimming one changes nothing — a third of a second of a CC BY-SA recording is
still CC BY-SA. Filtering by licence first is what avoids the question; editing
afterwards is not.

## Selection

The source is 32 seconds holding twelve separated sounds. An RMS envelope finds
their boundaries; the four kept below were chosen by listening. They are
deliberately different lengths — a 0.26s clip and a 1.77s one are different
alerts, not the same one twice.
"""

import os
import struct
import subprocess
import sys
import tempfile
import urllib.request
import wave

SOURCE_URL = "https://upload.wikimedia.org/wikipedia/commons/e/e3/Farting_sound_effects.webm"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")

RATE = 44100
PAD = 0.02                  # a little air either side of the burst
FADE_IN = 0.004             # a hard cut at either edge clicks
FADE_OUT = 0.05
PEAK = 0.90                 # loud enough to notice, short of clipping

# (name, start, end) in seconds within the source.
CLIPS = [
    ("Fart 1", 0.87, 1.75),
    ("Fart 2", 3.23, 3.56),
    ("Fart 3", 7.60, 7.82),
    ("Fart 4", 29.04, 30.77),
]


# Wikimedia refuses the default urllib agent outright; their policy asks for one
# that identifies the caller.
USER_AGENT = "vibeScroll-asset-builder/1.0 (https://github.com/alper50/vibeScroll)"


def decode_to_wav(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        source = destination + ".webm"
        with open(source, "wb") as handle:
            handle.write(response.read())
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", source,
         "-ac", "1", "-ar", str(RATE), "-acodec", "pcm_s16le", destination],
        check=True)


def clip(frames, start, end):
    samples = [v / 32768 for v in frames[max(0, int((start - PAD) * RATE)):int((end + PAD) * RATE)]]
    fade_in, fade_out, length = int(FADE_IN * RATE), int(FADE_OUT * RATE), len(samples)
    for i in range(fade_in):
        samples[i] *= i / fade_in
    for i in range(fade_out):
        samples[length - 1 - i] *= i / fade_out
    gain = PEAK / max(abs(v) for v in samples)
    return [v * gain for v in samples]


def write_wav(name, samples):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.normpath(os.path.join(OUT_DIR, f"{name}.wav"))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32768, min(32767, int(v * 32767)))) for v in samples))
    print(f"{os.path.basename(path):<12} {len(samples) / RATE:.2f}s")


if __name__ == "__main__":
    if not subprocess.run(["which", "ffmpeg"], capture_output=True).stdout:
        sys.exit("ffmpeg is required to decode the WebM source.")
    with tempfile.TemporaryDirectory() as tmp:
        decoded = os.path.join(tmp, "source.wav")
        decode_to_wav(SOURCE_URL, decoded)
        with wave.open(decoded) as w:
            frames = struct.unpack(f"<{w.getnframes()}h", w.readframes(w.getnframes()))
        for name, start, end in CLIPS:
            write_wav(name, clip(frames, start, end))
