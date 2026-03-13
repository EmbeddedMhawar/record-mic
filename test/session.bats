#!/usr/bin/env bats
# Tests for resolve_session

load helpers

setup() {
    export LAST_SESSION_FILE="$BATS_TEST_TMPDIR/last-session"
}

@test "resolve_session: returns dir directly when it exists" {
    mkdir -p "$BATS_TEST_TMPDIR/mysession"
    run resolve_session "$BATS_TEST_TMPDIR/mysession"
    assert_success
    assert_output "$BATS_TEST_TMPDIR/mysession"
}

@test "resolve_session: prepends session_ prefix" {
    mkdir -p "$BATS_TEST_TMPDIR/session_test1"
    # Pass just "test1" but resolve needs to find session_test1 in CWD.
    # We need to cd into BATS_TEST_TMPDIR for this to work.
    cd "$BATS_TEST_TMPDIR"
    run resolve_session "test1"
    assert_success
    assert_output "session_test1"
}

@test "resolve_session: reads from cache file" {
    echo "/some/cached/session" > "$LAST_SESSION_FILE"
    # No name, no directory — should read from cache
    run resolve_session ""
    assert_success
    assert_output "/some/cached/session"
}

@test "resolve_session: returns empty when no name and no cache" {
    rm -f "$LAST_SESSION_FILE"
    run resolve_session ""
    assert_success
    assert_output ""
}
