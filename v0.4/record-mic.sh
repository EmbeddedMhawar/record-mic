#!/usr/bin/env bash
set -euo pipefail

# v0.3: Multi-take recorder with FFT auto-sync for MotionCam Pro
#       Supports audio from PC mic or Samsung phone via ADB.
#       Config-driven via config.json + setup wizard.
#
# Usage:
#   ./record-mic.sh setup                         # interactive setup wizard
#   ./record-mic.sh setup --show                  # show current config
#   ./record-mic.sh setup --mode                  # quick switch phone/pc mode
#   ./record-mic.sh [session_name]                # record session (multi-take)
#   ./record-mic.sh resync [session]              # re-sync all takes
#   ./record-mic.sh resync [session] 2 +0.5       # resync take 2 with +0.5s adjustment
#   ./record-mic.sh manual [session] 2 12.5       # manual offset for take 2
#   ./record-mic.sh del [session]                 # delete all cache & processed files
#
# Session structure:
#   session_*/
#   ├── .audio_raw/          # mic audio (PC or Samsung) + extracted refs + offsets
#   ├── .video_raw/          # unprocessed videos pulled from Pixel
#   ├── .video_processed/    # individual synced takes (xxx_final.mp4)
#   └── YYYYMMDD_NN.mp4      # all takes concatenated

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"
LAST_SESSION_FILE="$HOME/.cache/record-mic-last-session"

# ── Load config ──────────────────────────────────────────────────────────────
if [[ -f "$CONFIG" ]] && command -v jq &>/dev/null; then
    RECORDING_MODE=$(jq -r '.mode // "phone"' "$CONFIG")
    AUDIO_SRC=$(jq -r '.audio_source // "pc"' "$CONFIG")

    # Pixel (video source)
    PIXEL_DEVICE=$(jq -r '.phone.video_device // ""' "$CONFIG")
    MCAM_DIR=$(jq -r '.phone.mcam_dir // "/sdcard/DCIM/MotionCam"' "$CONFIG")
    PIXEL_WIFI_IP=$(jq -r '.phone.wifi_ip // "10.114.222.226"' "$CONFIG")
    PIXEL_WIFI_PORT=$(jq -r '.phone.wifi_port // "5555"' "$CONFIG")
    PIXEL_HOTSPOT_SSID=$(jq -r '.phone.hotspot_ssid // "Pixel"' "$CONFIG")
    PIXEL_HOTSPOT_PASS=$(jq -r '.phone.hotspot_pass // "adminadmin"' "$CONFIG")

    # Samsung (audio source)
    SAMSUNG_DEVICE=$(jq -r '.samsung.device // ""' "$CONFIG")
    SAMSUNG_REC_DIR=$(jq -r '.samsung.recording_dir // ""' "$CONFIG")
    SAMSUNG_WIFI_IP=$(jq -r '.samsung.wifi_ip // ""' "$CONFIG")
    SAMSUNG_WIFI_PORT=$(jq -r '.samsung.wifi_port // "5555"' "$CONFIG")

    # PC audio
    PC_AUDIO_SOURCE=$(jq -r '.pc.audio_source // "default"' "$CONFIG")
    PC_SAMPLE_RATE=$(jq -r '.pc.sample_rate // 48000' "$CONFIG")
    PC_CHANNELS=$(jq -r '.pc.channels // 2' "$CONFIG")

    AUDIO_BITRATE=$(jq -r '.audio.bitrate // "320k"' "$CONFIG")
else
    RECORDING_MODE="phone"
    AUDIO_SRC="pc"
    PIXEL_DEVICE=""
    MCAM_DIR="/sdcard/DCIM/MotionCam"
    PIXEL_WIFI_IP="10.114.222.226"
    PIXEL_WIFI_PORT="5555"
    PIXEL_HOTSPOT_SSID="Pixel"
    PIXEL_HOTSPOT_PASS="adminadmin"
    SAMSUNG_DEVICE=""
    SAMSUNG_REC_DIR=""
    SAMSUNG_WIFI_IP=""
    SAMSUNG_WIFI_PORT="5555"
    PC_AUDIO_SOURCE="default"
    PC_SAMPLE_RATE=48000
    PC_CHANNELS=2
    AUDIO_BITRATE="320k"
fi

# ── SETUP shortcut (must be before anything else) ────────────────────────────
if [[ "${1:-}" == "setup" ]]; then
    shift
    exec "$SCRIPT_DIR/setup.sh" "$@"
fi

# ── ADB helpers ──────────────────────────────────────────────────────────────

# Run adb command targeting a specific device
# Usage: adb_for <serial> <adb args...>
adb_for() {
    local serial="$1"; shift
    if [[ -n "$serial" ]]; then
        adb -s "$serial" "$@"
    else
        adb "$@"
    fi
}

# Check if a specific device is connected
device_connected() {
    local serial="$1"
    adb devices 2>/dev/null | grep -q "$serial.*device"
}

ensure_pixel() {
    if [[ -n "$PIXEL_DEVICE" ]] && device_connected "$PIXEL_DEVICE"; then
        echo "Pixel: connected ($PIXEL_DEVICE)"
        return 0
    fi

    # Try wireless
    echo "Pixel: not found, trying wireless $PIXEL_WIFI_IP:$PIXEL_WIFI_PORT..."
    if timeout 5 adb connect "$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT" 2>&1 | grep -q "connected"; then
        PIXEL_DEVICE="$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT"
        echo "Pixel: connected wirelessly."
        return 0
    fi

    # Try hotspot
    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
    if [[ "$CURRENT_SSID" != "$PIXEL_HOTSPOT_SSID" ]]; then
        echo "Connecting to Pixel hotspot..."
        nmcli connection delete "$PIXEL_HOTSPOT_SSID" 2>/dev/null || true
        if ! nmcli device wifi connect "$PIXEL_HOTSPOT_SSID" password "$PIXEL_HOTSPOT_PASS" ifname wlan0 2>&1; then
            echo "Error: Could not connect to Pixel hotspot."
            exit 1
        fi
    fi

    if timeout 5 adb connect "$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT" 2>&1 | grep -q "connected"; then
        PIXEL_DEVICE="$PIXEL_WIFI_IP:$PIXEL_WIFI_PORT"
        echo "Pixel: connected via hotspot."
        return 0
    fi

    echo "Error: Cannot connect to Pixel. Plug in USB."
    exit 1
}

ensure_samsung() {
    if [[ -n "$SAMSUNG_DEVICE" ]] && device_connected "$SAMSUNG_DEVICE"; then
        echo "Samsung: connected ($SAMSUNG_DEVICE)"
        return 0
    fi

    # Try wireless
    if [[ -n "$SAMSUNG_WIFI_IP" ]]; then
        echo "Samsung: trying $SAMSUNG_WIFI_IP:$SAMSUNG_WIFI_PORT..."
        if timeout 5 adb connect "$SAMSUNG_WIFI_IP:$SAMSUNG_WIFI_PORT" 2>&1 | grep -q "connected"; then
            SAMSUNG_DEVICE="$SAMSUNG_WIFI_IP:$SAMSUNG_WIFI_PORT"
            echo "Samsung: connected wirelessly."
            return 0
        fi
    fi

    echo "Error: Cannot connect to Samsung. Check WiFi or plug in USB."
    exit 1
}

# ── Sync and merge a single take ────────────────────────────────────────────
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
            -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" \
            -map 0:v -map 1:a \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    else
        local PAD
        PAD=$(python3 -c "print(abs(float('$FINAL_OFFSET')))")
        ffmpeg -y -i "$VIDEO" -i "$MIC" \
            -filter_complex "[1:a]adelay=${PAD}s|${PAD}s[delayed]" \
            -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" \
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

# ── DEL ──────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "del" ]]; then
    if [[ "${2:-}" == "*" ]]; then
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

# ── RESYNC ───────────────────────────────────────────────────────────────────
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

# ── MANUAL ───────────────────────────────────────────────────────────────────
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
            -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" \
            -map 0:v -map 1:a \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    else
        PAD=$(python3 -c "print(abs(float('$MANUAL_OFFSET')))")
        ffmpeg -y -i "$VIDEO" -i "$MIC" \
            -filter_complex "[1:a]adelay=${PAD}s|${PAD}s[delayed]" \
            -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" \
            -map 0:v -map "[delayed]" \
            -t "$VDUR" \
            "$OUTPUT" 2>/dev/null
    fi

    echo "Saved: $OUTPUT"
    exit 0
fi

# ── RECORD MODE ──────────────────────────────────────────────────────────────
SESSION_NAME="${1:-session_$(date +%Y%m%d_%H%M%S)}"
SESSION_DIR="$SESSION_NAME"

mkdir -p "$SESSION_DIR/.audio_raw" "$SESSION_DIR/.video_raw" "$SESSION_DIR/.video_processed"
mkdir -p "$(dirname "$LAST_SESSION_FILE")"
echo "$SESSION_DIR" > "$LAST_SESSION_FILE"

MIC_WAV="$SESSION_DIR/.audio_raw/mic.wav"

echo ""
if [[ "$RECORDING_MODE" == "phone" ]]; then
    echo "=== Mode: 📱 Phone (Pixel video + ${AUDIO_SRC} audio) ==="
else
    echo "=== Mode: 🖥  PC only ==="
fi

if [[ "$RECORDING_MODE" == "phone" ]]; then
    # ── PHONE MODE ───────────────────────────────────────────────────────────
    # Uses a manifest file to track which videos have been processed.
    # No before/after diff — just finds all unprocessed videos on the phone.
    MANIFEST="$HOME/.cache/record-mic-processed.txt"
    touch "$MANIFEST"

    ensure_pixel
    if [[ "$AUDIO_SRC" == "samsung" ]]; then
        ensure_samsung
    fi

    echo ""
    echo "=== Session: $SESSION_DIR ==="

    if [[ "$AUDIO_SRC" == "pc" ]]; then
        echo "Recording PC mic (continuous)."
        echo "Record as many videos as you want on MotionCam Pro."
        echo "Press ENTER when all done."

        PW_ARGS=()
        if [[ "$PC_AUDIO_SOURCE" != "default" ]]; then
            PW_ARGS+=(--target "$PC_AUDIO_SOURCE")
        fi
        PW_ARGS+=(--rate "$PC_SAMPLE_RATE" --channels "$PC_CHANNELS")
        pw-record "${PW_ARGS[@]}" "$MIC_WAV" &
        PWREC_PID=$!
        echo ""
        read -r
        kill "$PWREC_PID" 2>/dev/null
        wait "$PWREC_PID" 2>/dev/null || true
    else
        echo "📱 Audio source: Samsung"
        echo "Make sure you've already recorded video on Pixel + audio on Samsung."
        echo "Press ENTER to pull and sync."
        echo ""
        read -r
    fi

    echo ""
    echo "=== Processing ==="

    # ── Find unprocessed videos on Pixel ──
    echo "Scanning Pixel for videos..."
    ALL_VIDEOS=$(adb_for "$PIXEL_DEVICE" shell "ls -1t '$MCAM_DIR'/*.mp4 2>/dev/null || true" | tr -d '\r')

    # Filter out already-processed files
    NEW_FILES=""
    while IFS= read -r VIDEO_REMOTE; do
        [[ -z "$VIDEO_REMOTE" ]] && continue
        BASENAME=$(basename "$VIDEO_REMOTE")
        if ! grep -qxF "$BASENAME" "$MANIFEST"; then
            NEW_FILES="${NEW_FILES}${VIDEO_REMOTE}"$'\n'
        fi
    done <<< "$ALL_VIDEOS"
    NEW_FILES=$(echo "$NEW_FILES" | sed '/^$/d' | sort)

    if [[ -z "$NEW_FILES" ]]; then
        echo "No unprocessed videos found on Pixel."
        echo ""
        echo "All videos on phone are already in the manifest."
        echo "To reprocess, remove entries from: $MANIFEST"
        [[ "$AUDIO_SRC" == "pc" && -f "$MIC_WAV" ]] && echo "Raw mic saved: $MIC_WAV"
        exit 1
    fi

    VIDEO_COUNT=$(echo "$NEW_FILES" | wc -l)
    echo "Found $VIDEO_COUNT unprocessed video(s):"
    echo "$NEW_FILES" | while read -r f; do echo "  $(basename "$f")"; done
    echo ""

    TAKE_NUM=0
    while IFS= read -r VIDEO_REMOTE; do
        TAKE_NUM=$((TAKE_NUM + 1))
        PADNUM=$(printf "%03d" "$TAKE_NUM")
        BASENAME=$(basename "$VIDEO_REMOTE")
        LOCAL_NAME="${PADNUM}_${BASENAME}"

        echo "Pulling take $TAKE_NUM: $BASENAME"
        adb_for "$PIXEL_DEVICE" pull "$VIDEO_REMOTE" "$SESSION_DIR/.video_raw/$LOCAL_NAME" 2>&1

        # Mark as processed in manifest
        echo "$BASENAME" >> "$MANIFEST"
    done <<< "$NEW_FILES"

    # ── Pull audio from Samsung ──
    if [[ "$AUDIO_SRC" == "samsung" ]]; then
        echo ""
        echo "Scanning Samsung for audio recordings..."
        SAMSUNG_MANIFEST="$HOME/.cache/record-mic-samsung-processed.txt"
        touch "$SAMSUNG_MANIFEST"

        ALL_SAMSUNG=$(adb_for "$SAMSUNG_DEVICE" shell "ls -1t '$SAMSUNG_REC_DIR'/*.wav '$SAMSUNG_REC_DIR'/*.m4a '$SAMSUNG_REC_DIR'/*.mp3 2>/dev/null || true" | tr -d '\r')

        SAMSUNG_NEW=""
        while IFS= read -r REC_REMOTE; do
            [[ -z "$REC_REMOTE" ]] && continue
            REC_BASE=$(basename "$REC_REMOTE")
            if ! grep -qxF "$REC_BASE" "$SAMSUNG_MANIFEST"; then
                SAMSUNG_NEW="${SAMSUNG_NEW}${REC_REMOTE}"$'\n'
            fi
        done <<< "$ALL_SAMSUNG"
        SAMSUNG_NEW=$(echo "$SAMSUNG_NEW" | sed '/^$/d')

        if [[ -z "$SAMSUNG_NEW" ]]; then
            echo "No unprocessed audio recordings on Samsung."
            echo "To reprocess, remove entries from: $SAMSUNG_MANIFEST"
            exit 1
        fi

        # Use the most recent unprocessed recording
        SAMSUNG_LATEST=$(echo "$SAMSUNG_NEW" | head -1)
        SAMSUNG_BASENAME=$(basename "$SAMSUNG_LATEST")
        SAMSUNG_LOCAL="$SESSION_DIR/.audio_raw/samsung_raw_${SAMSUNG_BASENAME}"

        SAMSUNG_COUNT=$(echo "$SAMSUNG_NEW" | wc -l)
        echo "Found $SAMSUNG_COUNT unprocessed recording(s). Using latest: $SAMSUNG_BASENAME"

        echo "Pulling Samsung audio: $SAMSUNG_BASENAME"
        adb_for "$SAMSUNG_DEVICE" pull "$SAMSUNG_LATEST" "$SAMSUNG_LOCAL" 2>&1

        echo "Converting to mic.wav..."
        ffmpeg -y -i "$SAMSUNG_LOCAL" -ar 48000 -ac 1 "$MIC_WAV" 2>/dev/null
        echo "Samsung audio ready: $MIC_WAV"

        # Mark as processed
        echo "$SAMSUNG_BASENAME" >> "$SAMSUNG_MANIFEST"
    fi

    echo ""
    echo "Pulled $TAKE_NUM video(s). Syncing..."
    echo ""

    for i in $(seq 1 "$TAKE_NUM"); do
        sync_take "$SESSION_DIR" "$i"
    done

    # Concatenate
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

else
    # ── PC ONLY MODE ─────────────────────────────────────────────────────────
    PW_ARGS=()
    if [[ "$PC_AUDIO_SOURCE" != "default" ]]; then
        PW_ARGS+=(--target "$PC_AUDIO_SOURCE")
    fi
    PW_ARGS+=(--rate "$PC_SAMPLE_RATE" --channels "$PC_CHANNELS")

    echo ""
    echo "=== Session: $SESSION_DIR ==="
    echo "Recording audio from PC."
    echo "Press ENTER to stop recording."
    echo ""

    pw-record "${PW_ARGS[@]}" "$MIC_WAV" &
    PWREC_PID=$!

    read -r
    kill "$PWREC_PID" 2>/dev/null
    wait "$PWREC_PID" 2>/dev/null || true

    DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$MIC_WAV" 2>/dev/null || echo "unknown")

    echo ""
    echo "=== Session complete: $SESSION_DIR ==="
    echo "Recording: $MIC_WAV (${DURATION}s)"
fi
