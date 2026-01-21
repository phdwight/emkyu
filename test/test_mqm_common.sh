#!/bin/bash
#############################################################################
# Tests for mqm_common.sh
# Run with: bash test/test_mqm_common.sh
# Note: Tests run under bash but verify ksh93-compatible code
#############################################################################

set -euo pipefail

# Test framework variables
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#############################################################################
# Test Framework Functions
#############################################################################

setup() {
    # Create temporary test directory
    TEST_DIR=$(mktemp -d)
    
    # Reset the loaded flag to allow re-sourcing
    unset _MQM_COMMON_LOADED
    
    # Set test configuration
    export QM_FILE="$TEST_DIR/queue_manager_cache.json"
    export MQM_PATH="/opt/mqm/bin"
}

teardown() {
    # Clean up test directory
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
    unset QM_FILE MQM_PATH _MQM_COMMON_LOADED
}

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    ((TESTS_RUN++)) || true
    
    setup
    
    # Run test in subshell to isolate failures
    local test_result=0
    ( set -e; "$test_func" ) || test_result=$?
    
    if [[ $test_result -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $test_name"
        ((TESTS_FAILED++)) || true
    fi
    
    teardown
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        [[ -n "$message" ]] && echo "  Message:  $message"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "  Expected to contain: '$needle'"
        echo "  Actual: '$haystack'"
        [[ -n "$message" ]] && echo "  Message: $message"
        return 1
    fi
}

assert_return_code() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" -eq "$actual" ]]; then
        return 0
    else
        echo "  Expected return code: $expected"
        echo "  Actual return code:   $actual"
        [[ -n "$message" ]] && echo "  Message: $message"
        return 1
    fi
}

#############################################################################
# Test: mqm_error_json
#############################################################################

test_mqm_error_json_simple_message() {
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(mqm_error_json "test error")
    
    assert_equals '{"error": "test error"}' "$result"
}

test_mqm_error_json_escapes_quotes() {
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(mqm_error_json 'error with "quotes"')
    
    assert_equals '{"error": "error with \"quotes\""}' "$result"
}

test_mqm_error_json_default_message() {
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(mqm_error_json)
    
    assert_equals '{"error": "Unknown error"}' "$result"
}

#############################################################################
# Test: check_jq_installed
#############################################################################

test_check_jq_installed_when_available() {
    # Only run if jq is actually installed
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    source "$SRC_DIR/mqm_common.sh"
    
    local rc=0
    check_jq_installed >/dev/null 2>&1 || rc=$?
    
    assert_return_code 0 "$rc"
}

test_check_jq_installed_returns_error_json() {
    # Create a subshell where jq is not in PATH
    (
        # Override PATH to exclude jq
        PATH="/usr/bin:/bin"
        hash -r  # Clear command hash table
        
        # Only run test if jq is now unavailable
        if command -v jq &>/dev/null; then
            echo "  (skipped - cannot hide jq from PATH)"
            exit 0
        fi
        
        unset _MQM_COMMON_LOADED
        source "$SRC_DIR/mqm_common.sh"
        
        local result
        result=$(check_jq_installed 2>&1)
        local rc=$?
        
        assert_return_code 1 "$rc" "Should return error code when jq missing"
        assert_contains "$result" "jq is not installed"
    )
}

#############################################################################
# Test: check_qm_file_exists
#############################################################################

test_check_qm_file_exists_when_present() {
    # Create the cache file
    echo '[]' > "$QM_FILE"
    
    source "$SRC_DIR/mqm_common.sh"
    
    local rc=0
    check_qm_file_exists >/dev/null 2>&1 || rc=$?
    
    assert_return_code 0 "$rc"
}

test_check_qm_file_exists_when_missing() {
    # Ensure file does not exist
    rm -f "$QM_FILE"
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    local rc=0
    result=$(check_qm_file_exists 2>&1) || rc=$?
    
    assert_return_code 2 "$rc" "Should return MQM_EXIT_NO_FILE (2)"
    assert_contains "$result" "does not exist"
}

#############################################################################
# Test: get_active_queue_managers
#############################################################################

test_get_active_queue_managers_returns_active_qms() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    # Create cache file with active queue managers
    cat > "$QM_FILE" << 'EOF'
[
    {"Q_MANAGER": "QM1", "Q_STATUS": 1},
    {"Q_MANAGER": "QM2", "Q_STATUS": 0},
    {"Q_MANAGER": "QM3", "Q_STATUS": 1}
]
EOF
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(get_active_queue_managers)
    
    # Should contain QM1 and QM3, but not QM2
    assert_contains "$result" "QM1" "Should include active QM1"
    assert_contains "$result" "QM3" "Should include active QM3"
    
    # QM2 has status 0, should not be included
    if [[ "$result" == *"QM2"* ]]; then
        echo "  Should NOT include inactive QM2"
        return 1
    fi
}

test_get_active_queue_managers_returns_empty_array_when_none_active() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    # Create cache file with no active queue managers
    cat > "$QM_FILE" << 'EOF'
[
    {"Q_MANAGER": "QM1", "Q_STATUS": 0},
    {"Q_MANAGER": "QM2", "Q_STATUS": 0}
]
EOF
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(get_active_queue_managers)
    
    assert_equals "[]" "$result"
}

test_get_active_queue_managers_returns_empty_array_for_empty_file() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    # Create empty JSON array
    echo '[]' > "$QM_FILE"
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(get_active_queue_managers)
    
    assert_equals "[]" "$result"
}

test_get_active_queue_managers_handles_single_qm() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    cat > "$QM_FILE" << 'EOF'
[
    {"Q_MANAGER": "SINGLE_QM", "Q_STATUS": 1}
]
EOF
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(get_active_queue_managers)
    
    assert_equals "SINGLE_QM" "$result"
}

test_get_active_queue_managers_space_separated_output() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    cat > "$QM_FILE" << 'EOF'
[
    {"Q_MANAGER": "QM1", "Q_STATUS": 1},
    {"Q_MANAGER": "QM2", "Q_STATUS": 1},
    {"Q_MANAGER": "QM3", "Q_STATUS": 1}
]
EOF
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    result=$(get_active_queue_managers)
    
    # Should be space-separated, not newline-separated
    assert_equals "QM1 QM2 QM3" "$result"
}

test_get_active_queue_managers_fails_when_file_missing() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    rm -f "$QM_FILE"
    
    source "$SRC_DIR/mqm_common.sh"
    
    local result
    local rc=0
    result=$(get_active_queue_managers 2>&1) || rc=$?
    
    assert_return_code 2 "$rc" "Should return MQM_EXIT_NO_FILE"
    assert_contains "$result" "does not exist"
}

#############################################################################
# Test: Source guard
#############################################################################

test_source_guard_prevents_double_loading() {
    source "$SRC_DIR/mqm_common.sh"
    
    # Verify the guard variable is set
    if [[ -z "${_MQM_COMMON_LOADED:-}" ]]; then
        echo "  _MQM_COMMON_LOADED should be set after sourcing"
        return 1
    fi
    
    # Source again - should return immediately
    source "$SRC_DIR/mqm_common.sh"
    
    # If we get here without error, the guard worked
    return 0
}

#############################################################################
# Test: Configuration overrides
#############################################################################

test_qm_file_can_be_overridden() {
    local custom_path="/custom/path/cache.json"
    export QM_FILE="$custom_path"
    
    source "$SRC_DIR/mqm_common.sh"
    
    # The QM_FILE should remain as our custom value
    assert_equals "$custom_path" "$QM_FILE"
}

test_mqm_path_can_be_overridden() {
    local custom_path="/custom/mqm/bin"
    export MQM_PATH="$custom_path"
    
    source "$SRC_DIR/mqm_common.sh"
    
    assert_contains "$PATH" "$custom_path" "PATH should contain custom MQM_PATH"
}

#############################################################################
# Test Runner
#############################################################################

echo ""
echo "========================================"
echo "  mqm_common.sh Test Suite"
echo "========================================"
echo ""

# mqm_error_json tests
run_test "mqm_error_json: simple message" test_mqm_error_json_simple_message
run_test "mqm_error_json: escapes quotes" test_mqm_error_json_escapes_quotes
run_test "mqm_error_json: default message" test_mqm_error_json_default_message

# check_jq_installed tests
run_test "check_jq_installed: returns 0 when available" test_check_jq_installed_when_available
run_test "check_jq_installed: returns error JSON when missing" test_check_jq_installed_returns_error_json

# check_qm_file_exists tests
run_test "check_qm_file_exists: returns 0 when present" test_check_qm_file_exists_when_present
run_test "check_qm_file_exists: returns error when missing" test_check_qm_file_exists_when_missing

# get_active_queue_managers tests
run_test "get_active_queue_managers: returns active QMs" test_get_active_queue_managers_returns_active_qms
run_test "get_active_queue_managers: returns [] when none active" test_get_active_queue_managers_returns_empty_array_when_none_active
run_test "get_active_queue_managers: returns [] for empty file" test_get_active_queue_managers_returns_empty_array_for_empty_file
run_test "get_active_queue_managers: handles single QM" test_get_active_queue_managers_handles_single_qm
run_test "get_active_queue_managers: space-separated output" test_get_active_queue_managers_space_separated_output
run_test "get_active_queue_managers: fails when file missing" test_get_active_queue_managers_fails_when_file_missing

# Source guard tests
run_test "source guard: prevents double loading" test_source_guard_prevents_double_loading

# Configuration tests
run_test "configuration: QM_FILE can be overridden" test_qm_file_can_be_overridden
run_test "configuration: MQM_PATH can be overridden" test_mqm_path_can_be_overridden

# Summary
echo ""
echo "========================================"
echo "  Results: $TESTS_PASSED/$TESTS_RUN passed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
else
    echo -e "  ${GREEN}All tests passed!${NC}"
    exit 0
fi
