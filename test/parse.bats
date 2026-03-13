#!/usr/bin/env bats
# Tests for parse_video_ts and parse_audio_ts — pure functions, no mocks needed

load helpers

@test "parse_video_ts: standard MotionCam filename" {
    run parse_video_ts "260312_182925_VIDEO_001.mp4"
    assert_success
    assert_output "20260312182925"
}

@test "parse_video_ts: different date" {
    run parse_video_ts "250115_093012_VIDEO_002.mp4"
    assert_success
    assert_output "20250115093012"
}

@test "parse_audio_ts: wav file" {
    run parse_audio_ts "recording2026-03-12 10-16-12.wav"
    assert_success
    assert_output "20260312101612"
}

@test "parse_audio_ts: m4a file" {
    run parse_audio_ts "recording2026-03-12 10-16-12.m4a"
    assert_success
    assert_output "20260312101612"
}

@test "parse_audio_ts: mp3 file" {
    run parse_audio_ts "recording2026-01-05 23-59-01.mp3"
    assert_success
    assert_output "20260105235901"
}

@test "parse_audio_ts: midnight timestamp" {
    run parse_audio_ts "recording2026-03-13 00-00-00.wav"
    assert_success
    assert_output "20260313000000"
}
