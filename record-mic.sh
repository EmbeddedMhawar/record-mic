#!/usr/bin/env bash
set -euo pipefail

# All-in-one: record PC mic, pull latest video from phone, auto-sync & merge.
#
# Usage:
#   ./record-mic.sh [output.mp4]
#
# 1. Connects to phone (USB or wireless automatically)
# 2. Starts recording PC mic
# 3. You record on MotionCam Pro
# 4. Press Ctrl+C to stop
# 5. Automatically: pulls latest video from phone, syncs audio, merges

MCAM_DIR="/sdcard/DCIM/MotionCam"
PIXEL_WIFI_IP="10.114.222.226"
PIXEL_WIFI_PORT="5555"
PIXEL_HOTSPOT_SSID="Pixel"
PIXEL_HOTSPOT_PASS="adminadmin"
OUTPUT="${1:-recording_$(date +%Y%m%d_%H%M%S).mp4}"
TMPDIR_SYNC=$(mktemp -d /tmp/autosync.XXXXXX)
MIC_WAV="$TMPDIR_SYNC/mic.wav"

cleanup_tmp() {
    rm -rf "$TMPDIR_SYNC"
}

ensure_adb() {
    # Check if any ADB device is already connected
    if adb devices 2>/dev/null | grep -q "device$"; then
        echo "ADB: device connected."
        return 0
    fi

    echo "No ADB device found. Trying to connect..."

    # Try 1: USB — just check again after a moment
    if adb devices 2>/dev/null | grep -qE "usb|device$"; then
        echo "ADB: connected via USB."
        return 0
    fi

    # Try 2: WiFi — check if we're on the Pixel hotspot
    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
    if [[ "$CURRENT_SSID" != "$PIXEL_HOTSPOT_SSID" ]]; then
        echo "Not on Pixel hotspot (current: $CURRENT_SSID). Connecting..."
        nmcli connection delete "$PIXEL_HOTSPOT_SSID" 2>/dev/null || true
        if ! nmcli device wifi connect "$PIXEL_HOTSPOT_SSID" password "$PIXEL_HOTSPOT_PASS" ifname wlan0 2>&1; then
            echo "Error: Could not connect to Pixel hotspot."
            echo "Please connect USB or enable the hotspot."
            exit 1
        fi
        echo "Connected to Pixel hotspot."
    fi

    # Connect ADB over WiFi
    echo "Connecting ADB wirelessly to $PIXEL_WIFI_IP:$PIXEL_WIFI_PORT..."
    if timeout 5 adb connect "$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT" 2>&1 | grep -q "connected"; then
        echo "ADB: connected wirelessly."
        return 0
    fi

    # WiFi ADB failed — might need USB first to enable tcpip mode
    echo "Wireless ADB failed. Plug in USB briefly to enable it."
    echo "Waiting for USB device..."
    if ! adb wait-for-usb-device 2>/dev/null; then
        echo "Error: No device found. Connect phone via USB."
        exit 1
    fi
    adb tcpip "$PIXEL_WIFI_PORT" 2>/dev/null
    sleep 2
    adb connect "$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT" 2>/dev/null
    echo "ADB: enabled wireless mode. You can unplug USB now."
}

# === Step 1: Ensure ADB connection ===
ensure_adb

# Snapshot existing files on phone before recording
echo ""
echo "Scanning phone for existing videos..."
BEFORE=$(adb shell "ls -1 '$MCAM_DIR'/*.mp4 2>/dev/null" | tr -d '\r' | sort)

echo ""
echo "=== Recording PC mic ==="
echo "Start recording on MotionCam Pro, then press ENTER when done."
echo ""

pw-record "$MIC_WAV" &
PWREC_PID=$!

read -r
kill "$PWREC_PID" 2>/dev/null
wait "$PWREC_PID" 2>/dev/null || true

echo ""
echo "=== Processing ==="

# Find new video(s) on phone
echo "Looking for new video on phone..."
AFTER=$(adb shell "ls -1 '$MCAM_DIR'/*.mp4 2>/dev/null" | tr -d '\r' | sort)
NEW_FILES=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))

if [[ -z "$NEW_FILES" ]]; then
    echo "No new video found on phone."
    echo "Saving raw mic audio: ${OUTPUT%.*}_mic.wav"
    cp "$MIC_WAV" "${OUTPUT%.*}_mic.wav"
    cleanup_tmp
    exit 1
fi

# Take the latest new file
VIDEO_REMOTE=$(echo "$NEW_FILES" | tail -1)
echo "Found: $(basename "$VIDEO_REMOTE")"

# Pull from phone
VIDEO_LOCAL="$TMPDIR_SYNC/video.mp4"
echo "Pulling video from phone..."
adb pull "$VIDEO_REMOTE" "$VIDEO_LOCAL" 2>&1

# Check video has audio for sync reference
HAS_AUDIO=$(ffprobe -v quiet -show_streams -select_streams a "$VIDEO_LOCAL" | head -1)
if [[ -z "$HAS_AUDIO" ]]; then
    echo "Warning: Video has no audio track — skipping auto-sync, trimming to video duration."
    VDUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$VIDEO_LOCAL")
    ffmpeg -y -i "$VIDEO_LOCAL" -i "$MIC_WAV" \
        -c:v copy -c:a aac -b:a 320k \
        -map 0:v -map 1:a \
        -t "$VDUR" \
        "$OUTPUT" 2>/dev/null
    echo "Saved: $OUTPUT (no sync — trimmed only)"
    cleanup_tmp
    exit 0
fi

# === Auto-sync via FFT cross-correlation (Kdenlive/PluralEyes method) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Extracting reference audio (phone mic)..."
ffmpeg -y -i "$VIDEO_LOCAL" -vn -f wav "$TMPDIR_SYNC/ref.wav" 2>/dev/null

echo "Computing cross-correlation (FFT)..."
OFFSET=$(python3 "$SCRIPT_DIR/audio_sync.py" "$TMPDIR_SYNC/ref.wav" "$MIC_WAV")
echo "Detected sync offset: ${OFFSET}s"

VDUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$VIDEO_LOCAL")
echo "Video duration: ${VDUR}s"

# If offset is positive, PC mic started before video — skip into PC audio
# If offset is negative, video started before PC mic — pad PC audio
echo "Merging synced audio onto video..."
if python3 -c "import sys; sys.exit(0 if float('$OFFSET') >= 0 else 1)"; then
    ffmpeg -y -i "$VIDEO_LOCAL" -ss "$OFFSET" -i "$MIC_WAV" \
        -c:v copy -c:a aac -b:a 320k \
        -map 0:v -map 1:a \
        -t "$VDUR" \
        "$OUTPUT" 2>/dev/null
else
    # Pad PC audio with silence at the start
    PAD=$(python3 -c "print(abs(float('$OFFSET')))")
    ffmpeg -y -i "$VIDEO_LOCAL" -i "$MIC_WAV" \
        -filter_complex "[1:a]adelay=${PAD}s|${PAD}s[delayed]" \
        -c:v copy -c:a aac -b:a 320k \
        -map 0:v -map "[delayed]" \
        -t "$VDUR" \
        "$OUTPUT" 2>/dev/null
fi

cleanup_tmp
echo ""
echo "Saved: $OUTPUT"
echo "Done."
