#!/usr/bin/env python3
"""Synthesize the Sound Alerts test fixtures: mono 16 kHz 16-bit WAV, <= 3 s.

Everything here is generated from first principles (no recordings), so the
files are CC0 / public domain by construction.
"""
import math
import struct
import sys
import wave
from pathlib import Path

import numpy as np

SR = 16000
rng = np.random.default_rng(1234)


def write_wav(path: Path, samples: np.ndarray) -> None:
    samples = np.clip(samples, -1.0, 1.0)
    data = (samples * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)


def t(seconds: float) -> np.ndarray:
    return np.arange(int(seconds * SR)) / SR


def room(x: np.ndarray, decay: float = 0.25, taps: int = 6, gain: float = 0.35) -> np.ndarray:
    """A crude early-reflection reverb so tones don't sound anechoic."""
    out = x.copy()
    for i in range(1, taps + 1):
        delay = int(SR * (0.011 * i + 0.003 * rng.random()))
        g = gain * math.exp(-i / (taps * decay * 4))
        out[delay:] += g * x[:-delay] if delay > 0 else 0
    return out


def smoke_alarm(duration: float = 3.0) -> np.ndarray:
    """T3 pattern: three 0.5 s beeps with 0.5 s gaps, then a pause. Piezo at
    ~3.2 kHz with harsh harmonics and a slight chirp, like a real detector."""
    n = int(duration * SR)
    out = np.zeros(n)
    f0 = 3200.0
    for k in range(3):
        start = int(k * 1.0 * SR)
        tt = t(0.5)
        # Piezo buzzers are harmonically rich and slightly frequency-unstable.
        chirp = f0 * (1 + 0.004 * np.sin(2 * math.pi * 7 * tt))
        phase = 2 * math.pi * np.cumsum(chirp) / SR
        tone = (
            1.0 * np.sin(phase)
            + 0.35 * np.sin(2 * phase)
            + 0.15 * np.sin(3 * phase)
            + 0.08 * np.sign(np.sin(phase))
        )
        # Fast attack / release envelope.
        env = np.ones_like(tt)
        a = int(0.005 * SR)
        env[:a] = np.linspace(0, 1, a)
        env[-a:] = np.linspace(1, 0, a)
        seg = tone * env
        out[start:start + len(seg)] += seg
    out = room(out, decay=0.4, gain=0.25)
    out += 0.003 * rng.standard_normal(n)
    return 0.8 * out / np.max(np.abs(out))


def door_bell(duration: float = 3.0) -> np.ndarray:
    """Two-tone mechanical chime ('ding-dong'): struck tone bars with the
    non-harmonic overtones of a free bar and a long decay."""
    n = int(duration * SR)
    out = np.zeros(n)

    def bar(freq: float, start_s: float, length_s: float, level: float) -> None:
        tt = t(length_s)
        partials = [(1.0, 1.0, 1.0), (2.756, 0.36, 1.8), (5.404, 0.144, 2.6), (8.933, 0.048, 3.5)]
        sig = np.zeros_like(tt)
        for ratio, amp, dec in partials:
            sig += amp * np.sin(2 * math.pi * freq * ratio * tt) * np.exp(-dec * 1.8 * tt)
        # Strike transient.
        strike = rng.standard_normal(len(tt)) * np.exp(-tt * 150) * 0.2
        sig += strike
        start = int(start_s * SR)
        end = min(n, start + len(sig))
        out[start:end] += level * sig[: end - start]

    bar(880.0, 0.05, 2.9, 1.0)   # ding (A5)
    bar(698.0, 0.65, 2.3, 0.95)  # dong (F5)
    out = room(out, decay=0.5, gain=0.2)
    out += 0.002 * rng.standard_normal(n)
    return 0.85 * out / np.max(np.abs(out))


def bandpass_noise(n: int, lo: float, hi: float) -> np.ndarray:
    x = rng.standard_normal(n)
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(n, 1 / SR)
    mask = (freqs >= lo) & (freqs <= hi)
    spec[~mask] = 0
    y = np.fft.irfft(spec, n)
    return y / (np.max(np.abs(y)) + 1e-9)


def knock(duration: float = 3.0) -> np.ndarray:
    """Knuckles on a wooden door: five short broadband impacts with a faint
    panel thud, in a dry room."""
    n = int(duration * SR)
    out = np.zeros(n)
    for start_s in (0.5, 0.82, 1.12, 1.45, 1.78):
        tt = t(0.18)
        impact = bandpass_noise(len(tt), 150, 2500) * np.exp(-tt * 90)
        thud = (np.sin(2 * math.pi * 95 * tt) * np.exp(-tt * 45)
                + 0.5 * np.sin(2 * math.pi * 160 * tt) * np.exp(-tt * 55))
        sig = impact * 0.9 + thud * 0.5
        sig *= 0.8 + 0.2 * rng.random()
        start = int(start_s * SR)
        out[start:start + len(sig)] += sig
    out = room(out, decay=0.3, gain=0.15)
    out += 0.002 * rng.standard_normal(n)
    return 0.9 * out / np.max(np.abs(out))


def silence(duration: float = 3.0) -> np.ndarray:
    """A quiet room: very low-level noise floor only."""
    n = int(duration * SR)
    return 0.0005 * rng.standard_normal(n)


def main(out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_wav(out / "smoke_alarm.wav", smoke_alarm())
    write_wav(out / "doorbell.wav", door_bell())
    write_wav(out / "knock.wav", knock())
    write_wav(out / "silence.wav", silence())
    for p in sorted(out.glob("*.wav")):
        print(p.name, p.stat().st_size, "bytes")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "out")
