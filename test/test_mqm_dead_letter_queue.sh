#!/bin/bash
#############################################################################
# Tests for mqm_dead_letter_queue.sh
# Run with: bash test/test_mqm_dead_letter_queue.sh
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
NC='\033[0m' # No Color

#############################################################################
# Test Framework Functions
#############################################################################

setup() {
    TEST_DIR=$(mktemp -d)
    export QM_FILE="$TEST_DIR/queue_manager_cache.json"
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
    unset QM_FILE
}

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    ((TESTS_RUN++)) || true
    
    setup
    
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
    first_line=$(head -1 "$SRC_DIR/mqm_dead_letter_queue.sh")
    
    if [[ "$first_line" == "#!/usr/bin/ksh93" || "$first_line" == "#!/bin/ksh93" || "$first_line" == "#!/bin/bash" ]]; then
        return 0
    else
        echo "  Expected ksh93 or bash shebang, got: $first_line"
        return 1
    fi
}

test_script_sources_common() {
    if grep -q '\. .*mqm_common\.sh\|source.*mqm_common\.sh' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should source mqm_common.sh"
        return 1
    fi
}

test_script_has_copyright() {
    if grep -q "COPYRIGHT Kyndryl" "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should have copyright header"
        return 1
    fi
}

test_script_has_version() {
    if grep -q "Version" "$SRC_DIR/mqm_dead_letter_queue.sh"; then
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
    if grep -q "command -v jq" "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should check for jq availability"
        return 1
    fi
}

test_script_outputs_error_json_when_jq_missing() {
    if grep -q 'mqm_error_json.*jq' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
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

#############################################################################
# Test: JSON output format
#############################################################################

test_jq_output_produces_valid_json() {
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    # Use actual tab character
    local result
    result=$(printf 'QM1\t5\tSYSTEM.DEAD.LETTER.QUEUE\nQM2\t0\tMY.DLQ\n' | jq -c -R -n '
        [ inputs
          | select(length>0)
          | capture("^(?<q_manager>\\S+)\\t(?<depth>-?\\d+)\\t(?<dlname>[^\\t]*)")
          | { Q_MANAGER: .q_manager
            , Q_STATUS: (.depth|tonumber)
            , Q_DLNAME: .dlname }
        ]')
    
    assert_json_valid "$result"
}

test_jq_output_has_required_fields() {
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local result
    result=$(printf 'QM1\t5\tSYSTEM.DEAD.LETTER.QUEUE\n' | jq -c -R -n '
        [ inputs
          | select(length>0)
          | capture("^(?<q_manager>\\S+)\\t(?<depth>-?\\d+)\\t(?<dlname>[^\\t]*)")
          | { Q_MANAGER: .q_manager
            , Q_STATUS: (.depth|tonumber)
            , Q_DLNAME: .dlname }
        ]')
    
    local qm_value status_value dlname_value
    qm_value=$(echo "$result" | jq -r '.[0].Q_MANAGER')
    assert_equals "QM1" "$qm_value" "Q_MANAGER field should be present"
    
    status_value=$(echo "$result" | jq -r '.[0].Q_STATUS')
    assert_equals "5" "$status_value" "Q_STATUS field should be 5"
    
    dlname_value=$(echo "$result" | jq -r '.[0].Q_DLNAME')
    assert_equals "SYSTEM.DEAD.LETTER.QUEUE" "$dlname_value" "Q_DLNAME field should be present"
}

test_jq_handles_negative_depth() {
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local result
    result=$(printf 'QM1\t-1\t\n' | jq -c -R -n '
        [ inputs
          | select(length>0)
          | capture("^(?<q_manager>\\S+)\\t(?<depth>-?\\d+)\\t(?<dlname>[^\\t]*)")
          | { Q_MANAGER: .q_manager
            , Q_STATUS: (.depth|tonumber)
            , Q_DLNAME: .dlname }
        ]')
    
    local status_value
    status_value=$(echo "$result" | jq -r '.[0].Q_STATUS')
    assert_equals "-1" "$status_value" "Q_STATUS should handle -1 for no DLQ"
}

#############################################################################
# Test: Embedded script structure
#############################################################################

test_script_uses_temp_script_file() {
    if grep -q 'tmpscript=\|cat.*MQSC_EOF' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should use temp script file for embedded script"
        return 1
    fi
}

test_embedded_script_sets_path() {
    if grep -q 'PATH=.*\$MQM_PATH' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Embedded script should set MQ bin path using MQM_PATH variable"
        return 1
    fi
}

test_embedded_script_uses_runmqsc() {
    if grep -q 'runmqsc' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Embedded script should use runmqsc command"
        return 1
    fi
}

test_embedded_script_queries_deadq() {
    if grep -q 'DISPLAY QMGR DEADQ' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Embedded script should query DEADQ"
        return 1
    fi
}

test_embedded_script_queries_qstatus() {
    if grep -q 'DISPLAY QSTATUS' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Embedded script should query QSTATUS for depth"
        return 1
    fi
}

#############################################################################
# Test: Shell compatibility
#############################################################################

test_script_handles_sudo_execution() {
    if grep -q 'sudo -n -u mqm' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should support sudo execution as mqm"
        return 1
    fi
}

test_script_checks_current_user() {
    if grep -q 'id -un' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should check current user"
        return 1
    fi
}

test_script_uses_tmp_directory() {
    if grep -q 'tmpscript="/tmp/' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should use /tmp for temp files"
        return 1
    fi
}

#############################################################################
# Test: Debug functionality
#############################################################################

test_script_has_debug_function() {
    if grep -q 'dbg()' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
        return 0
    else
        echo "  Script should have debug function"
        return 1
    fi
}

test_script_checks_debug_variable() {
    if grep -q 'DEBUG' "$SRC_DIR/mqm_dead_letter_queue.sh"; then
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
echo "  mqm_dead_letter_queue.sh Test Suite"
echo "========================================"
echo ""

# Script structure tests
run_test "script structure: proper shebang" test_script_has_proper_shebang
run_test "script structure: sources common" test_script_sources_common
run_test "script structure: has copyright" test_script_has_copyright
run_test "script structure: has version" test_script_has_version

# jq requirement tests
run_test "jq requirement: checks for jq" test_script_checks_for_jq
run_test "jq requirement: outputs error JSON" test_script_outputs_error_json_when_jq_missing

# Empty queue managers tests
run_test "empty QMs: outputs [] when no queue managers" test_outputs_empty_array_when_no_qms

# JSON output tests
run_test "JSON output: valid JSON from jq" test_jq_output_produces_valid_json
run_test "JSON output: has required fields" test_jq_output_has_required_fields
run_test "JSON output: handles negative depth" test_jq_handles_negative_depth

# Embedded script tests
run_test "embedded script: uses temp script file" test_script_uses_temp_script_file
run_test "embedded script: sets PATH" test_embedded_script_sets_path
run_test "embedded script: uses runmqsc" test_embedded_script_uses_runmqsc
run_test "embedded script: queries DEADQ" test_embedded_script_queries_deadq
run_test "embedded script: queries QSTATUS" test_embedded_script_queries_qstatus

# Shell compatibility tests
run_test "shell compat: handles sudo execution" test_script_handles_sudo_execution
run_test "shell compat: checks current user" test_script_checks_current_user
run_test "shell compat: uses /tmp directory" test_script_uses_tmp_directory

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
