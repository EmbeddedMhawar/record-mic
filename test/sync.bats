#!/usr/bin/env bats
# Tests for sync_take — uses full mocks (ffprobe, ffmpeg, venv_python)

load helpers

setup() {
    setup_mocks
    SESSION="$BATS_TEST_TMPDIR/session"
    mkdir -p "$SESSION/.video_raw" "$SESSION/.audio_raw" "$SESSION/.video_processed"
}

@test "sync_take: fails when video file not found" {
    touch "$SESSION/.audio_raw/mic.wav"
    run sync_take "$SESSION" 1
    assert_failure
    assert_output --partial "not found"
}

@test "sync_take: fails when mic file not found" {
    touch "$SESSION/.video_raw/001_260312_182925_VIDEO_001.mp4"
    run sync_take "$SESSION" 1 0 "$SESSION/.audio_raw/nonexistent.wav"
    assert_failure
    assert_output --partial "Mic recording not found"
}

@test "sync_take: succeeds with positive offset (video has audio track)" {
    touch "$SESSION/.video_raw/001_260312_182925_VIDEO_001.mp4"
    touch "$SESSION/.audio_raw/mic.wav"
    export MOCK_FFPROBE_DURATION="15.5"
    export MOCK_FFPROBE_STREAMS="codec_type=audio"
    export MOCK_AUDIO_OFFSET="0.5"

    run sync_take "$SESSION" 1 0 "$SESSION/.audio_raw/mic.wav"
    assert_success
    assert_output --partial "auto offset"
    assert_output --partial "saved"
}

@test "sync_take: applies adjustment to offset" {
    touch "$SESSION/.video_raw/001_260312_182925_VIDEO_001.mp4"
    touch "$SESSION/.audio_raw/mic.wav"
    export MOCK_FFPROBE_DURATION="10.0"
    export MOCK_FFPROBE_STREAMS="codec_type=audio"
    export MOCK_AUDIO_OFFSET="1.0"

    run sync_take "$SESSION" 1 "+0.5" "$SESSION/.audio_raw/mic.wav"
    assert_success
    assert_output --partial "adjustment"
    assert_output --partial "final offset 1.5s"
}
