#!/usr/bin/env bats
# Tests for find_matching_mic — uses file stubs in BATS_TEST_TMPDIR

load helpers

setup() {
    SESSION="$BATS_TEST_TMPDIR/session"
    mkdir -p "$SESSION/.audio_raw"
}

@test "find_matching_mic: picks audio that started before video (closest)" {
    # Video at 20260312183000
    # Mic1 at 20260312101612 (before, farther)
    # Mic2 at 20260312182500 (before, closer) ← should pick this
    touch "$SESSION/.audio_raw/mic_20260312_101612.wav"
    touch "$SESSION/.audio_raw/mic_20260312_182500.wav"

    run find_matching_mic "20260312183000" "$SESSION"
    assert_success
    assert_output "$SESSION/.audio_raw/mic_20260312_182500.wav"
}

@test "find_matching_mic: falls back to closest overall when none started before" {
    # Video at 20260312100000
    # Both mics started after the video
    touch "$SESSION/.audio_raw/mic_20260312_100500.wav"  # 5 min after (closer)
    touch "$SESSION/.audio_raw/mic_20260312_120000.wav"  # 2 hrs after

    run find_matching_mic "20260312100000" "$SESSION"
    assert_success
    assert_output "$SESSION/.audio_raw/mic_20260312_100500.wav"
}

@test "find_matching_mic: falls back to legacy mic.wav" {
    # No timestamped mics, but legacy mic.wav exists
    touch "$SESSION/.audio_raw/mic.wav"

    run find_matching_mic "20260312183000" "$SESSION"
    assert_success
    assert_output "$SESSION/.audio_raw/mic.wav"
}

@test "find_matching_mic: returns empty when no audio files" {
    run find_matching_mic "20260312183000" "$SESSION"
    assert_success
    assert_output ""
}

@test "find_matching_mic: single mic file before video" {
    touch "$SESSION/.audio_raw/mic_20260312_180000.wav"

    run find_matching_mic "20260312183000" "$SESSION"
    assert_success
    assert_output "$SESSION/.audio_raw/mic_20260312_180000.wav"
}
