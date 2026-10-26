#!/usr/bin/env python3 -I
"""Synthetic meeting fixture from macOS `say` voices.

Writes <out>/synth-mic.wav, synth-sys.wav, synth-mix.wav (16 kHz mono PCM16),
synth.m4a (48 kHz stereo AAC: L = mic, R = system) and synth-script.json.
Usage: python3 -I scripts/make-fixture.py <out_dir> [ffmpeg_path]
"""
import json, os, struct, subprocess, sys, wave

out = sys.argv[1]
ffmpeg = sys.argv[2] if len(sys.argv) > 2 else "ffmpeg"
lines_dir = os.path.join(out, "lines")
os.makedirs(lines_dir, exist_ok=True)
RATE = 16000
GAP = 0.8

# (track, voice, spoken name or None, text)
LINES = [
    ("mic", "Samantha", "Ethan",  "Hi everyone, thanks for joining. Let's get started with the roadmap review."),
    ("sys", "Daniel",   "Daniel", "Thanks Ethan. This is Daniel from the platform team. We shipped the new ingest pipeline last week."),
    ("sys", "Karen",    "Karen",  "Hi all, Karen here. Quick question for Daniel: did the latency numbers improve after the rollout?"),
    ("sys", "Daniel",   "Daniel", "Yes Karen, they did. P ninety five dropped from four hundred milliseconds to about one hundred and twenty."),
    ("mic", "Samantha", "Ethan",  "That's great news. Moira, can you share the status on the billing migration?"),
    ("sys", "Moira",    "Moira",  "Sure. The migration is on track and we expect to finish by the end of next week."),
    ("sys", "Tessa",    None,     "One more thing before we close. The release notes still need a review before Friday."),
    ("mic", "Samantha", "Ethan",  "Good point, I'll take that. Let's wrap up. Thanks Daniel, Karen and Moira."),
    ("sys", "Daniel",   "Daniel", "Thanks everyone, talk soon."),
]

def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == RATE, path
        n = w.getnframes()
        return list(struct.unpack("<%dh" % n, w.readframes(n)))

tracks = {"mic": [], "sys": []}
script = []
t = GAP
for i, (track, voice, name, text) in enumerate(LINES):
    aiff = os.path.join(lines_dir, f"{i:02d}.aiff")
    wav = os.path.join(lines_dir, f"{i:02d}.wav")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav], check=True)
    samples = read_wav(wav)
    start = int(t * RATE)
    for k in tracks:
        if len(tracks[k]) < start:
            tracks[k].extend([0] * (start - len(tracks[k])))
    tracks[track].extend(samples)
    script.append({"index": i, "track": track, "voice": voice, "name": name,
                   "start": round(start / RATE, 3), "end": round((start + len(samples)) / RATE, 3), "text": text})
    t = (start + len(samples)) / RATE + GAP

total = max(len(v) for v in tracks.values()) + int(GAP * RATE)
for k in tracks:
    tracks[k].extend([0] * (total - len(tracks[k])))

def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))

mic_path = os.path.join(out, "synth-mic.wav")
sys_path = os.path.join(out, "synth-sys.wav")
mix_path = os.path.join(out, "synth-mix.wav")
write_wav(mic_path, tracks["mic"])
write_wav(sys_path, tracks["sys"])
write_wav(mix_path, [max(-32768, min(32767, a + b)) for a, b in zip(tracks["mic"], tracks["sys"])])
subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", mic_path, "-i", sys_path,
                "-filter_complex", "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]", "-map", "[a]",
                "-ar", "48000", "-c:a", "aac", "-b:a", "192k", os.path.join(out, "synth.m4a")], check=True)
with open(os.path.join(out, "synth-script.json"), "w") as f:
    json.dump(script, f, indent=2)
print(f"fixture: {total / RATE:.1f}s, {len(LINES)} lines → {out}")
