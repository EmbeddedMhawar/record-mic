#!/usr/bin/env bash
# Test helpers — loaded by every .bats file

# Load bats libraries
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load "$TEST_DIR/test_helper/bats-support/load"
load "$TEST_DIR/test_helper/bats-assert/load"

# Source the script (functions only — main guard prevents side effects)
SCRIPT_UNDER_TEST="$TEST_DIR/../v0.5.1/record-mic.sh"
source "$SCRIPT_UNDER_TEST"

# Override constants AFTER sourcing (the script sets these at top-level)
export SCRIPT_DIR="$TEST_DIR/fixtures"
export VENV_PYTHON="venv_python"
export DEVICES_YAML="$TEST_DIR/fixtures/devices.yaml"
export LAST_SESSION_FILE="${BATS_TEST_TMPDIR:-/tmp}/last-session"

setup_mocks() {
    export PATH="$TEST_DIR/mocks:$PATH"
    # Re-set LAST_SESSION_FILE now that BATS_TEST_TMPDIR is available
    export LAST_SESSION_FILE="$BATS_TEST_TMPDIR/last-session"
}
