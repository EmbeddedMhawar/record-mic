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
import time

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


def _wait_for_device(serial, timeout=30):
    """Poll `adb devices` until *serial* shows state 'device'. Returns True on success."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for d in get_connected_devices():
            if d["serial"] == serial and d["state"] == "device":
                return True
        time.sleep(2)
    return False


def _get_model(serial):
    """Query the model name for an already-authorised device."""
    out, rc = run_adb("-s", serial, "shell", "getprop", "ro.product.model")
    return out.strip() if rc == 0 and out.strip() else "unknown"


def connect_by_ip():
    """Connect to a device over WiFi by IP address.

    Three-stage strategy:
      1. Try  adb connect <ip>:5555  (works if device already in TCP/IP mode)
      2. If that fails, ask for the pairing code + port and pair first
      3. After pairing, switch the device to port 5555 for a stable connection

    Returns a device dict (serial, connection, ip, port, model).
    """
    ip = input("\nDevice WiFi IP address: ").strip()
    if not re.match(r"\d+\.\d+\.\d+\.\d+$", ip):
        print("Invalid IP address.")
        sys.exit(1)

    std_serial = f"{ip}:5555"

    # ── Stage 1: try direct connect on port 5555 ────────────────────
    print(f"\nTrying adb connect {std_serial} ...")
    out, rc = run_adb("connect", std_serial, timeout=15)
    if rc == 0 and "connected" in out.lower():
        print(f"  Connected: {out}")
        print("Waiting for device authorisation (tap Allow if prompted) ...")
        if _wait_for_device(std_serial):
            model = _get_model(std_serial)
            print(f"  Device ready: {model}")
            return {"serial": std_serial, "connection": "wireless",
                    "ip": ip, "port": 5555, "model": model}
        print("  Timed out waiting for authorisation.")

    # ── Stage 2: pair with device first ─────────────────────────────
    print("\nDirect connect failed — the device may need pairing first.")
    print("On your phone: Settings > Developer options > Wireless debugging")
    print("  Tap 'Pair device with pairing code' and enter the info below.\n")

    pair_port = input("  Pairing port (shown on phone): ").strip()
    pair_code = input("  Pairing code (shown on phone): ").strip()
    if not pair_port or not pair_code:
        print("Pairing port and code are required.")
        sys.exit(1)

    pair_target = f"{ip}:{pair_port}"
    print(f"\nPairing with {pair_target} ...")
    out, rc = run_adb("pair", pair_target, pair_code, timeout=30)
    if rc != 0 or "failed" in out.lower():
        print(f"  Pairing failed: {out}")
        sys.exit(1)
    print(f"  Paired: {out}")

    # After pairing, connect to the wireless debugging port to get a session
    # The phone's wireless debugging has a *connect* port (different from pair port).
    print("\nOn your phone, note the IP & Port shown under 'Wireless debugging'")
    print("  (this is the *connect* port, NOT the pairing port).\n")
    connect_port = input("  Connect port: ").strip()
    if not connect_port:
        print("Connect port is required.")
        sys.exit(1)

    connect_serial = f"{ip}:{connect_port}"
    print(f"\nConnecting to {connect_serial} ...")
    out, rc = run_adb("connect", connect_serial, timeout=15)
    if rc != 0 or "cannot" in out.lower():
        print(f"  Connect failed: {out}")
        sys.exit(1)
    print(f"  Connected: {out}")

    # ── Stage 3: switch to standard port 5555 ───────────────────────
    print("Switching to standard port 5555 ...")
    run_adb("-s", connect_serial, "tcpip", "5555", timeout=15)
    time.sleep(2)

    out, rc = run_adb("connect", std_serial, timeout=15)
    if rc != 0 or "cannot" in out.lower():
        print(f"  Failed to reconnect on port 5555: {out}")
        sys.exit(1)
    print(f"  Reconnected: {out}")

    print("Waiting for device authorisation ...")
    if not _wait_for_device(std_serial):
        print("  Timed out waiting for authorisation.")
        sys.exit(1)

    model = _get_model(std_serial)
    print(f"  Device ready: {model}")
    return {"serial": std_serial, "connection": "wireless",
            "ip": ip, "port": 5555, "model": model}


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

    print("\nHow would you like to add a device?")
    print("  1) Select from already-connected ADB devices")
    print("  2) Connect a new device by IP address")
    while True:
        try:
            method = input("Choice [1/2]: ").strip()
            if method in ("1", "2"):
                break
        except EOFError:
            sys.exit(0)
        print("Pick 1 or 2.")

    if method == "2":
        device = connect_by_ip()
        wifi_ip, wifi_port = device["ip"], device["port"]
    else:
        connected = get_connected_devices()
        device = pick_device(connected, cfg["devices"])
        wifi_ip, wifi_port = pick_wifi(device)

    role = pick_role()
    pull_dir = pick_pull_dir(role)

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
