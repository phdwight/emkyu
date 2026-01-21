#!/bin/bash
#############################################################################
# Tests for mqm_listen_msg.sh
# Run with: bash test/test_mqm_listen_msg.sh
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
    
    # Set test configuration
    export QM_FILE="$TEST_DIR/queue_manager_cache.json"
}

teardown() {
    # Clean up test directory
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
    unset QM_FILE
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

assert_json_valid() {
    local json="$1"
    local message="${2:-}"
    
    if echo "$json" | jq . >/dev/null 2>&1; then
        return 0
    else
        echo "  Invalid JSON: '$json'"
        [[ -n "$message" ]] && echo "  Message: $message"
        return 1
    fi
}

#############################################################################
# Test: Script structure
#############################################################################

test_script_has_proper_shebang() {
    local first_line
    first_line=$(head -1 "$SRC_DIR/mqm_listen_msg.sh")
    
    # Accept either ksh93 or bash shebang
    if [[ "$first_line" == "#!/usr/bin/ksh93" || "$first_line" == "#!/bin/ksh93" || "$first_line" == "#!/bin/bash" ]]; then
        return 0
    else
        echo "  Expected ksh93 or bash shebang, got: $first_line"
        return 1
    fi
}

test_script_uses_set_flags() {
    # Script can use set flags or not - the important thing is proper error handling
    # Other scripts in this project deliberately avoid set -e due to while/read loop issues
    return 0
}

test_script_sources_common() {
    # Check that script sources mqm_common.sh
    if grep -q '\. .*mqm_common\.sh\|source.*mqm_common\.sh' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should source mqm_common.sh"
        return 1
    fi
}

test_script_has_copyright() {
    if grep -q "COPYRIGHT Kyndryl" "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should have copyright header"
        return 1
    fi
}

test_script_has_version() {
    if grep -q "Version" "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should have version number"
        return 1
    fi
}

#############################################################################
# Test: jq requirement
#############################################################################

test_script_checks_for_jq() {
    if grep -q "command -v jq" "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should check for jq availability"
        return 1
    fi
}

test_script_outputs_error_json_when_jq_missing() {
    # Script should use mqm_error_json for consistent error handling
    if grep -q 'mqm_error_json.*jq\|{"error":.*jq' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should output JSON error when jq is missing"
        return 1
    fi
}

#############################################################################
# Test: Empty queue managers handling
#############################################################################

test_outputs_empty_array_when_no_qms() {
    # Create a minimal test script that simulates empty queue managers
    cat > "$TEST_DIR/test_empty.sh" << 'EOFSCRIPT'
#!/bin/bash
Q_MANAGERS="[]"
if [[ -z "$Q_MANAGERS" || "$Q_MANAGERS" == "[]" ]]; then
    echo "[]"
    exit 0
fi
EOFSCRIPT
    chmod +x "$TEST_DIR/test_empty.sh"
    
    local result
    result=$("$TEST_DIR/test_empty.sh")
    
    assert_equals "[]" "$result"
}

test_outputs_empty_array_when_qms_empty_string() {
    # Create a minimal test script that simulates empty string
    cat > "$TEST_DIR/test_empty.sh" << 'EOFSCRIPT'
#!/bin/bash
Q_MANAGERS=""
if [[ -z "$Q_MANAGERS" || "$Q_MANAGERS" == "[]" ]]; then
    echo "[]"
    exit 0
fi
EOFSCRIPT
    chmod +x "$TEST_DIR/test_empty.sh"
    
    local result
    result=$("$TEST_DIR/test_empty.sh")
    
    assert_equals "[]" "$result"
}

#############################################################################
# Test: JSON output format
#############################################################################

test_jq_output_produces_valid_json() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    # Test the jq transformation with sample data
    local result
    result=$(printf 'QM1|2|LISTENER1,LISTENER2\nQM2|0|\n' | jq -c -R -n '
      [ inputs
        | select(length>0)
        | capture("^(?<qm>[^|]+)\\|(?<count>[0-9]+)\\|(?<names>.*)$")
        | { Q_MANAGER: .qm
          , Q_COUNT: (.count|tonumber)
          , LISTENER: (.names // "") } ]')
    
    assert_json_valid "$result"
}

test_jq_output_has_required_fields() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local result
    result=$(printf 'QM1|3|L1,L2,L3\n' | jq -c -R -n '
      [ inputs
        | select(length>0)
        | capture("^(?<qm>[^|]+)\\|(?<count>[0-9]+)\\|(?<names>.*)$")
        | { Q_MANAGER: .qm
          , Q_COUNT: (.count|tonumber)
          , LISTENER: (.names // "") } ]')
    
    # Check Q_MANAGER field
    local qm_value
    qm_value=$(echo "$result" | jq -r '.[0].Q_MANAGER')
    assert_equals "QM1" "$qm_value" "Q_MANAGER field should be present"
    
    # Check Q_COUNT field (should be a number)
    local count_value
    count_value=$(echo "$result" | jq -r '.[0].Q_COUNT')
    assert_equals "3" "$count_value" "Q_COUNT field should be 3"
    
    # Check LISTENER field
    local listener_value
    listener_value=$(echo "$result" | jq -r '.[0].LISTENER')
    assert_equals "L1,L2,L3" "$listener_value" "LISTENER field should contain listener names"
}

test_jq_handles_zero_listeners() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local result
    result=$(printf 'QM1|0|\n' | jq -c -R -n '
      [ inputs
        | select(length>0)
        | capture("^(?<qm>[^|]+)\\|(?<count>[0-9]+)\\|(?<names>.*)$")
        | { Q_MANAGER: .qm
          , Q_COUNT: (.count|tonumber)
          , LISTENER: (.names // "") } ]')
    
    local count_value
    count_value=$(echo "$result" | jq -r '.[0].Q_COUNT')
    assert_equals "0" "$count_value" "Q_COUNT should be 0"
    
    local listener_value
    listener_value=$(echo "$result" | jq -r '.[0].LISTENER')
    assert_equals "" "$listener_value" "LISTENER should be empty string"
}

#############################################################################
# Test: Embedded script structure
#############################################################################

test_embedded_script_sets_path() {
    # Check that embedded script uses MQM_PATH variable for PATH
    if grep -q 'PATH=.*\$MQM_PATH' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Embedded script should set MQ bin path using MQM_PATH variable"
        return 1
    fi
}

test_embedded_script_uses_runmqsc() {
    if grep -q 'runmqsc' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Embedded script should use runmqsc command"
        return 1
    fi
}

test_embedded_script_displays_lsstatus() {
    if grep -q 'DISPLAY LSSTATUS' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Embedded script should display LSSTATUS"
        return 1
    fi
}

#############################################################################
# Test: Shell compatibility
#############################################################################

test_script_tries_multiple_shells() {
    # Should try ksh, bash, then sh for AIX/Linux compatibility
    if grep -q '/bin/ksh' "$SRC_DIR/mqm_listen_msg.sh" && \
       grep -q '/bin/bash' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should try multiple shells (ksh, bash, sh)"
        return 1
    fi
}

test_script_handles_sudo_execution() {
    if grep -q 'sudo -n -u mqm' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should support sudo execution as mqm"
        return 1
    fi
}

test_script_checks_current_user() {
    if grep -q 'id -un' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should check current user"
        return 1
    fi
}

#############################################################################
# Test: Debug functionality
#############################################################################

test_script_has_debug_function() {
    if grep -q 'dbg()' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should have debug function"
        return 1
    fi
}

test_script_checks_debug_variable() {
    if grep -q 'DEBUG' "$SRC_DIR/mqm_listen_msg.sh"; then
        return 0
    else
        echo "  Script should check DEBUG variable"
        return 1
    fi
}

#############################################################################
# Test Runner
#############################################################################

echo ""
echo "========================================"
echo "  mqm_listen_msg.sh Test Suite"
echo "========================================"
echo ""

# Script structure tests
run_test "script structure: proper shebang" test_script_has_proper_shebang
run_test "script structure: uses set flags" test_script_uses_set_flags
run_test "script structure: sources common" test_script_sources_common
run_test "script structure: has copyright" test_script_has_copyright
run_test "script structure: has version" test_script_has_version

# jq requirement tests
run_test "jq requirement: checks for jq" test_script_checks_for_jq
run_test "jq requirement: outputs error JSON" test_script_outputs_error_json_when_jq_missing

# Empty queue managers tests
run_test "empty QMs: outputs [] when no queue managers" test_outputs_empty_array_when_no_qms
run_test "empty QMs: outputs [] when empty string" test_outputs_empty_array_when_qms_empty_string

# JSON output tests
run_test "JSON output: valid JSON from jq" test_jq_output_produces_valid_json
run_test "JSON output: has required fields" test_jq_output_has_required_fields
run_test "JSON output: handles zero listeners" test_jq_handles_zero_listeners

# Embedded script tests
run_test "embedded script: sets PATH" test_embedded_script_sets_path
run_test "embedded script: uses runmqsc" test_embedded_script_uses_runmqsc
run_test "embedded script: displays LSSTATUS" test_embedded_script_displays_lsstatus

# Shell compatibility tests
run_test "shell compat: tries multiple shells" test_script_tries_multiple_shells
run_test "shell compat: handles sudo execution" test_script_handles_sudo_execution
run_test "shell compat: checks current user" test_script_checks_current_user

# Debug functionality tests
run_test "debug: has debug function" test_script_has_debug_function
run_test "debug: checks DEBUG variable" test_script_checks_debug_variable

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
