#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Check jq
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: sudo apt install jq"
    exit 1
fi

# Initialize config if missing
if [[ ! -f "$CONFIG" ]]; then
    cat > "$CONFIG" <<'EOF'
{
  "mode": "phone",
  "phone": {
    "mcam_dir": "/sdcard/DCIM/MotionCam",
    "wifi_ip": "10.114.222.226",
    "wifi_port": "5555",
    "hotspot_ssid": "Pixel",
    "hotspot_pass": "adminadmin"
  },
  "pc": {
    "audio_source": "default",
    "sample_rate": 48000,
    "channels": 2
  },
  "audio": {
    "format": "wav",
    "bitrate": "320k"
  }
}
EOF
fi

read_config() {
    jq -r "$1" "$CONFIG"
}

write_config() {
    local tmp
    tmp=$(jq "$1" "$CONFIG")
    echo "$tmp" > "$CONFIG"
}

show_config() {
    echo ""
    echo -e "${BOLD}Current configuration:${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local mode audio_src
    mode=$(read_config '.mode')
    audio_src=$(read_config '.audio_source')
    if [[ "$mode" == "phone" ]]; then
        echo -e "  Mode:           ${GREEN}📱 Phone (ADB)${NC}"
    else
        echo -e "  Mode:           ${GREEN}🖥  PC (direct recording)${NC}"
    fi
    if [[ "$audio_src" == "samsung" ]]; then
        echo -e "  Audio source:   ${GREEN}📱 Samsung (via ADB)${NC}"
    else
        echo -e "  Audio source:   ${GREEN}🎤 PC mic${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}Pixel (video):${NC}"
    echo -e "    Device:       $(read_config '.phone.video_device')"
    echo -e "    WiFi IP:      $(read_config '.phone.wifi_ip')"
    echo -e "    WiFi Port:    $(read_config '.phone.wifi_port')"
    echo -e "    Hotspot SSID: $(read_config '.phone.hotspot_ssid')"
    echo -e "    Hotspot Pass: $(read_config '.phone.hotspot_pass')"
    echo -e "    Camera Dir:   $(read_config '.phone.mcam_dir')"
    echo ""
    echo -e "  ${CYAN}Samsung (audio):${NC}"
    echo -e "    Device:       $(read_config '.samsung.device')"
    echo -e "    WiFi IP:      $(read_config '.samsung.wifi_ip')"
    echo -e "    WiFi Port:    $(read_config '.samsung.wifi_port')"
    echo -e "    Recording Dir:$(read_config '.samsung.recording_dir')"
    echo ""
    echo -e "  ${CYAN}PC audio:${NC}"
    echo -e "    Audio Source:  $(read_config '.pc.audio_source')"
    echo -e "    Sample Rate:   $(read_config '.pc.sample_rate')"
    echo -e "    Channels:      $(read_config '.pc.channels')"
    echo ""
    echo -e "  ${CYAN}Audio output:${NC}"
    echo -e "    Format:        $(read_config '.audio.format')"
    echo -e "    Bitrate:       $(read_config '.audio.bitrate')"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

prompt() {
    local prompt_text="$1" default="$2" var_name="$3"
    read -rp "  $prompt_text [$default]: " input
    eval "$var_name=\"${input:-$default}\""
}

setup_mode() {
    echo ""
    echo -e "${BOLD}Select recording mode:${NC}"
    echo "  1) 📱 Phone (ADB) - Record video on Pixel, sync with audio"
    echo "  2) 🖥  PC only    - Record audio directly from PC (no phone/ADB needed)"
    echo ""
    read -rp "  Choice [1]: " choice
    case "${choice:-1}" in
        1) write_config '.mode = "phone"'
           echo -e "  ${GREEN}✓ Mode set to: Phone (ADB)${NC}" ;;
        2) write_config '.mode = "pc"'
           echo -e "  ${GREEN}✓ Mode set to: PC only${NC}" ;;
        *) echo "  Invalid choice, keeping current." ;;
    esac

    echo ""
    echo -e "${BOLD}Select audio source (when in phone mode):${NC}"
    echo "  1) 🎤 PC mic      - Record audio continuously on this PC"
    echo "  2) 📱 Samsung     - Pull audio recording from Samsung phone via ADB"
    echo ""
    read -rp "  Choice [1]: " achoice
    case "${achoice:-1}" in
        1) write_config '.audio_source = "pc"'
           echo -e "  ${GREEN}✓ Audio source: PC mic${NC}" ;;
        2) write_config '.audio_source = "samsung"'
           echo -e "  ${GREEN}✓ Audio source: Samsung${NC}" ;;
        *) echo "  Invalid choice, keeping current." ;;
    esac
}

setup_phone() {
    echo ""
    echo -e "${BOLD}Pixel (video) settings:${NC}"
    local device ip port ssid pass mcam

    # Show connected devices
    echo ""
    echo -e "  ${CYAN}Connected ADB devices:${NC}"
    adb devices -l 2>/dev/null | grep "device " | sed 's/^/    /' || echo "    (none)"
    echo ""

    prompt "Pixel device serial (USB or IP:port)" "$(read_config '.phone.video_device')" device
    prompt "WiFi IP" "$(read_config '.phone.wifi_ip')" ip
    prompt "WiFi Port" "$(read_config '.phone.wifi_port')" port
    prompt "Hotspot SSID" "$(read_config '.phone.hotspot_ssid')" ssid
    prompt "Hotspot Password" "$(read_config '.phone.hotspot_pass')" pass
    prompt "Camera directory on phone" "$(read_config '.phone.mcam_dir')" mcam

    write_config "
        .phone.video_device = \"$device\" |
        .phone.wifi_ip = \"$ip\" |
        .phone.wifi_port = \"$port\" |
        .phone.hotspot_ssid = \"$ssid\" |
        .phone.hotspot_pass = \"$pass\" |
        .phone.mcam_dir = \"$mcam\"
    "
    echo -e "  ${GREEN}✓ Pixel settings saved.${NC}"
}

setup_samsung() {
    echo ""
    echo -e "${BOLD}Samsung (audio) settings:${NC}"
    local device ip port recdir

    echo ""
    echo -e "  ${CYAN}Connected ADB devices:${NC}"
    adb devices -l 2>/dev/null | grep "device " | sed 's/^/    /' || echo "    (none)"
    echo ""

    prompt "Samsung device (serial or IP:port)" "$(read_config '.samsung.device')" device
    prompt "Samsung WiFi IP" "$(read_config '.samsung.wifi_ip')" ip
    prompt "Samsung WiFi Port" "$(read_config '.samsung.wifi_port')" port
    prompt "Recording directory on Samsung" "$(read_config '.samsung.recording_dir')" recdir

    write_config "
        .samsung.device = \"$device\" |
        .samsung.wifi_ip = \"$ip\" |
        .samsung.wifi_port = \"$port\" |
        .samsung.recording_dir = \"$recdir\"
    "
    echo -e "  ${GREEN}✓ Samsung settings saved.${NC}"
}

setup_pc() {
    echo ""
    echo -e "${BOLD}PC audio settings:${NC}"

    # List available sources
    echo ""
    echo -e "  ${CYAN}Available audio sources:${NC}"
    if command -v pw-record &>/dev/null; then
        echo "  (PipeWire detected)"
        pw-cli list-objects Node 2>/dev/null | grep -E 'node.name|media.class' | head -20 || true
    elif command -v pactl &>/dev/null; then
        pactl list short sources 2>/dev/null | head -10 || true
    fi
    echo ""

    local source rate channels
    prompt "Audio source (device name or 'default')" "$(read_config '.pc.audio_source')" source
    prompt "Sample rate" "$(read_config '.pc.sample_rate')" rate
    prompt "Channels" "$(read_config '.pc.channels')" channels

    write_config "
        .pc.audio_source = \"$source\" |
        .pc.sample_rate = $rate |
        .pc.channels = $channels
    "
    echo -e "  ${GREEN}✓ PC audio settings saved.${NC}"
}

setup_audio_output() {
    echo ""
    echo -e "${BOLD}Audio output settings:${NC}"
    local fmt bitrate
    prompt "Format (wav/flac)" "$(read_config '.audio.format')" fmt
    prompt "AAC bitrate for video merge" "$(read_config '.audio.bitrate')" bitrate

    write_config "
        .audio.format = \"$fmt\" |
        .audio.bitrate = \"$bitrate\"
    "
    echo -e "  ${GREEN}✓ Audio output settings saved.${NC}"
}

test_adb() {
    echo ""
    echo -e "${BOLD}Testing ADB connections...${NC}"

    echo ""
    echo -e "  ${CYAN}All connected devices:${NC}"
    adb devices -l 2>/dev/null | grep "device " | sed 's/^/    /' || echo "    (none)"

    # Test Pixel
    local pixel_dev
    pixel_dev=$(read_config '.phone.video_device')
    echo ""
    echo -e "  ${CYAN}Pixel ($pixel_dev):${NC}"
    if adb devices 2>/dev/null | grep -q "$pixel_dev.*device"; then
        echo -e "    ${GREEN}✓ Connected${NC}"
        adb -s "$pixel_dev" shell "ls '$( read_config '.phone.mcam_dir' )' 2>/dev/null | tail -3" 2>/dev/null | sed 's/^/    /' || true
    else
        echo -e "    ${YELLOW}✗ Not connected${NC}"
    fi

    # Test Samsung
    local sam_dev
    sam_dev=$(read_config '.samsung.device')
    if [[ -n "$sam_dev" ]]; then
        echo ""
        echo -e "  ${CYAN}Samsung ($sam_dev):${NC}"
        if adb devices 2>/dev/null | grep -q "$sam_dev.*device"; then
            echo -e "    ${GREEN}✓ Connected${NC}"
            adb -s "$sam_dev" shell "ls '$(read_config '.samsung.recording_dir')' 2>/dev/null | tail -3" 2>/dev/null | sed 's/^/    /' || true
        else
            echo -e "    ${YELLOW}✗ Not connected. Trying ${sam_dev}...${NC}"
            if timeout 5 adb connect "$sam_dev" 2>&1 | grep -q "connected"; then
                echo -e "    ${GREEN}✓ Connected wirelessly${NC}"
            else
                echo -e "    ${YELLOW}✗ Could not connect${NC}"
            fi
        fi
    fi
}

# === Main menu ===
if [[ "${1:-}" == "--show" ]]; then
    show_config
    exit 0
fi

if [[ "${1:-}" == "--mode" ]]; then
    setup_mode
    exit 0
fi

if [[ "${1:-}" == "--phone" ]]; then
    setup_phone
    exit 0
fi

if [[ "${1:-}" == "--samsung" ]]; then
    setup_samsung
    exit 0
fi

if [[ "${1:-}" == "--pc" ]]; then
    setup_pc
    exit 0
fi

if [[ "${1:-}" == "--test" ]]; then
    test_adb
    exit 0
fi

# Interactive menu
echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      record-mic setup wizard         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"

show_config

while true; do
    echo -e "${BOLD}What would you like to configure?${NC}"
    echo "  1) Recording mode & audio source"
    echo "  2) Pixel (video) settings"
    echo "  3) Samsung (audio) settings"
    echo "  4) PC audio settings"
    echo "  5) Audio output settings"
    echo "  6) Test ADB connections"
    echo "  7) Show current config"
    echo "  8) Done"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
        1) setup_mode ;;
        2) setup_phone ;;
        3) setup_samsung ;;
        4) setup_pc ;;
        5) setup_audio_output ;;
        6) test_adb ;;
        7) show_config ;;
        8) echo -e "\n  ${GREEN}✓ Setup complete!${NC}"; show_config; break ;;
        *) echo "  Invalid choice." ;;
    esac
    echo ""
done
