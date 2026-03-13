#!/usr/bin/env bats
# Tests for device_connected, adb_for, ensure_device — uses mock adb

load helpers

setup() {
    setup_mocks
}

@test "device_connected: returns 0 when device is present" {
    export MOCK_ADB_DEVICES="ABC123	device"
    run device_connected "ABC123"
    assert_success
}

@test "device_connected: returns 1 when device not present" {
    export MOCK_ADB_DEVICES=""
    run device_connected "ABC123"
    assert_failure
}

@test "device_connected: returns 1 when device unauthorized" {
    export MOCK_ADB_DEVICES="ABC123	unauthorized"
    run device_connected "ABC123"
    assert_failure
}

@test "adb_for: passes serial via -s flag" {
    # Our mock adb prints ADB_SERIAL=<serial> to stderr for -s calls
    run adb_for "MYSERIAL" shell echo hello 2>&1
    assert_success
}

@test "ensure_device: already connected succeeds immediately" {
    export MOCK_ADB_DEVICES="ABC123	device"
    run ensure_device "TestPhone" "ABC123" "usb" "" ""
    assert_success
    assert_output --partial "already connected"
}

@test "ensure_device: USB device not found fails" {
    export MOCK_ADB_DEVICES=""
    run ensure_device "TestPhone" "ABC123" "usb" "" ""
    assert_failure
    assert_output --partial "not found on USB"
}
