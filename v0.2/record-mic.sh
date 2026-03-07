#!/usr/bin/env bash
set -euo pipefail

# v0.2: Multi-take PC mic recorder with FFT auto-sync for MotionCam Pro
#
# Usage:
#   ./record-mic.sh [session_name]                # record session (multi-take)
#   ./record-mic.sh resync [session]              # re-sync all takes
#   ./record-mic.sh resync [session] 2 +0.5       # resync take 2 with +0.5s adjustment
#   ./record-mic.sh manual [session] 2 12.5       # manual offset for take 2
#   ./record-mic.sh del [session]                 # delete all cache & processed files
#
# Session structure:
#   session_*/
#   ├── .audio_raw/          # raw PC mic + extracted refs + offsets
#   ├── .video_raw/          # unprocessed videos pulled from phone
#   ├── .video_processed/    # individual synced takes (xxx_final.mp4)
#   └── final.mp4            # all takes concatenated

MCAM_DIR="/sdcard/DCIM/MotionCam"
PIXEL_WIFI_IP="10.114.222.226"
PIXEL_WIFI_PORT="5555"
PIXEL_HOTSPOT_SSID="Pixel"
PIXEL_HOTSPOT_PASS="adminadmin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_SESSION_FILE="$HOME/.cache/record-mic-last-session"

ensure_adb() {
    if adb devices 2>/dev/null | grep -q "device$"; then
        echo "ADB: device connected."
        return 0
    fi

    echo "No ADB device found. Trying to connect..."

    if adb devices 2>/dev/null | grep -qE "usb|device$"; then
        echo "ADB: connected via USB."
        return 0
    fi

    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
    if [[ "$CURRENT_SSID" != "$PIXEL_HOTSPOT_SSID" ]]; then
        echo "Not on Pixel hotspot (current: $CURRENT_SSID). Connecting..."
        nmcli connection delete "$PIXEL_HOTSPOT_SSID" 2>/dev/null || true
        if ! nmcli device wifi connect "$PIXEL_HOTSPOT_SSID" password "$PIXEL_HOTSPOT_PASS" ifname wlan0 2>&1; then
            echo "Error: Could not connect to Pixel hotspot."
            exit 1
        fi
        echo "Connected to Pixel hotspot."
    fi

    echo "Connecting ADB wirelessly to $PIXEL_WIFI_IP:$PIXEL_WIFI_PORT..."
    if timeout 5 adb connect "$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT" 2>&1 | grep -q "connected"; then
        echo "ADB: connected wirelessly."
        return 0
    fi

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

# Sync and merge a single take
sync_take() {
    local SESSION="$1" TAKE_NUM="$2" ADJUST="${3:-0}"
    local PADNUM
    PADNUM=$(printf "%03d" "$TAKE_NUM")
    local VIDEO_RAW="$SESSION/.video_raw"
    local MIC="$SESSION/.audio_raw/mic.wav"
    local VIDEO
    VIDEO=$(ls "$VIDEO_RAW/${PADNUM}_"*.mp4 2>/dev/null | head -1)

    if [[ -z "$VIDEO" || ! -f "$VIDEO" ]]; then
        echo "Error: Take $TAKE_NUM not found in $VIDEO_RAW"
        return 1
    fi

    if [[ ! -f "$MIC" ]]; then
        echo "Error: Mic recording not found at $MIC"
        return 1
    fi

    mkdir -p "$SESSION/.video_processed"
    local OUTPUT="$SESSION/.video_processed/${PADNUM}_final.mp4"
    local VDUR
    VDUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$VIDEO")

    local HAS_AUDIO
    HAS_AUDIO=$(ffprobe -v quiet -show_streams -select_streams a "$VIDEO" | head -1)

    local OFFSET="0"
    if [[ -n "$HAS_AUDIO" ]]; then
        local REF_WAV="$SESSION/.audio_raw/${PADNUM}_ref.wav"
        ffmpeg -y -i "$VIDEO" -vn -f wav "$REF_WAV" 2>/dev/null
        OFFSET=$(python3 "$SCRIPT_DIR/audio_sync.py" "$REF_WAV" "$MIC")
        echo "  Take $TAKE_NUM: auto offset ${OFFSET}s"
    else
        echo "  Take $TAKE_NUM: no reference audio, using offset 0"
    fi

    local FINAL_OFFSET
    FINAL_OFFSET=$(python3 -c "print(float('$OFFSET') + float('$ADJUST'))")
    if [[ "$ADJUST" != "0" ]]; then
        echo "  Take $TAKE_NUM: adjustment ${ADJUST}s → final offset ${FINAL_OFFSET}s"
    fi

    echo "$FINAL_OFFSET" > "$SESSION/.audio_raw/${PADNUM}_offset.txt"

    if python3 -c "import sys; sys.exit(0 if float('$FINAL_OFFSET') >= 0 else 1)"; then
        ffmpeg -y -i "$VIDEO" -ss "$FINAL_OFFSET" -i "$MIC" \
            -c:v copy -c:a aac -b:a 320k \
            -map 0:v -map 1:a \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    else
        local PAD
        PAD=$(python3 -c "print(abs(float('$FINAL_OFFSET')))")
        ffmpeg -y -i "$VIDEO" -i "$MIC" \
            -filter_complex "[1:a]adelay=${PAD}s|${PAD}s[delayed]" \
            -c:v copy -c:a aac -b:a 320k \
            -map 0:v -map "[delayed]" \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    fi

    echo "  Take $TAKE_NUM: saved $OUTPUT (${VDUR}s)"
}

resolve_session() {
    local NAME="${1:-}"
    if [[ -n "$NAME" && -d "$NAME" ]]; then
        echo "$NAME"
    elif [[ -n "$NAME" && -d "session_$NAME" ]]; then
        echo "session_$NAME"
    elif [[ -z "$NAME" && -f "$LAST_SESSION_FILE" ]]; then
        cat "$LAST_SESSION_FILE"
    else
        echo ""
    fi
}

# === DEL: delete cache & processed files, keep final.mp4 ===
if [[ "${1:-}" == "del" ]]; then
    if [[ "${2:-}" == "*" ]]; then
        # Delete cache from ALL sessions
        echo "Cleaning all sessions..."
        for SESSION in session_*/; do
            [[ -d "$SESSION" ]] || continue
            echo "  $SESSION"
            rm -rf "$SESSION/.audio_raw" "$SESSION/.video_raw" "$SESSION/.video_processed"
        done
        echo "Done. All final.mp4 files kept."
        exit 0
    fi

    SESSION=$(resolve_session "${2:-}")
    if [[ -z "$SESSION" || ! -d "$SESSION" ]]; then
        echo "Error: Session not found. Usage: $0 del [session|*]"
        exit 1
    fi

    echo "Cleaning session: $SESSION"
    rm -rf "$SESSION/.audio_raw" "$SESSION/.video_raw" "$SESSION/.video_processed"
    echo "Done. Kept:"
    ls -1 "$SESSION/"*.mp4 2>/dev/null || echo "  (no finals)"
    exit 0
fi

# === RESYNC ===
if [[ "${1:-}" == "resync" ]]; then
    SESSION=$(resolve_session "${2:-}")
    if [[ -z "$SESSION" || ! -d "$SESSION" ]]; then
        echo "Error: Session not found. Usage: $0 resync [session] [take_num] [adjustment]"
        exit 1
    fi

    TAKE="${3:-}"
    ADJUST="${4:-0}"

    echo "=== Resyncing: $SESSION ==="
    if [[ -n "$TAKE" ]]; then
        sync_take "$SESSION" "$TAKE" "$ADJUST"
    else
        COUNT=$(ls "$SESSION/.video_raw/"*.mp4 2>/dev/null | wc -l)
        for i in $(seq 1 "$COUNT"); do
            sync_take "$SESSION" "$i" "$ADJUST"
        done
    fi

    # Re-concatenate
    COUNT=$(ls "$SESSION/.video_processed/"*_final.mp4 2>/dev/null | wc -l)
    if [[ "$COUNT" -gt 0 ]]; then
        CONCAT_LIST="$SESSION/.video_raw/concat.txt"
        > "$CONCAT_LIST"
        for f in "$SESSION/.video_processed/"*_final.mp4; do
            echo "file '$(realpath "$f")'" >> "$CONCAT_LIST"
        done
        echo "Concatenating..."
        ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$SESSION/final.mp4" 2>/dev/null
        echo "Combined: $SESSION/final.mp4"
    fi

    echo "Done."
    exit 0
fi

# === MANUAL ===
if [[ "${1:-}" == "manual" ]]; then
    SESSION=$(resolve_session "${2:-}")
    TAKE="${3:?Usage: $0 manual [session] <take_num> <offset>}"
    MANUAL_OFFSET="${4:?Usage: $0 manual [session] <take_num> <offset>}"

    if [[ -z "$SESSION" || ! -d "$SESSION" ]]; then
        echo "Error: Session not found."
        exit 1
    fi

    PADNUM=$(printf "%03d" "$TAKE")
    VIDEO=$(ls "$SESSION/.video_raw/${PADNUM}_"*.mp4 2>/dev/null | head -1)
    MIC="$SESSION/.audio_raw/mic.wav"
    mkdir -p "$SESSION/.video_processed"
    OUTPUT="$SESSION/.video_processed/${PADNUM}_final.mp4"
    VDUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$VIDEO")

    echo "=== Manual sync: take $TAKE, offset ${MANUAL_OFFSET}s ==="
    echo "$MANUAL_OFFSET" > "$SESSION/.audio_raw/${PADNUM}_offset.txt"

    if python3 -c "import sys; sys.exit(0 if float('$MANUAL_OFFSET') >= 0 else 1)"; then
        ffmpeg -y -i "$VIDEO" -ss "$MANUAL_OFFSET" -i "$MIC" \
            -c:v copy -c:a aac -b:a 320k \
            -map 0:v -map 1:a \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    else
        PAD=$(python3 -c "print(abs(float('$MANUAL_OFFSET')))")
        ffmpeg -y -i "$VIDEO" -i "$MIC" \
            -filter_complex "[1:a]adelay=${PAD}s|${PAD}s[delayed]" \
            -c:v copy -c:a aac -b:a 320k \
            -map 0:v -map "[delayed]" \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    fi

    echo "Saved: $OUTPUT"
    exit 0
fi

# === RECORD MODE ===
SESSION_NAME="${1:-session_$(date +%Y%m%d_%H%M%S)}"
SESSION_DIR="$SESSION_NAME"

ensure_adb

mkdir -p "$SESSION_DIR/.audio_raw" "$SESSION_DIR/.video_raw" "$SESSION_DIR/.video_processed"
mkdir -p "$(dirname "$LAST_SESSION_FILE")"
echo "$SESSION_DIR" > "$LAST_SESSION_FILE"

MIC_WAV="$SESSION_DIR/.audio_raw/mic.wav"

echo ""
echo "Scanning phone for existing videos..."
BEFORE=$(adb shell "ls -1 '$MCAM_DIR'/*.mp4 2>/dev/null" | tr -d '\r' | sort)

echo ""
echo "=== Session: $SESSION_DIR ==="
echo "Recording PC mic (continuous)."
echo "Record as many videos as you want on MotionCam Pro."
echo "Press ENTER when all done."
echo ""

pw-record "$MIC_WAV" &
PWREC_PID=$!

read -r
kill "$PWREC_PID" 2>/dev/null
wait "$PWREC_PID" 2>/dev/null || true

echo ""
echo "=== Processing ==="

echo "Looking for new videos on phone..."
AFTER=$(adb shell "ls -1 '$MCAM_DIR'/*.mp4 2>/dev/null" | tr -d '\r' | sort)
NEW_FILES=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))

if [[ -z "$NEW_FILES" ]]; then
    echo "No new videos found on phone."
    echo "Raw mic saved: $MIC_WAV"
    exit 1
fi

TAKE_NUM=0
while IFS= read -r VIDEO_REMOTE; do
    TAKE_NUM=$((TAKE_NUM + 1))
    PADNUM=$(printf "%03d" "$TAKE_NUM")
    BASENAME=$(basename "$VIDEO_REMOTE")
    LOCAL_NAME="${PADNUM}_${BASENAME}"

    echo "Pulling take $TAKE_NUM: $BASENAME"
    adb pull "$VIDEO_REMOTE" "$SESSION_DIR/.video_raw/$LOCAL_NAME" 2>&1
done <<< "$NEW_FILES"

echo ""
echo "Pulled $TAKE_NUM video(s). Syncing..."
echo ""

for i in $(seq 1 "$TAKE_NUM"); do
    sync_take "$SESSION_DIR" "$i"
done

# Concatenate all takes into one video, numbered by day
TODAY=$(date +%Y%m%d)
EXISTING=$(ls -1 "$SESSION_DIR/" 2>/dev/null | grep -cE "^${TODAY}_[0-9]+\.mp4$" || true)
EXISTING=${EXISTING:-0}
FINAL_NUM=$((EXISTING + 1))
FINAL_OUTPUT="$SESSION_DIR/${TODAY}_$(printf "%02d" "$FINAL_NUM").mp4"
CONCAT_LIST="$SESSION_DIR/.video_raw/concat.txt"
> "$CONCAT_LIST"
for i in $(seq 1 "$TAKE_NUM"); do
    PADNUM=$(printf "%03d" "$i")
    TAKE_FILE="$(realpath "$SESSION_DIR/.video_processed/${PADNUM}_final.mp4")"
    if [[ -f "$TAKE_FILE" ]]; then
        echo "file '$TAKE_FILE'" >> "$CONCAT_LIST"
    fi
done

echo ""
echo "Concatenating all takes into one video..."
ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$FINAL_OUTPUT" 2>/dev/null

echo ""
echo "=== Session complete: $SESSION_DIR ==="
echo "$TAKE_NUM take(s) synced."
echo ""
echo "Individual takes: $SESSION_DIR/.video_processed/"
ls -1 "$SESSION_DIR/.video_processed/"*_final.mp4 2>/dev/null
echo ""
echo "Combined: $FINAL_OUTPUT"
