#!/usr/bin/env python3
"""Interactive device setup — add phones one at a time, assign audio/video role.

Detects the currently connected ADB device (USB or wireless), asks whether
it's for audio or video, then saves it into devices.yaml.

Audio pull path:  app recording dir (e.g. voice recorder app)
Video pull path:  MotionCam folder (/sdcard/DCIM/MotionCam)

Usage:
    python setup_devices.py              # add a device interactively
    python setup_devices.py --list       # show current config
    python setup_devices.py --clear      # wipe config and start fresh
"""
import os
import sys
import re
import subprocess

try:
    import yaml
except ImportError:
    print("Error: PyYAML required.  Activate the venv or: pip install pyyaml",
          file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "devices.yaml")

# Defaults
DEFAULT_AUDIO_DIR = "/sdcard/Android/data/com.first75.voicerecorder2/files/Recordings"
DEFAULT_VIDEO_DIR = "/sdcard/DCIM/MotionCam"


# ── helpers ──────────────────────────────────────────────────────────

def run_adb(*args, timeout=10):
    try:
        r = subprocess.run(["adb", *args],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.returncode
    except FileNotFoundError:
        print("Error: 'adb' not found.", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        return "", 1


def get_connected_devices():
    """Return list of dicts for every device reported by `adb devices -l`."""
    out, _ = run_adb("devices", "-l")
    devices = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("*"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        serial = parts[0]
        state = parts[1]
        is_wireless = bool(re.match(r"\d+\.\d+\.\d+\.\d+:\d+", serial))

        model_m = re.search(r"model:(\S+)", line)
        model = model_m.group(1).replace("_", " ") if model_m else "unknown"

        d = {
            "serial": serial,
            "state": state,
            "connection": "wireless" if is_wireless else "usb",
            "model": model,
        }
        if is_wireless:
            ip, port = serial.rsplit(":", 1)
            d["ip"] = ip
            d["port"] = int(port)
        devices.append(d)
    return devices


def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            cfg = yaml.safe_load(f) or {}
    else:
        cfg = {}
    cfg.setdefault("devices", [])
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)


def show_config(cfg):
    devs = cfg.get("devices", [])
    if not devs:
        print("No devices configured yet.  Run: python setup_devices.py")
        return
    print(f"\n── Configured devices ({len(devs)}) ──")
    for i, d in enumerate(devs, 1):
        role = d.get("role", "?")
        icon = "🎬" if role == "video" else "🎙"
        conn = d.get("connection", "?")
        print(f"  {i}) {icon}  {d.get('name', '?')}  ({role})  [{conn}]  serial={d['serial']}")
        print(f"       pull dir: {d.get('pull_dir', '—')}")
    print()


# ── interactive flow ─────────────────────────────────────────────────

def pick_device(connected, already_configured):
    """Let user pick one of the currently connected devices."""
    configured_serials = {d["serial"] for d in already_configured}
    available = [d for d in connected if d["state"] == "device"]

    if not available:
        print("No authorised ADB devices detected. Plug in or wirelessly connect a phone first.")
        sys.exit(1)

    # Mark already-configured ones
    print("\n── Connected ADB devices ──")
    for i, d in enumerate(available, 1):
        tag = " (already configured)" if d["serial"] in configured_serials else ""
        print(f"  {i}) {d['model']}  ({d['connection']})  serial={d['serial']}{tag}")

    if len(available) == 1:
        print(f"\nAuto-selected: {available[0]['model']}")
        return available[0]

    while True:
        try:
            choice = input(f"\nSelect device [1-{len(available)}]: ").strip()
            idx = int(choice) - 1
            if 0 <= idx < len(available):
                return available[idx]
        except (ValueError, EOFError):
            pass
        print("Invalid choice.")


def pick_role():
    print("\nWhat role does this phone have?")
    print("  1) 🎙  Audio  — pull audio recordings (voice recorder app)")
    print("  2) 🎬  Video  — pull video from MotionCam folder")
    while True:
        try:
            c = input("Choice [1/2]: ").strip()
            if c == "1":
                return "audio"
            if c == "2":
                return "video"
        except EOFError:
            sys.exit(0)
        print("Pick 1 or 2.")


def pick_pull_dir(role):
    default = DEFAULT_AUDIO_DIR if role == "audio" else DEFAULT_VIDEO_DIR
    d = input(f"Pull directory on phone [{default}]: ").strip()
    return d if d else default


def pick_wifi(device):
    """If the device is USB, optionally store WiFi info for future wireless connect."""
    if device["connection"] == "wireless":
        # already wireless — ip/port already known
        return device.get("ip"), device.get("port")

    ans = input("Store WiFi IP for wireless reconnect later? [y/N]: ").strip().lower()
    if ans != "y":
        return None, None
    ip = input("  WiFi IP: ").strip()
    port = input("  WiFi port [5555]: ").strip() or "5555"
    return ip, int(port)


def add_device():
    cfg = load_config()
    connected = get_connected_devices()
    device = pick_device(connected, cfg["devices"])

    role = pick_role()
    pull_dir = pick_pull_dir(role)
    wifi_ip, wifi_port = pick_wifi(device)

    name = input(f"Friendly name [{device['model']}]: ").strip() or device["model"]

    entry = {
        "name": name,
        "serial": device["serial"],
        "role": role,
        "connection": device["connection"],
        "pull_dir": pull_dir,
    }
    if wifi_ip:
        entry["ip"] = wifi_ip
        entry["port"] = wifi_port
    elif device["connection"] == "wireless":
        entry["ip"] = device["ip"]
        entry["port"] = device["port"]

    # Replace if same serial already exists
    cfg["devices"] = [d for d in cfg["devices"] if d["serial"] != device["serial"]]
    cfg["devices"].append(entry)

    save_config(cfg)
    print(f"\n✓ Saved {name} as {role} device.")
    show_config(cfg)


# ── CLI ──────────────────────────────────────────────────────────────

def main():
    if "--list" in sys.argv:
        show_config(load_config())
        return

    if "--clear" in sys.argv:
        save_config({"devices": []})
        print("Config cleared.")
        return

    add_device()


if __name__ == "__main__":
    main()
