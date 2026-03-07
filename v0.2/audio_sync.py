#!/usr/bin/env python3
"""Find the offset between two audio files using FFT cross-correlation.
Same method as Kdenlive/PluralEyes.

Usage: audio_sync.py <reference.wav> <target.wav>
Prints the offset in seconds (how far into target.wav the reference starts).
"""
import sys
import subprocess
import numpy as np
from scipy.signal import fftconvolve

def load_mono_16k(path):
    """Load audio file as mono 16kHz raw PCM via ffmpeg."""
    cmd = [
        "ffmpeg", "-v", "quiet", "-i", path,
        "-ac", "1", "-ar", "16000", "-f", "s16le", "-"
    ]
    raw = subprocess.run(cmd, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32)

def find_offset(ref_path, target_path):
    ref = load_mono_16k(ref_path)
    target = load_mono_16k(target_path)

    if len(ref) == 0 or len(target) == 0:
        print("Error: empty audio", file=sys.stderr)
        return 0.0

    # Normalize
    ref = ref / (np.max(np.abs(ref)) + 1e-9)
    target = target / (np.max(np.abs(target)) + 1e-9)

    # Cross-correlate using FFT (much faster than naive)
    corr = fftconvolve(target, ref[::-1], mode="full")

    # Peak index tells us the lag
    peak_idx = np.argmax(np.abs(corr))

    # Convert to offset in samples (relative to target)
    offset_samples = peak_idx - (len(ref) - 1)

    # Convert to seconds (16kHz sample rate)
    offset_sec = offset_samples / 16000.0

    return offset_sec

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <reference.wav> <target.wav>", file=sys.stderr)
        sys.exit(1)

    offset = find_offset(sys.argv[1], sys.argv[2])
    print(f"{offset:.4f}")
