#!/usr/bin/env python3
"""Audio sync tool — reads devices.yaml, auto-connects, computes offset.

Usage:
    python setup_devices.py              # add devices (run per phone)
    python audio_sync.py <ref> <tgt>     # sync two audio files
    python audio_sync.py --devices       # connect & show configured devices
"""
import os
import sys
import subprocess
import numpy as np
from scipy.signal import fftconvolve

try:
    import yaml
except ImportError:
    print("Error: PyYAML required. Activate the venv or: pip install pyyaml",
          file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "devices.yaml")


# ── ADB config & connection ─────────────────────────────────────────

def load_config():
    if not os.path.exists(CONFIG_PATH):
        print(f"Config not found: {CONFIG_PATH}", file=sys.stderr)
        print("Run setup_devices.py first.", file=sys.stderr)
        return []
    with open(CONFIG_PATH) as f:
        cfg = yaml.safe_load(f) or {}
    return cfg.get("devices", [])


def adb_connect(device):
    """Connect to a wireless device. No-op for USB."""
    if device.get("connection") != "wireless":
        return True
    ip = device.get("ip")
    port = device.get("port", 5555)
    if not ip:
        return False
    addr = f"{ip}:{port}"
    print(f"  Connecting to {device.get('name', '?')} at {addr} …", end=" ")
    try:
        r = subprocess.run(["adb", "connect", addr],
                           capture_output=True, text=True, timeout=10)
        if "connected" in r.stdout.lower():
            print("OK")
            return True
        print(f"FAILED ({r.stdout.strip()})")
        return False
    except Exception as e:
        print(f"FAILED ({e})")
        return False


def connect_all(devices):
    if not devices:
        return []
    print("── Connecting to configured devices ──")
    live = []
    for d in devices:
        role = d.get("role", "?")
        icon = "🎙" if role == "audio" else "🎬"
        if d.get("connection") == "usb":
            print(f"  {icon} {d['name']} ({d['serial']}) — USB")
            live.append(d)
        else:
            if adb_connect(d):
                live.append(d)
    print()
    return live


def select_device(devices, role=None):
    """Pick a device, optionally filtered by role (audio/video)."""
    filtered = [d for d in devices if role is None or d.get("role") == role]
    if not filtered:
        print(f"No {'reachable' if role is None else role} devices.")
        return None
    if len(filtered) == 1:
        d = filtered[0]
        print(f"Auto-selected: {d['name']} ({d.get('role','?')}) [{d['serial']}]")
        return d

    print(f"Available {role or ''} devices:".strip() + ":")
    for i, d in enumerate(filtered, 1):
        r = d.get("role", "?")
        print(f"  {i}) {d['name']}  ({r})  serial={d['serial']}")
    while True:
        try:
            choice = input(f"Select device [1-{len(filtered)}]: ").strip()
            idx = int(choice) - 1
            if 0 <= idx < len(filtered):
                return filtered[idx]
        except (ValueError, EOFError):
            pass
        print("Invalid choice.")


# ── Audio helpers ────────────────────────────────────────────────────

def load_mono_16k(path):
    cmd = ["ffmpeg", "-v", "quiet", "-i", path,
           "-ac", "1", "-ar", "16000", "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32)


def find_offset(ref_path, target_path):
    ref = load_mono_16k(ref_path)
    target = load_mono_16k(target_path)
    if len(ref) == 0 or len(target) == 0:
        print("Error: empty audio", file=sys.stderr)
        return 0.0
    ref = ref / (np.max(np.abs(ref)) + 1e-9)
    target = target / (np.max(np.abs(target)) + 1e-9)
    corr = fftconvolve(target, ref[::-1], mode="full")
    peak_idx = np.argmax(np.abs(corr))
    offset_samples = peak_idx - (len(ref) - 1)
    return offset_samples / 16000.0


# ── CLI ──────────────────────────────────────────────────────────────

def main():
    if "--devices" in sys.argv:
        devices = load_config()
        live = connect_all(devices)
        for role in ("audio", "video"):
            d = select_device(live, role=role)
            if d:
                print(f"  {role}: {d['name']} [{d['serial']}]  pull_dir={d.get('pull_dir','—')}\n")
        sys.exit(0)

    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <reference.wav> <target.wav>", file=sys.stderr)
        print(f"       {sys.argv[0]} --devices", file=sys.stderr)
        sys.exit(1)

    offset = find_offset(sys.argv[1], sys.argv[2])
    print(f"{offset:.4f}")


if __name__ == "__main__":
    main()
