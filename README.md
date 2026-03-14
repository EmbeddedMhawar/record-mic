# Audsync

Audsync is a tool for multi-camera and high-quality audio recording synchronization using Android devices (via ADB). It's designed for workflows where you record video on one device (e.g., Pixel with MotionCam Pro) and professional audio on another (e.g., Samsung with a Voice Recorder app), then need to automatically pull and sync them.

## Current Features

- **Device Management**: Interactively add and configure Android devices over USB or Wi-Fi.
- **Automatic Sync**: Uses FFT-based cross-correlation to calculate the exact offset between video and reference audio tracks.
- **Multi-Take Support**: Pulls multiple takes from devices and syncs them individually.
- **Session-Based Organization**: Automatically organizes recordings into session folders.
- **Automatic Concatenation**: Groups takes by audio session and concatenates them into final video files.

## Workflow

1.  **Setup**: Run `python setup_devices.py` to add your audio and video devices.
2.  **Record**: Start recording video on your camera phone and audio on your recorder phone.
3.  **Sync**: Run `./record-mic.sh [session_name]` to pull the files from the devices and automatically sync them based on audio fingerprints.

## Future Ideas: Options-Based Editing

Instead of repetitive manual editing, the goal is to implement **options-based editing**:

1.  **Configuration Phase**: At the first step, the user provides the videos and audios and selects from predefined options (preferences) for how they want the final video to be edited and processed.
2.  **Preference Saving**: These selections are saved as a configuration for future use.
3.  **Automatic Processing**: Next time, the user only needs to provide the raw videos/audios. The system will automatically apply the saved preferences to edit and process the media without further manual intervention.

---
*Note: This project uses `adb`, `ffmpeg`, `numpy`, and `scipy`.*
