#!/bin/zsh
# Generates synthetic meeting audio for the integration tests:
#  - system.wav  : two distinct TTS voices alternating (remote participants → diarization)
#  - mic.wav     : one voice (the local user's channel)
# 16 kHz 16-bit mono WAV, concatenated with silence gaps via python's wave module.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/Tests/SKNoteCoreTests/Fixtures"
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gen() { # voice, text, out
    say -v "$1" --file-format=WAVE --data-format=LEI16@16000 -o "$3" "$2"
}

# Remote side (system audio): Samantha = client, Daniel = colleague.
gen "Samantha" "Hello everyone, thanks for joining today's meeting. I want to review the launch checklist for the website redesign project." "$TMP/sys1.wav"
gen "Daniel"   "Sure. The design work is nearly complete, and I will send the revised proposal to the client on Friday." "$TMP/sys2.wav"
gen "Samantha" "That sounds great. Let's also remember that the client prefers weekly check-ins on Friday mornings." "$TMP/sys3.wav"

# Local user (microphone).
gen "Reed (English (US))" "Thanks for the update. I have decided we will ship version one without single sign on." "$TMP/mic1.wav"

python3 - "$TMP" "$DIR" <<'PY'
import sys, wave, os

tmp, out = sys.argv[1], sys.argv[2]
RATE = 16000

def read(path):
    with wave.open(path, 'rb') as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1, path
        return w.readframes(w.getnframes())

def silence(seconds):
    return b'\x00\x00' * int(RATE * seconds)

def write(path, chunks):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        for c in chunks: w.writeframes(c)
    print(f"wrote {path} ({os.path.getsize(path)//1024} KB)")

# System channel: S-voice, gap, D-voice, gap, S-voice.
write(os.path.join(out, 'system.wav'), [
    silence(0.5), read(os.path.join(tmp, 'sys1.wav')),
    silence(1.2), read(os.path.join(tmp, 'sys2.wav')),
    silence(1.2), read(os.path.join(tmp, 'sys3.wav')), silence(0.5),
])

# Mic channel: silence while others talk, then the local user speaks.
# (Rough overlap layout: user talks after sys2 ends.)
write(os.path.join(out, 'mic.wav'), [
    silence(14.0), read(os.path.join(tmp, 'mic1.wav')), silence(0.5),
])
PY
echo "Fixtures ready in $DIR"
