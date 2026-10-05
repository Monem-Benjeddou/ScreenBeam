"""Synthesizes a royalty-free 42 s electronic bed at 120 BPM (one bar = 2 s) for the ScreenBeam promo."""
import wave
import numpy as np
from scipy.signal import butter, sosfilt

SR = 44100
DUR = 42.0
N = int(SR * DUR)
BEAT = 0.5
mix = np.zeros((N, 2))


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def add(sig, start, gain=1.0, pan=0.0):
    i = int(start * SR)
    if i >= N:
        return
    sig = sig[: N - i]
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    mix[i:i + len(sig), 0] += sig * gain * l
    mix[i:i + len(sig), 1] += sig * gain * r


def env(n, a, d_total):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4))
    rel = np.clip((d_total - t) / 0.4, 0, 1)
    return e * rel


# Am - F - C - G, one chord per bar
CHORDS = [[57, 60, 64], [53, 57, 60], [48, 55, 60, 64], [55, 59, 62]]
ROOTS = [45, 41, 48, 43]


def chord_at(bar):
    return bar % 4


# --- Pad: detuned additive tones, brighter as the track opens up
def pad(midi, dur, bright):
    t = np.arange(int(dur * SR)) / SR
    s = np.zeros_like(t)
    for det in (-0.12, 0.12):
        f = hz(midi + det)
        for h in range(1, 7):
            s += np.sin(2 * np.pi * f * h * t + h) / h ** (2.2 - bright)
    return s * env(len(t), 0.6, dur) * 0.05


for bar in range(21):
    t0 = bar * 2.0
    if t0 >= 40:
        break
    bright = 0.2 if t0 < 4 else (0.6 if t0 < 14 else 0.9)
    length = 2.4 if bar < 19 else 4.0
    for k, m in enumerate(CHORDS[chord_at(bar)]):
        add(pad(m, length, bright), t0, 1.0, pan=(k - 1) * 0.4)

# Final chord ring-out
for m in CHORDS[0] + [69]:
    add(pad(m, 2.5, 0.6), 39.5, 1.1)


# --- Kick
def kick():
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 45 + 110 * np.exp(-t * 28)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 7) * 0.9


K = kick()
kick_times = [b * BEAT for b in range(int(DUR / BEAT))
              if (4 <= b * BEAT < 30) or (34 <= b * BEAT < 40)]
for kt in kick_times:
    add(K, kt, 0.85)

# Sidechain duck on everything placed so far (pads), keyed by the kicks
duck = np.ones(N)
for kt in kick_times:
    i = int(kt * SR)
    n = min(int(0.4 * SR), N - i)
    duck[i:i + n] = np.minimum(duck[i:i + n], 0.35 + 0.65 * (np.arange(n) / n) ** 0.6)
kick_layer = np.zeros_like(mix)
for kt in kick_times:
    i = int(kt * SR)
    s = K[: N - i] * 0.85
    kick_layer[i:i + len(s)] += s[:, None] * 0.707
mix = (mix - kick_layer) * duck[:, None] + kick_layer

# --- Bass: root on the off-beat eighths, pumping
for bar in range(21):
    t0 = bar * 2.0
    if not (4 <= t0 < 30 or 34 <= t0 < 40):
        continue
    f = hz(ROOTS[chord_at(bar)])
    for e in range(8):
        start = t0 + e * 0.25 + 0.125
        n = int(0.2 * SR)
        t = np.arange(n) / SR
        s = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t)) * np.exp(-t * 9)
        add(s, start, 0.32)

# --- Hats
rng = np.random.default_rng(7)
sos_hp = butter(4, 7000, "hp", fs=SR, output="sos")
for b in range(int(DUR / 0.25)):
    ht = b * 0.25
    if not (8 <= ht < 30 or 34 <= ht < 40):
        continue
    n = int(0.06 * SR)
    s = sosfilt(sos_hp, rng.standard_normal(n)) * np.exp(-np.arange(n) / SR * 60)
    g = 0.11 if b % 2 else 0.05
    add(s, ht, g, pan=0.3 if b % 4 == 1 else -0.2)

# --- Arp pluck: chord tones in sixteenths, an octave up
for bar in range(21):
    t0 = bar * 2.0
    if not (14 <= t0 < 30 or 34 <= t0 < 40):
        continue
    notes = CHORDS[chord_at(bar)]
    seq = [notes[0], notes[1], notes[2], notes[1] + 12, notes[2], notes[1], notes[0] + 12, notes[2]]
    for s16 in range(16):
        m = seq[s16 % 8] + 12
        n = int(0.22 * SR)
        t = np.arange(n) / SR
        f = hz(m)
        s = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t + 1)) * np.exp(-t * 16)
        add(s, t0 + s16 * 0.125, 0.07, pan=0.5 * np.sin(s16))

# --- Risers into 4 s and 34 s, impacts on arrival
sos_bp_cache = {}
for (a, b) in [(2.0, 4.0), (32.0, 34.0)]:
    n = int((b - a) * SR)
    noise = rng.standard_normal(n)
    out = np.zeros(n)
    chunks = 32
    for c in range(chunks):
        lo, hi = c * n // chunks, (c + 1) * n // chunks
        fc = 400 * (12000 / 400) ** (c / chunks)
        sos = butter(2, [fc * 0.7, min(fc * 1.3, SR / 2 - 100)], "bp", fs=SR, output="sos")
        out[lo:hi] = sosfilt(sos, noise[lo:hi])
    out *= np.linspace(0, 1, n) ** 2 * 0.35
    add(out, a, 1.0)
for at in (4.0, 34.0):
    n = int(1.6 * SR)
    t = np.arange(n) / SR
    boom = np.sin(2 * np.pi * (38 + 40 * np.exp(-t * 6)) * t) * np.exp(-t * 2.5)
    crash = sosfilt(butter(2, 3000, "hp", fs=SR, output="sos"), rng.standard_normal(n)) * np.exp(-t * 3) * 0.12
    add(boom * 0.7 + crash, at, 1.0)

# --- Master: fades, soft clip, normalize
fade_in = np.clip(np.arange(N) / (0.3 * SR), 0, 1)
fade_out = np.clip((N - np.arange(N)) / (1.8 * SR), 0, 1)
mix *= (fade_in * fade_out)[:, None]
mix = np.tanh(mix * 1.4)
mix /= np.max(np.abs(mix)) / 0.89

with wave.open("music.wav", "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
print("music.wav", DUR, "s")
