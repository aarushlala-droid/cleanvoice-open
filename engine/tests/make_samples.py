"""Build deliberately bad test clips from DeepFilterNet's public assets (real speech, real noise, real room IR)."""
import os, subprocess, sys
import numpy as np, soundfile as sf
from scipy import signal
import imageio_ffmpeg

SR = 48000
src, out = sys.argv[1], sys.argv[2]
FF = imageio_ffmpeg.get_ffmpeg_exe()
rng = np.random.default_rng(7)

def load(name):
    x, sr = sf.read(os.path.join(src, name), dtype="float32")
    assert sr == SR
    return x.mean(1) if x.ndim > 1 else x

def rms(x): return np.sqrt(np.mean(x ** 2))
def at_snr(sig, noise, snr):
    noise = np.resize(noise, len(sig))
    return noise * rms(sig) / (rms(noise) * 10 ** (snr / 20))
def hum(n, base, level_db, harmonics=(1, 2, 3, 4, 5, 7, 9)):
    t = np.arange(n) / SR
    h = sum(np.sin(2 * np.pi * base * k * t + k) / k for k in harmonics)
    return (h / np.abs(h).max() * 10 ** (level_db / 20)).astype(np.float32)
def rumble(n, level_db):
    r = signal.sosfilt(signal.butter(4, 60, "lowpass", fs=SR, output="sos"), rng.standard_normal(n))
    return (r / rms(r) * 10 ** (level_db / 20)).astype(np.float32)
def norm(x, peak=-3): return (x / np.abs(x).max() * 10 ** (peak / 20)).astype(np.float32)
def video(wav, path, colour):
    subprocess.run([FF, "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c={colour}:s=1280x720:r=25",
                    "-i", wav, "-map", "0:v", "-map", "1:a", "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "256k", path], check=True)

speech = load("clean_freesound_33711.wav")
street = load("noise_freesound_2530.wav")
other = load("noise_freesound_573577.wav")
rir = load("rir_sim_1001_w11.7_l2.6_h2.5_rt60_0.7919.wav")
echo = signal.fftconvolve(speech, rir)[: len(speech)]
echo = 0.6 * speech / rms(speech) + 0.8 * echo / rms(echo)
n = len(speech)
s1, s2 = os.path.join(out, "Scene 1"), os.path.join(out, "Scene 2")
os.makedirs(s1, exist_ok=True); os.makedirs(s2, exist_ok=True)

# 1. Terrible location: echoey room, street noise at 0 dB SNR, 50 Hz mains hum, rumble -> MP4
bad = echo + at_snr(echo, street, 0) + hum(n, 50, -28) + rumble(n, -30)
tmp = os.path.join(out, "tmp.wav"); sf.write(tmp, np.stack([norm(bad)] * 2, 1), SR)
video(tmp, os.path.join(s1, "terrible_location.mp4"), "0x334455")
# 2. DeepFilterNet's own 0 dB SNR sample, as a WAV
sf.write(os.path.join(s1, "noisy_snr0.wav"), load("noisy_snr0.wav"), SR, subtype="PCM_24")
# 3. 60 Hz (US mains) hum + light hiss -> MOV
h60 = speech + hum(n, 60, -22) + 0.003 * rng.standard_normal(n).astype(np.float32)
sf.write(tmp, np.stack([norm(h60)] * 2, 1), SR)
video(tmp, os.path.join(s2, "hum_60hz.mov"), "0x553322")
# 4. Room tone only, no speech
sf.write(os.path.join(s2, "room_tone_only.wav"), norm(np.resize(other, 6 * SR), -30), SR, subtype="PCM_24")
# 5. Two different mics: L = boom in the street, R = lav (closer, quieter noise)
lav = speech + at_snr(speech, np.roll(street, 50000), 15)
sf.write(os.path.join(s2, "two_mics.wav"), np.stack([norm(bad), norm(lav)], 1), SR, subtype="PCM_24")
os.remove(tmp)
print("built in", out)
