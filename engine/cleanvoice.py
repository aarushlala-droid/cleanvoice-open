#!/usr/bin/env python3
"""CleanVoice engine: dialogue cleaning for film clips.

Chain: hum notches + low cut -> DeepFilterNet3 -> noise-reduction mix -> EQ -> compression
-> loudness -> true-peak limiter. Video streams are copied, never re-encoded; sources are never modified.

Modes:
  serve                       JSON-lines worker used by the CleanVoice app (requests on stdin, replies on stdout)
  process PATH... [options]   batch export from Terminal
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
import traceback
from collections import OrderedDict

import numpy as np
import soundfile as sf
from scipy import signal
from scipy.ndimage import minimum_filter1d, uniform_filter1d

VERSION = "1.0.0"
SR = 48000
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mxf", ".mts", ".m2ts", ".avi", ".mkv"}
AUDIO_EXT = {".wav", ".bwf", ".aif", ".aiff", ".flac", ".mp3", ".m4a"}
CACHE_DIR = os.path.expanduser("~/Library/Caches/CleanVoice")
OUTPUT_DIR_NAME = "Cleaned for DaVinci"

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
MODELS = {
    "deepfilternet3": "DeepFilterNet 3 (AI, strongest)",
    "deepfilternet2": "DeepFilterNet 2 (AI, alternative)",
    "rnnoise": "RNNoise (light AI)",
    "spectral": "Spectral (classic, most natural, keeps non-voice sounds)",
}
AUTO_EXCERPT_LIMIT = 60.0  # clips longer than this choose their model on a speech excerpt

DEFAULTS = {
    "model": "auto",          # auto | one of MODELS
    "noise_reduction": 28.0,  # dB of background reduction; ignored when full
    "full": False,            # remove all background (silent gaps)
    "hum": "auto",            # auto | 50 | 60 | off
    "low_cut": 80.0,          # Hz high-pass, 0 = off
    "warmth": -2.0,           # dB at 250 Hz
    "clarity": 2.0,           # dB at 3.5 kHz
    "evenness": 0.5,          # compression amount, 0 = off, 1 = strong
    "loudness": -24.0,        # LUFS target, None = keep the cleaned level
    "true_peak": -1.5,        # dBTP ceiling
}
RANGES = {
    "noise_reduction": (0.0, 60.0), "low_cut": (0.0, 200.0), "warmth": (-6.0, 3.0),
    "clarity": (-3.0, 6.0), "evenness": (0.0, 1.0), "loudness": (-31.0, -12.0), "true_peak": (-6.0, 0.0),
}


class EngineError(Exception):
    """An error with a message meant for the user."""


# ---------------------------------------------------------------- settings

def normalise_settings(raw: dict | None) -> dict:
    s = dict(DEFAULTS)
    for k, v in (raw or {}).items():
        if k in s:
            s[k] = v
    for k, (lo, hi) in RANGES.items():
        if s[k] is None and k == "loudness":
            continue
        try:
            s[k] = float(min(hi, max(lo, float(s[k]))))
        except (TypeError, ValueError):
            raise EngineError(f"Invalid value for {k}: {s[k]!r}")
    s["full"] = bool(s["full"])
    hum = str(s["hum"]).lower()
    if hum not in ("auto", "50", "60", "off"):
        raise EngineError(f"Invalid hum setting: {s['hum']!r}")
    s["hum"] = hum
    model = str(s["model"]).lower()
    if model != "auto" and model not in MODELS:
        raise EngineError(f"Unknown model: {s['model']!r}")
    s["model"] = model
    return s


def settings_hash(s: dict) -> str:
    return hashlib.sha1(json.dumps(s, sort_keys=True).encode()).hexdigest()[:12]


# ---------------------------------------------------------------- ffmpeg I/O

def ffmpeg() -> str:
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def probe(path: str) -> dict:
    r = subprocess.run([ffmpeg(), "-hide_banner", "-nostdin", "-i", path], capture_output=True, text=True, errors="replace")
    info = r.stderr
    if "No such file" in info or "Invalid data found" in info:
        raise EngineError("File could not be read")
    dur = re.search(r"Duration: (\d+):(\d+):(\d+\.\d+)", info)
    audio = re.search(r"Stream #\S+.*?: Audio: .*", info)
    video = [ln for ln in re.findall(r"Stream #\S+.*?: Video: .*", info) if "attached pic" not in ln]
    if not audio:
        raise EngineError("No audio track")
    line = audio.group(0)
    ch = 2
    if " mono" in line:
        ch = 1
    elif m := re.search(r"(\d+) channels", line):
        ch = int(m.group(1))
    elif re.search(r"5\.1|7\.1|quad", line):
        ch = 6 if "5.1" in line else (8 if "7.1" in line else 4)
    return {
        "duration": (int(dur[1]) * 3600 + int(dur[2]) * 60 + float(dur[3])) if dur else 0.0,
        "channels": max(1, min(8, ch)),
        "has_video": bool(video),
    }


def decode(path: str, channels: int) -> np.ndarray:
    """Decode to [C, T] float32 at 48 kHz via a memory-mapped temp file (avoids holding pipe buffers twice)."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = os.path.join(CACHE_DIR, f"decode-{os.getpid()}-{time.time_ns()}.f32")
    try:
        cmd = [ffmpeg(), "-v", "error", "-nostdin", "-y", "-i", path, "-map", "0:a:0", "-vn",
               "-ac", str(channels), "-ar", str(SR), "-f", "f32le", tmp]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0 or not os.path.exists(tmp) or os.path.getsize(tmp) == 0:
            raise EngineError("Audio could not be decoded: " + r.stderr.decode(errors="replace").strip()[-300:])
        mm = np.memmap(tmp, dtype=np.float32, mode="r").reshape(-1, channels)
        out = np.empty((channels, mm.shape[0]), dtype=np.float32)
        for c in range(channels):
            out[c] = mm[:, c]
        del mm
        return out
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


# ---------------------------------------------------------------- measurement

def frame_db(x: np.ndarray, hop: int = SR // 20) -> np.ndarray:
    m = x if x.ndim == 1 else x.mean(0)
    n = max(1, len(m) // hop)
    m = m[: n * hop] if len(m) >= hop else np.pad(m, (0, hop - len(m)))
    return 20 * np.log10(np.sqrt(np.mean(m.reshape(n, -1) ** 2, axis=1)) + 1e-6)


_K_SOS = np.array([
    [1.53512485958697, -2.69169618940638, 1.19839281085285, 1.0, -1.69065929318241, 0.73248077421585],
    [1.0, -2.0, 1.0, 1.0, -1.99004745483398, 0.99007225036621],
])


CHUNK = 10 * SR  # chunked processing keeps memory flat on long clips


def sosfilt_chunked(sos: np.ndarray, x: np.ndarray, reverse: bool = False, zi: np.ndarray | None = None) -> np.ndarray:
    """Causal SOS filter over [C, T] float32 audio in chunks (state carried), optionally run backwards in time."""
    C, T = x.shape
    y = np.empty((C, T), dtype=np.float32)
    z = np.zeros((sos.shape[0], C, 2)) if zi is None else zi
    starts = list(range(0, T, CHUNK))
    for a in (reversed(starts) if reverse else starts):
        b = min(T, a + CHUNK)
        seg = x[:, a:b][:, ::-1] if reverse else x[:, a:b]
        out, z = signal.sosfilt(sos, seg, axis=-1, zi=z)
        y[:, a:b] = out[:, ::-1] if reverse else out
    return y


def filtfilt_chunked(sos: np.ndarray, x: np.ndarray) -> np.ndarray:
    """Zero-phase filtering (forward then backward pass) without full-length float64 temporaries."""
    zi0 = signal.sosfilt_zi(sos)[:, None, :]
    y = sosfilt_chunked(sos, x, zi=zi0 * x[:, 0][None, :, None])
    return sosfilt_chunked(sos, y, reverse=True, zi=zi0 * y[:, -1][None, :, None])


def integrated_lufs(x: np.ndarray) -> float:
    """ITU-R BS.1770-4 integrated loudness (channels weighted equally), computed in chunks."""
    C, T = x.shape
    sub = SR // 10  # 100 ms sub-blocks; a 400 ms gating block is 4 of them (75 % overlap)
    n = T // sub
    if n < 4:
        y = signal.sosfilt(_K_SOS, x, axis=-1)
        z = np.array([np.sum(np.mean(y ** 2, axis=-1))])
    else:
        ms = np.zeros(n)
        zi = np.zeros((_K_SOS.shape[0], C, 2))
        for a in range(0, n * sub, CHUNK):
            b = min(n * sub, a + CHUNK)
            y, zi = signal.sosfilt(_K_SOS, x[:, a:b], axis=-1, zi=zi)
            ms[a // sub: b // sub] = (y ** 2).reshape(C, -1, sub).mean(2).sum(0)
        z = np.convolve(ms, np.ones(4) / 4, mode="valid")
    lk = -0.691 + 10 * np.log10(z + 1e-12)
    z = z[lk > -70]
    if not len(z):
        return -70.0
    rel = -0.691 + 10 * np.log10(z.mean()) - 10
    z = z[-0.691 + 10 * np.log10(z) > rel]
    return float(-0.691 + 10 * np.log10(z.mean())) if len(z) else -70.0


def true_peak_env(x: np.ndarray, chunk: int = 10 * SR) -> np.ndarray:
    """Per-sample true-peak magnitude (4x oversampled, max over channels), computed in chunks."""
    T = x.shape[-1]
    out = np.empty(T, dtype=np.float32)
    pad = 64
    for s in range(0, T, chunk):
        a, b = max(0, s - pad), min(T, s + chunk + pad)
        os4 = np.abs(signal.resample_poly(x[:, a:b], 4, 1, axis=-1)).max(0)
        seg = os4[: (b - a) * 4].reshape(-1, 4).max(1)
        out[s: min(T, s + chunk)] = seg[s - a: s - a + min(chunk, T - s)]
    return out


def detect_hum(quiet: np.ndarray) -> dict:
    n = len(quiet)
    nper = 32768 if n >= 32768 else 2 ** int(math.log2(max(1024, n)))
    if n < nper:
        quiet = np.pad(quiet, (0, nper - n))
    f, p = signal.welch(quiet, SR, nperseg=nper)
    pd = 10 * np.log10(p + 1e-20)
    best = {"base": None, "harmonics": [], "score": 0.0}
    for base in (50, 60):
        found, score = [], 0.0
        for k in range(1, 11):
            hz = base * k
            if hz > 600:
                break
            pk = pd[(f >= hz - 2) & (f <= hz + 2)]
            ref = pd[((f >= hz - 15) & (f <= hz - 5)) | ((f >= hz + 5) & (f <= hz + 15))]
            if not len(pk) or not len(ref):
                continue
            prom = float(pk.max() - np.median(ref))
            if prom >= 6:
                found.append((hz, prom))
                score += prom
        # Mains hum shows several harmonics; a lone weak peak is more likely a tonal sound in the scene.
        if len(found) < 2 and not any(p >= 12 for _, p in found):
            found, score = [], 0.0
        found = [hz for hz, _ in found]
        if score > best["score"]:
            best = {"base": base, "harmonics": found, "score": score}
    return {"base": best["base"], "harmonics": best["harmonics"]}


# ---------------------------------------------------------------- processing stages

_DF_MODELS: dict[str, tuple] = {}


def load_df(name: str = "deepfilternet3"):
    if name not in _DF_MODELS:
        import torch
        torch.set_num_threads(max(1, min(8, os.cpu_count() or 4)))
        from df.enhance import init_df
        base = "DeepFilterNet3" if name == "deepfilternet3" else "DeepFilterNet2"
        model, state, _ = init_df(model_base_dir=base, post_filter=True, log_level="WARNING", log_file=None)
        _DF_MODELS[name] = (model, state)
    return _DF_MODELS[name]


def denoise_df(x: np.ndarray, name: str, progress=None) -> np.ndarray:
    """DeepFilterNet at full strength. Long audio runs in 60 s chunks with a warm-up and crossfade."""
    import torch
    from df.enhance import enhance
    model, state = load_df(name)

    def run(seg):
        with torch.no_grad():
            return enhance(model, state, torch.from_numpy(np.ascontiguousarray(seg))).numpy()

    T = x.shape[-1]
    chunk, warm, fade = 20 * SR, SR, SR // 2
    if T <= chunk + warm:
        y = run(x)
        if progress:
            progress(1.0)
        return y
    out = np.zeros_like(x)
    ramp = np.linspace(0, 1, fade, dtype=np.float32)
    start = 0
    while start < T:
        end = min(T, start + chunk)
        if start == 0:
            out[:, :end] = run(x[:, :end])
        else:
            s0 = start - fade - warm
            y = run(x[:, s0:end])[:, warm:]  # y now starts at start - fade
            out[:, start - fade:start] = out[:, start - fade:start] * (1 - ramp) + y[:, :fade] * ramp
            out[:, start:end] = y[:, fade:]
        start = end
        if progress:
            progress(start / T)
    return out


def ffmpeg_filter(x: np.ndarray, af: str) -> np.ndarray:
    """Run float audio [C, T] through an ffmpeg audio filter and re-align the result to the input."""
    C, T = x.shape
    cmd = [ffmpeg(), "-v", "error", "-nostdin", "-f", "f32le", "-ar", str(SR), "-ac", str(C), "-i", "-",
           "-af", af, "-f", "f32le", "-ar", str(SR), "-ac", str(C), "-"]
    r = subprocess.run(cmd, input=np.ascontiguousarray(x.T).tobytes(), capture_output=True)
    if r.returncode != 0:
        raise EngineError("Filter failed: " + r.stderr.decode(errors="replace").strip()[-300:])
    y = np.frombuffer(r.stdout, dtype=np.float32).reshape(-1, C).T
    lag = estimate_lag(x.mean(0), y.mean(0))
    y = y[:, lag:] if lag > 0 else y
    if y.shape[-1] < T:
        y = np.pad(y, ((0, 0), (0, T - y.shape[-1])))
    return np.ascontiguousarray(y[:, :T])


def estimate_lag(a: np.ndarray, b: np.ndarray, max_lag: int = 4096) -> int:
    """Samples by which b is delayed relative to a (0..max_lag), from the loudest 10 s."""
    n = min(len(a), len(b), 10 * SR)
    if n < 2 * max_lag:
        return 0
    corr = signal.correlate(b[:n], a[:n], mode="full", method="fft")
    mid = n - 1
    seg = corr[mid: mid + max_lag + 1]
    return int(np.argmax(seg))


def denoise_ffmpeg(x: np.ndarray, name: str, floor_db: float) -> np.ndarray:
    if name == "rnnoise":
        path = os.path.join(MODEL_DIR, "rnnoise-sh.rnnn")
        if not os.path.exists(path):
            raise EngineError("RNNoise model file missing (engine/models/rnnoise-sh.rnnn)")
        esc = path.replace("\\", "\\\\").replace("'", "\\'").replace(":", "\\:")
        return ffmpeg_filter(x, f"arnndn=m='{esc}':mix=1")
    nf = max(-80.0, min(-20.0, floor_db))
    return ffmpeg_filter(x, f"afftdn=nr=40:nf={nf:.1f}:tn=1")


def run_model(name: str, x: np.ndarray, floor_db: float, progress=None) -> np.ndarray:
    if name in ("deepfilternet3", "deepfilternet2"):
        return denoise_df(x, name, progress)
    y = denoise_ffmpeg(x, name, floor_db)
    if progress:
        progress(1.0)
    return y


# ---------------------------------------------------------------- DNSMOS (automatic quality scoring)

_DNSMOS = None


def dnsmos(x: np.ndarray) -> dict:
    """Microsoft DNSMOS P.835 (non-intrusive): SIG = voice quality, BAK = background, OVRL = overall (1-5)."""
    global _DNSMOS
    if _DNSMOS is None:
        import onnxruntime as ort
        path = os.path.join(MODEL_DIR, "dnsmos_sig_bak_ovr.onnx")
        if not os.path.exists(path):
            raise EngineError("DNSMOS model file missing (engine/models/dnsmos_sig_bak_ovr.onnx)")
        opts = ort.SessionOptions()
        opts.log_severity_level = 3
        _DNSMOS = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
    fs = 16000
    a = signal.resample_poly(x.mean(0) if x.ndim > 1 else x, 1, 3).astype(np.float32)
    need = int(9.01 * fs)
    while len(a) < need:
        a = np.concatenate([a, a])
    hops = int(np.floor(len(a) / fs) - 9.01) + 1
    raw = []
    for i in range(hops):
        seg = a[i * fs: i * fs + need]
        if len(seg) == need:
            raw.append(_DNSMOS.run(None, {"input_1": seg[np.newaxis, :]})[0][0])
    sig, bak, ovr = np.mean(raw, axis=0)
    return {
        "sig": round(float(np.poly1d([-0.08397278, 1.22083953, 0.0052439])(sig)), 2),
        "bak": round(float(np.poly1d([-0.13166888, 1.60915514, -0.39604546])(bak)), 2),
        "ovrl": round(float(np.poly1d([-0.06766283, 1.11546468, 0.04602535])(ovr)), 2),
    }


def pick_best(scores: dict) -> str:
    """Highest overall quality, penalising any model that damages the voice noticeably more than the best one."""
    best_sig = max(v["sig"] for v in scores.values())
    rank = {m: v["ovrl"] - max(0.0, best_sig - v["sig"] - 0.15) for m, v in scores.items()}
    top = max(rank.values())
    # DNSMOS differences under ~0.05 are within its noise: treat as a tie and prefer MODELS order.
    return next(m for m in MODELS if m in rank and rank[m] >= top - 0.05)


def prefilter(x: np.ndarray, low_cut: float, hum_freqs: list[int]) -> np.ndarray:
    sos = []
    if low_cut > 0:
        sos.append(signal.butter(2, low_cut, "highpass", fs=SR, output="sos"))
    for hz in hum_freqs:
        b, a = signal.iirnotch(hz, 30, fs=SR)
        sos.append(signal.tf2sos(b, a))
    if not sos:
        return x.astype(np.float32, copy=True)
    return filtfilt_chunked(np.vstack(sos), x)


def peaking_sos(f0: float, gain_db: float, q: float = 1.0) -> np.ndarray:
    a_ = 10 ** (gain_db / 40)
    w = 2 * math.pi * f0 / SR
    alpha = math.sin(w) / (2 * q)
    b = [1 + alpha * a_, -2 * math.cos(w), 1 - alpha * a_]
    a = [1 + alpha / a_, -2 * math.cos(w), 1 - alpha / a_]
    return signal.tf2sos(b, a)


def compress(x: np.ndarray, evenness: float, speech_db: float) -> np.ndarray:
    if evenness <= 0:
        return x
    ratio = 1 + 3 * evenness
    thr = speech_db - (3 + 9 * evenness)
    blk = SR // 1000
    C, T = x.shape
    n = T // blk
    ms = np.empty(n)
    for a in range(0, n * blk, CHUNK):
        b = min(n * blk, a + CHUNK)
        ms[a // blk: b // blk] = (x[:, a:b] ** 2).reshape(C, -1, blk).mean(axis=(0, 2))
    lvl = 10 * np.log10(uniform_filter1d(ms, 10) + 1e-12)
    target = np.maximum(0.0, lvl - thr) * (1 - 1 / ratio)
    att, rel = math.exp(-1 / 10), math.exp(-1 / 150)
    gr = np.empty(n)
    prev = 0.0
    for i, t in enumerate(target):
        c = att if t > prev else rel
        prev = c * prev + (1 - c) * t
        gr[i] = prev
    centres = np.arange(n) * blk + blk / 2
    for a in range(0, T, CHUNK):  # in place: callers pass an array they own
        b = min(T, a + CHUNK)
        x[:, a:b] *= (10 ** (-np.interp(np.arange(a, b), centres, gr) / 20)).astype(np.float32)
    return x


def limit(x: np.ndarray, ceiling_db: float) -> np.ndarray:
    thr = 10 ** (ceiling_db / 20)
    w = int(0.01 * SR)
    for _ in range(3):
        pk = true_peak_env(x)
        if pk.max() <= thr:
            break
        g = np.minimum(1.0, thr * 0.995 / np.maximum(pk, 1e-9))
        g = uniform_filter1d(minimum_filter1d(g, 2 * w + 1), w)
        x *= g.astype(np.float32)  # in place: callers pass an array they own
    return x


# ---------------------------------------------------------------- clip cache

class Clip:
    def __init__(self, path: str):
        self.path = os.path.abspath(path)
        st = os.stat(self.path)
        self.key = hashlib.sha1(f"{self.path}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()[:16]
        info = probe(self.path)
        self.duration = info["duration"]
        self.channels = info["channels"]
        self.has_video = info["has_video"]
        raw = decode(self.path, self.channels)
        self.duration = raw.shape[-1] / SR
        self.linked = True
        if self.channels > 1:
            sub = raw[:, ::8].astype(np.float64)  # a decimated copy is plenty to tell identical channels apart
            ref = sub[0]
            for c in sub[1:]:
                rms_diff = abs(10 * math.log10((np.mean(c ** 2) + 1e-18) / (np.mean(ref ** 2) + 1e-18)))
                corr = np.corrcoef(ref, c)[0, 1] if np.std(ref) > 0 and np.std(c) > 0 else 1.0
                if corr < 0.98 or rms_diff > 1.0:
                    self.linked = False
                    break
            del sub
        self.work = raw.mean(0, keepdims=True) if self.linked else raw
        db = frame_db(self.work)
        quiet_idx = np.where(db <= np.percentile(db, 15))[0]
        hop = SR // 20
        mono = self.work.mean(0)
        quiet = np.concatenate([mono[i * hop:(i + 1) * hop] for i in quiet_idx]) if len(quiet_idx) >= 10 else mono
        self.hum = detect_hum(quiet)
        self.noise_floor_db = float(np.percentile(db, 10))
        self.voice_db = float(np.percentile(db, 90))
        self.peak_db = float(20 * math.log10(np.abs(raw).max() + 1e-9))
        self.lufs = integrated_lufs(raw)
        self.stages: OrderedDict[tuple, dict] = OrderedDict()
        self.auto: dict[tuple, dict] = {}
        self._pre_key: tuple | None = None
        self._pre: np.ndarray | None = None

    def nbytes(self) -> int:
        n = self.work.nbytes + (self._pre.nbytes if self._pre is not None else 0)
        for st in self.stages.values():
            n += st["enh"].nbytes
        return n

    def hum_freqs(self, s: dict) -> list[int]:
        if s["hum"] == "off":
            return []
        if s["hum"] == "auto":
            return list(self.hum["harmonics"])
        base = int(s["hum"])
        return [base * k for k in range(1, 10) if base * k <= 500]

    def prefiltered(self, s: dict) -> tuple[tuple, np.ndarray]:
        key = (tuple(self.hum_freqs(s)), round(s["low_cut"], 1))
        if key != self._pre_key:
            self._pre = prefilter(self.work, s["low_cut"], list(key[0]))
            self._pre_key = key
        return key, self._pre

    def excerpt(self, x: np.ndarray, windows: int = 3, length: float = 15.0) -> np.ndarray:
        """The loudest (most speech-like) non-overlapping windows, joined, for quick model scoring."""
        sec = frame_db(x, SR)  # 1 s frames
        w = int(length)
        energy = np.convolve(10 ** (sec / 10), np.ones(w), mode="valid")
        picked: list[int] = []
        for i in np.argsort(-energy):
            if all(abs(i - j) >= w for j in picked):
                picked.append(int(i))
            if len(picked) == windows:
                break
        return np.concatenate([x[:, i * SR:(i + w) * SR] for i in sorted(picked)], axis=-1)

    def _store(self, key: tuple, model: str, enh: np.ndarray) -> dict:
        db = frame_db(enh)
        p95 = float(np.percentile(db, 95))
        speech = db > max(p95 - 30, -60)
        st = {
            "model": model, "enh": enh,
            "speech_ratio": float(speech.mean()),
            "speech_db": float(np.percentile(db[speech], 90)) if speech.any() else p95,
            "little_speech": bool(speech.mean() < 0.05 or p95 < -55),
        }
        self.stages[key] = st
        limit = len(MODELS) if self.duration <= AUTO_EXCERPT_LIMIT else 1
        while len(self.stages) > limit:
            self.stages.popitem(last=False)
        return st

    def choose_model(self, s: dict, progress=None) -> dict:
        """Auto mode: run every model, score each with DNSMOS, keep the best. Cached per pre-filter setting."""
        pkey, pre = self.prefiltered(s)
        if pkey in self.auto:
            return self.auto[pkey]
        short = self.duration <= AUTO_EXCERPT_LIMIT
        x = pre if short else self.excerpt(pre)
        scores, errors = {"original": dnsmos(x)}, {}
        names = list(MODELS)
        for i, m in enumerate(names):
            sub = (lambda v, i=i: progress((i + v) / len(names))) if progress else None
            try:
                y = run_model(m, x, self.noise_floor_db, sub)
            except Exception as e:  # noqa: BLE001  (one failing model must not stop the others)
                errors[m] = str(e)
                continue
            scores[m] = dnsmos(y)
            if short:
                self._store((m,) + pkey, m, y)
        candidates = {m: v for m, v in scores.items() if m != "original"}
        if not candidates:
            raise EngineError("No cleaning model could run: " + "; ".join(errors.values()))
        result = {"model": pick_best(candidates), "scores": scores, "errors": errors,
                  "scored_on": "whole clip" if short else "45 s speech excerpt"}
        self.auto[pkey] = result
        return result

    def stage(self, s: dict, progress=None) -> dict:
        pkey, pre = self.prefiltered(s)
        model = s["model"]
        if model == "auto":
            first = progress
            if progress and pkey not in self.auto and self.duration > AUTO_EXCERPT_LIMIT:
                first = lambda v: progress(0.5 * v)  # noqa: E731
                orig, progress = progress, (lambda v: orig(0.5 + 0.5 * v))
            model = self.choose_model(s, first)["model"]
        key = (model,) + pkey
        if key in self.stages:
            self.stages.move_to_end(key)
            return self.stages[key]
        return self._store(key, model, run_model(model, pre, self.noise_floor_db, progress))

    def analysis(self) -> dict:
        return {
            "key": self.key, "path": self.path, "duration": round(self.duration, 3),
            "channels": self.channels, "has_video": self.has_video, "linked_channels": self.linked,
            "hum_base": self.hum["base"], "hum_harmonics": self.hum["harmonics"],
            "noise_floor_db": round(self.noise_floor_db, 1), "voice_db": round(self.voice_db, 1),
            "peak_db": round(self.peak_db, 1), "lufs": round(self.lufs, 1),
        }


class ClipCache:
    def __init__(self, max_bytes: int = 1_500_000_000, max_clips: int = 4):
        self.clips: OrderedDict[str, Clip] = OrderedDict()
        self.max_bytes, self.max_clips = max_bytes, max_clips

    def get(self, path: str) -> Clip:
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            raise EngineError("File not found")
        clip = self.clips.get(path)
        st = os.stat(path)
        if clip is not None:
            key = hashlib.sha1(f"{path}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()[:16]
            if key == clip.key:
                self.clips.move_to_end(path)
                return clip
        clip = Clip(path)
        self.clips[path] = clip
        self.trim()
        return clip

    def trim(self):
        while len(self.clips) > 1 and (len(self.clips) > self.max_clips or sum(c.nbytes() for c in self.clips.values()) > self.max_bytes):
            self.clips.popitem(last=False)


# ---------------------------------------------------------------- render

def render(clip: Clip, settings: dict, progress=None) -> tuple[np.ndarray, dict]:
    s = normalise_settings(settings)
    st = clip.stage(s, progress)
    pre, enh = clip._pre, st["enh"]
    lim = 0.0 if s["full"] else 10 ** (-s["noise_reduction"] / 20)
    y = np.subtract(pre, enh)  # in place below: y = enh + lim * (pre - enh), no extra full-length copies
    y *= lim
    y += enh
    eq = []
    if abs(s["warmth"]) > 0.05:
        eq.append(peaking_sos(250, s["warmth"]))
    if abs(s["clarity"]) > 0.05:
        eq.append(peaking_sos(3500, s["clarity"]))
    if eq:
        y = sosfilt_chunked(np.vstack(eq), y)
    y = compress(y, s["evenness"], st["speech_db"])
    if clip.linked and clip.channels > 1:
        y = np.repeat(y, clip.channels, axis=0)
        ref = np.repeat(enh, clip.channels, axis=0)
    else:
        ref = enh
    warnings = []
    if st["little_speech"]:
        warnings.append("Little or no speech found: level left unchanged")
    elif s["loudness"] is not None or s["evenness"] > 0:
        target = s["loudness"] if s["loudness"] is not None else integrated_lufs(ref)
        current = integrated_lufs(y)
        gain = min(30.0, target - current)
        if target - current > 30:
            warnings.append("Very quiet recording: loudness boost capped at +30 dB")
        y *= np.float32(10 ** (gain / 20))
    y = limit(y, s["true_peak"])
    if clip.peak_db > -0.3:
        warnings.append("Source audio is clipped (distorted) in places; cleaning cannot repair that")
    if not clip.linked:
        warnings.append("Channels differ (e.g. separate mics); each channel cleaned separately")
    db = frame_db(y)
    stats = {
        "lufs": round(integrated_lufs(y), 1),
        "true_peak_db": round(float(20 * math.log10(true_peak_env(y).max() + 1e-9)), 1),
        "noise_floor_db": round(max(-120.0, float(np.percentile(db, 10))), 1),
        "voice_db": round(float(np.percentile(db, 90)), 1),
        "speech_ratio": round(st["speech_ratio"], 3),
        "little_speech": st["little_speech"],
        "model": st["model"],
        "model_label": MODELS[st["model"]],
        "auto": clip.auto.get(clip._pre_key) if s["model"] == "auto" else None,
        "warnings": warnings,
    }
    return y, stats


def write_wav(path: str, y: np.ndarray, subtype: str = "PCM_24"):
    tmp = path + ".part"
    sf.write(tmp, y.T, SR, subtype=subtype, format="WAV")
    os.replace(tmp, path)


def preview(cache: ClipCache, path: str, settings: dict, progress=None, original: bool = False) -> dict:
    clip = cache.get(path)
    s = normalise_settings(settings)
    h = settings_hash(s)
    d = os.path.join(CACHE_DIR, clip.key)
    os.makedirs(d, exist_ok=True)
    wav, meta = os.path.join(d, f"preview-{h}.wav"), os.path.join(d, f"preview-{h}.json")
    if os.path.exists(wav) and os.path.exists(meta):
        with open(meta) as f:
            stats = json.load(f)
    else:
        y, stats = render(clip, s, progress)
        write_wav(wav, y)
        with open(meta, "w") as f:
            json.dump(stats, f)
        for name in os.listdir(d):  # keep only the latest preview per clip
            if name.startswith("preview-") and h not in name:
                try:
                    os.remove(os.path.join(d, name))
                except OSError:
                    pass
        cache.trim()
    result = {"wav": wav, "settings_hash": h, "stats": stats, "analysis": clip.analysis()}
    if original:  # decoded source audio, for formats the app's player cannot open itself (e.g. MXF)
        ow = os.path.join(d, "original.wav")
        if not os.path.exists(ow):
            w = np.repeat(clip.work, clip.channels, axis=0) if clip.linked and clip.channels > 1 else clip.work
            write_wav(ow, w)
        result["original_wav"] = ow
    return result


MANIFEST = ".cleanvoice-manifest.json"


class OutputFolder:
    """An export folder. Files CleanVoice wrote there before (listed in a manifest) may be replaced on re-export,
    so DaVinci never sees '-2' duplicates. Any other existing file is left alone and the new file gets a new name."""

    def __init__(self, out_dir: str):
        self.dir = os.path.abspath(out_dir)
        self.path = os.path.join(self.dir, MANIFEST)
        try:
            with open(self.path) as f:
                self.owned = set(json.load(f).get("files", []))
        except (OSError, ValueError):
            self.owned = set()

    def target(self, path: str, sources: set[str]) -> str:
        path = os.path.abspath(path)
        rel = os.path.relpath(path, self.dir)
        if path in sources:
            raise EngineError("Refusing to overwrite a source file; choose a different export folder")
        if not os.path.exists(path) or rel in self.owned:
            return path
        base, ext = os.path.splitext(path)
        n = 2
        while os.path.exists(f"{base} ({n}){ext}") and os.path.relpath(f"{base} ({n}){ext}", self.dir) not in self.owned:
            n += 1
        return f"{base} ({n}){ext}"

    def record(self, paths: list[str]):
        self.owned.update(os.path.relpath(os.path.abspath(p), self.dir) for p in paths)
        tmp = self.path + ".part"
        with open(tmp, "w") as f:
            json.dump({"written_by": "CleanVoice", "files": sorted(self.owned)}, f, indent=1)
        os.replace(tmp, self.path)


def output_paths(src: str, root: str, out_dir: str, has_video: bool, video: bool, wav: bool,
                 layout: str = "folders", same_names: bool = True) -> tuple[str | None, str | None]:
    """Video files go in <out>/Video, audio in <out>/Audio. 'folders' mirrors the source folders; 'flat' puts
    everything side by side, prefixing the source folder names to keep names unique."""
    root = os.path.abspath(root) if root else os.path.dirname(src)
    rel = os.path.relpath(os.path.dirname(src), root)
    if rel.startswith("..") or rel == ".":
        rel = ""
    stem, ext = os.path.splitext(os.path.basename(src))
    if layout == "flat" and rel:
        stem = " - ".join(rel.split(os.sep) + [stem])
        rel = ""
    name = stem if same_names else f"{stem}_clean"
    video_out = wav_out = None
    if has_video and video:
        vext = ".mp4" if ext.lower() in (".mp4", ".m4v") else ".mov"
        video_out = os.path.join(out_dir, "Video", rel, name + vext)
    if wav or not has_video:
        wav_out = os.path.join(out_dir, "Audio", rel, name + ".wav")
    return video_out, wav_out


def export(cache: ClipCache, path: str, settings: dict, out_dir: str | None = None, root: str | None = None,
           wav_stem: bool = True, bitrate: str = "320k", progress=None, video: bool = True,
           layout: str = "folders", same_names: bool = True) -> dict:
    clip = cache.get(path)
    s = normalise_settings(settings)
    src = clip.path
    root = root or os.path.dirname(src)
    out_dir = os.path.abspath(out_dir or os.path.join(root, OUTPUT_DIR_NAME))
    if not (video and clip.has_video) and not wav_stem and clip.has_video:
        raise EngineError("Nothing to export: choose video files, audio files, or both")
    y, stats = render(clip, s, (lambda v: progress(0.8 * v)) if progress else None)
    folder = OutputFolder(out_dir)
    video_out, wav_out = output_paths(src, root, out_dir, clip.has_video, video, wav_stem, layout, same_names)
    sources = {src}
    video_out = folder.target(video_out, sources) if video_out else None
    wav_out = folder.target(wav_out, sources) if wav_out else None
    outputs = []
    if video_out:
        os.makedirs(os.path.dirname(video_out), exist_ok=True)
        tmp_wav = video_out + ".audio.wav"
        tmp_vid = video_out + ".part" + os.path.splitext(video_out)[1]
        # MOV gets uncompressed 24-bit audio (best for DaVinci); MP4 cannot carry PCM, so it gets AAC 320k.
        acodec = ["-c:a", "pcm_s24le"] if video_out.lower().endswith(".mov") else ["-c:a", "aac", "-b:a", bitrate]
        try:
            write_wav(tmp_wav, y, "FLOAT")
            cmd = [ffmpeg(), "-v", "error", "-nostdin", "-y", "-i", src, "-i", tmp_wav,
                   "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", *acodec,
                   "-ar", str(SR), "-map_metadata", "0", "-movflags", "+faststart", tmp_vid]
            r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
            if r.returncode != 0:
                raise EngineError("Video export failed: " + r.stderr.strip()[-400:])
            os.replace(tmp_vid, video_out)
            outputs.append(video_out)
        finally:
            for t in (tmp_wav, tmp_vid):
                if os.path.exists(t):
                    os.remove(t)
    if wav_out:
        os.makedirs(os.path.dirname(wav_out), exist_ok=True)
        write_wav(wav_out, y)
        outputs.append(wav_out)
    folder.record(outputs)
    if progress:
        progress(1.0)
    write_report_row(out_dir, src, outputs, clip, s, stats)
    return {"outputs": outputs, "stats": stats, "analysis": clip.analysis(), "out_dir": out_dir}


REPORT_FIELDS = ["time", "source", "outputs", "model", "hum", "noise_before_db", "noise_after_db", "lufs", "true_peak_db",
                 "noise_reduction", "loudness_target", "warnings"]


def write_report_row(out_dir: str, src: str, outputs: list[str], clip: Clip, s: dict, stats: dict):
    path = os.path.join(out_dir, "report.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=REPORT_FIELDS)
        if new:
            w.writeheader()
        w.writerow({
            "time": time.strftime("%Y-%m-%d %H:%M:%S"), "source": src, "outputs": " | ".join(outputs),
            "model": stats["model"] + (" (auto)" if s["model"] == "auto" else ""),
            "hum": f"{clip.hum['base']} Hz ({', '.join(map(str, clip.hum['harmonics']))})" if clip.hum["base"] else "none",
            "noise_before_db": round(clip.noise_floor_db, 1), "noise_after_db": stats["noise_floor_db"],
            "lufs": stats["lufs"], "true_peak_db": stats["true_peak_db"],
            "noise_reduction": "full" if s["full"] else s["noise_reduction"],
            "loudness_target": "off" if s["loudness"] is None else s["loudness"],
            "warnings": "; ".join(stats["warnings"]),
        })


# ---------------------------------------------------------------- worker mode

def serve():
    proto = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)  # stray prints from libraries go to stderr, never into the protocol
    sys.stdout = sys.stderr
    cache = ClipCache()

    def send(msg):
        proto.write(json.dumps(msg) + "\n")
        proto.flush()

    send({"event": "ready", "version": VERSION, "defaults": DEFAULTS})
    try:
        load_df("deepfilternet3")
        send({"event": "model_loaded"})
    except Exception as e:  # noqa: BLE001
        send({"event": "error", "error": f"Speech model failed to load: {e}"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            cmd = req.get("cmd")

            def progress(v, rid=rid):
                send({"id": rid, "event": "progress", "value": round(float(v), 3)})

            if cmd == "ping":
                result = {"pong": True}
            elif cmd == "models":
                result = {"models": MODELS, "defaults": DEFAULTS, "ranges": RANGES}
            elif cmd == "analyse":
                result = cache.get(req["path"]).analysis()
            elif cmd == "preview":
                result = preview(cache, req["path"], req.get("settings"), progress, bool(req.get("original")))
            elif cmd == "export":
                result = export(cache, req["path"], req.get("settings"), req.get("out_dir"), req.get("root"),
                                bool(req.get("wav_stem", True)), str(req.get("bitrate", "320k")), progress,
                                bool(req.get("video", True)), str(req.get("layout", "folders")),
                                bool(req.get("same_names", True)))
            elif cmd == "shutdown":
                send({"id": rid, "ok": True, "result": {}})
                break
            else:
                raise EngineError(f"Unknown command: {cmd}")
            send({"id": rid, "ok": True, "result": result})
        except EngineError as e:
            send({"id": rid, "ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            send({"id": rid, "ok": False, "error": f"{type(e).__name__}: {e}"})


# ---------------------------------------------------------------- CLI mode

def scan(paths: list[str]) -> list[tuple[str, str]]:
    """Return (file, root) pairs for supported media, skipping hidden files and our own output folders."""
    found = []
    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if os.path.isfile(p):
            found.append((p, os.path.dirname(p)))
        elif os.path.isdir(p):
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in (OUTPUT_DIR_NAME, "cleaned")
                                     and not os.path.exists(os.path.join(dirpath, d, MANIFEST)))
                for name in sorted(filenames):
                    if name.startswith(".") or "_clean" in name:
                        continue
                    if os.path.splitext(name)[1].lower() in VIDEO_EXT | AUDIO_EXT:
                        found.append((os.path.join(dirpath, name), p))
    return found


def cli(argv: list[str]):
    ap = argparse.ArgumentParser(prog="cleanvoice", description="Clean dialogue in video/audio clips. Use on source clips, not finished mixes: music and sound effects are removed too.")
    ap.add_argument("paths", nargs="+", help="files or folders")
    ap.add_argument("--out", help="output folder (default: 'cleaned' next to the input)")
    ap.add_argument("--model", default="auto", choices=["auto", *MODELS], help="cleaning model (default auto: tries each, keeps the best-scoring)")
    ap.add_argument("--noise-reduction", type=float, default=DEFAULTS["noise_reduction"], help="dB of background reduction (default 28)")
    ap.add_argument("--full", action="store_true", help="remove all background (silent gaps)")
    ap.add_argument("--hum", default="auto", choices=["auto", "50", "60", "off"])
    ap.add_argument("--low-cut", type=float, default=DEFAULTS["low_cut"])
    ap.add_argument("--warmth", type=float, default=DEFAULTS["warmth"])
    ap.add_argument("--clarity", type=float, default=DEFAULTS["clarity"])
    ap.add_argument("--evenness", type=float, default=DEFAULTS["evenness"])
    ap.add_argument("--loudness", default=str(DEFAULTS["loudness"]), help="LUFS target, or 'off'")
    ap.add_argument("--true-peak", type=float, default=DEFAULTS["true_peak"])
    ap.add_argument("--no-wav-stem", action="store_true", help="for videos, skip the separate WAV")
    ap.add_argument("--flat", action="store_true", help="put all exports side by side instead of mirroring source folders")
    ap.add_argument("--suffix", action="store_true", help="add _clean to file names (default keeps original names for DaVinci relinking)")
    ap.add_argument("--bitrate", default="320k")
    ap.add_argument("--json", action="store_true", help="print a JSON summary")
    a = ap.parse_args(argv)
    settings = normalise_settings({
        "model": a.model, "noise_reduction": a.noise_reduction, "full": a.full, "hum": a.hum, "low_cut": a.low_cut,
        "warmth": a.warmth, "clarity": a.clarity, "evenness": a.evenness, "true_peak": a.true_peak,
        "loudness": None if a.loudness.lower() == "off" else float(a.loudness),
    })
    files = scan(a.paths)
    if not files:
        print("No supported files found.", file=sys.stderr)
        return 1
    cache = ClipCache(max_clips=1)
    rows, failed = [], 0
    for i, (f, root) in enumerate(files, 1):
        t0 = time.time()
        if not a.json:
            print(f"[{i}/{len(files)}] {os.path.relpath(f, root)} ...", end="", flush=True, file=sys.stderr)
        try:
            r = export(cache, f, settings, a.out, root, not a.no_wav_stem, a.bitrate,
                       layout="flat" if a.flat else "folders", same_names=not a.suffix)
            an, st = r["analysis"], r["stats"]
            rows.append({"file": f, "ok": True, "outputs": r["outputs"], "model": st["model"], "hum": an["hum_base"],
                         "noise_before_db": an["noise_floor_db"], "noise_after_db": st["noise_floor_db"],
                         "lufs": st["lufs"], "true_peak_db": st["true_peak_db"], "warnings": st["warnings"]})
            if not a.json:
                print(f" done in {time.time() - t0:.1f}s  {st['model']}, background {an['noise_floor_db']} -> {st['noise_floor_db']} dB, "
                      f"{st['lufs']} LUFS" + ("".join(f"\n    ! {w}" for w in st["warnings"])), file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            failed += 1
            rows.append({"file": f, "ok": False, "error": str(e)})
            if not a.json:
                print(f" FAILED: {e}", file=sys.stderr)
    if a.json:
        print(json.dumps({"processed": len(rows) - failed, "failed": failed, "clips": rows}, indent=1))
    else:
        print(f"\n{len(rows) - failed} cleaned, {failed} failed.", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve()
    elif len(sys.argv) > 1 and sys.argv[1] == "process":
        sys.exit(cli(sys.argv[2:]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
