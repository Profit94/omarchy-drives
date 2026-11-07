#!/usr/bin/env python3
"""Builds sounds/attach.wav and sounds/detach.wav: short robot-plus-rocket cues.

attach: thruster hiss swells in under a bit-crushed square chirp that climbs
        and locks on with two quick blips (docking).
detach: a thruster burst at full power, a robot sweep falling away beneath it,
        and a low blip as it leaves (launch).

Run: python3 tools/make-sounds.py   (needs numpy; output is 16-bit mono 48 kHz)
"""
import os
import wave

import numpy as np

RATE = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sounds")
rng = np.random.default_rng(7)  # fixed seed, so a rebuild gives the same files


def t_of(sec):
    return np.arange(int(RATE * sec)) / RATE


def sweep(f0, f1, sec, curve=2.0):
    """Phase of a pitch glide from f0 to f1 (exponential-ish when curve > 1)."""
    t = t_of(sec)
    x = t / sec
    f = f0 + (f1 - f0) * (x ** curve if f1 > f0 else 1 - (1 - x) ** curve)
    return 2 * np.pi * np.cumsum(f) / RATE


def square(phase, duty=0.5):
    return np.where((phase / (2 * np.pi)) % 1 < duty, 1.0, -1.0)


def crush(x, bits=5, hold=6):
    """Robot grit: fewer levels and a sample-and-hold."""
    q = 2 ** (bits - 1)
    x = np.round(x * q) / q
    return np.repeat(x[::hold], hold)[: len(x)]


def lowpass(x, cutoff):
    """One-pole low-pass; cutoff may be an array (a moving filter)."""
    cutoff = np.broadcast_to(cutoff, x.shape)
    a = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a[i] * (x[i] - acc)
        y[i] = acc
    return y


def env(n, attack, release):
    e = np.ones(n)
    a, r = int(RATE * attack), int(RATE * release)
    if a:
        e[:a] = np.linspace(0, 1, a) ** 2
    if r:
        e[-r:] *= np.linspace(1, 0, r) ** 2
    return e


def place(buf, clip, at):
    i = int(RATE * at)
    buf[i : i + len(clip)] += clip[: len(buf) - i]


def blip(freq, sec, duty=0.25):
    c = square(sweep(freq, freq * 1.02, sec), duty)
    return crush(c, 4, 4) * env(len(c), 0.002, sec * 0.6)


def finish(x, rms_db=-16.5, ceiling_db=-1.0):
    """Same loudness (RMS) for every cue, not same peak: the launch's short
    burst peaked as high as the dock but sounded about 4 dB quieter."""
    x = x - np.mean(x)
    x *= env(len(x), 0.003, 0.012)  # no clicks at either end
    x *= 10 ** (rms_db / 20) / max(1e-9, np.sqrt(np.mean(x ** 2)))
    ceiling = 10 ** (ceiling_db / 20)
    return np.tanh(x / ceiling) * ceiling if np.max(np.abs(x)) > ceiling else x


def attach():
    dur = 0.38
    out = np.zeros(int(RATE * dur))
    # Thruster: noise whose filter opens as it swells, cut sharply at lock-on.
    n = int(RATE * 0.26)
    hiss = lowpass(rng.standard_normal(n), np.linspace(500, 4500, n))
    hiss *= np.linspace(0, 1, n) ** 1.5 * env(n, 0.0, 0.03)
    place(out, hiss * 0.9, 0.0)
    # Robot chirp climbing 260 -> 1500 Hz.
    ph = sweep(260, 1500, 0.22, 2.2)
    chirp = crush(square(ph, 0.35) * 0.6 + np.sin(ph) * 0.4, 5, 5)
    place(out, chirp * env(len(chirp), 0.01, 0.03) * 0.55, 0.02)
    # Lock-on: two rising blips.
    place(out, blip(1320, 0.05), 0.25)
    place(out, blip(1980, 0.08), 0.30)
    return finish(out)


def detach():
    dur = 0.40
    out = np.zeros(int(RATE * dur))
    # Thruster burst: loud at once, filter closing as it flies away.
    n = int(RATE * 0.36)
    hiss = lowpass(rng.standard_normal(n), np.geomspace(5000, 300, n))
    hiss *= env(n, 0.004, 0.0) * np.exp(-np.linspace(0, 4, n))
    place(out, hiss * 1.1, 0.0)
    # Robot sweep falling 1500 -> 180 Hz.
    ph = sweep(1500, 180, 0.30, 1.8)
    fall = crush(square(ph, 0.35) * 0.6 + np.sin(ph) * 0.4, 5, 5)
    place(out, fall * env(len(fall), 0.003, 0.08) * 0.55, 0.0)
    # Departure blip, low.
    place(out, blip(330, 0.06, 0.5) * 0.7, 0.32)
    return finish(out)


def write(name, x):
    os.makedirs(OUT, exist_ok=True)
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    write("attach.wav", attach())
    write("detach.wav", detach())
