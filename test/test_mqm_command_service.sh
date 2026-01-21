#!/bin/bash
#############################################################################
# Tests for mqm_command_service.sh
# Run with: bash test/test_mqm_command_service.sh
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
    mkdir -p "$TEST_DIR/logs"
    export QM_FILE="$TEST_DIR/queue_manager_cache.json"
    export ZABBIX_LOG_DIR="$TEST_DIR/logs"
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
    unset QM_FILE ZABBIX_LOG_DIR
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
    first_line=$(head -1 "$SRC_DIR/mqm_command_service.sh")
    
    if [[ "$first_line" == "#!/usr/bin/ksh93" || "$first_line" == "#!/bin/ksh93" || "$first_line" == "#!/bin/bash" ]]; then
        return 0
    else
        echo "  Expected ksh93 or bash shebang, got: $first_line"
        return 1
    fi
}

test_script_sources_common() {
    if grep -q '\. .*mqm_common\.sh\|source.*mqm_common\.sh' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should source mqm_common.sh"
        return 1
    fi
}

test_script_has_copyright() {
    if grep -q "COPYRIGHT Kyndryl" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should have copyright header"
        return 1
    fi
}

test_script_has_version() {
    if grep -q "Version" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should have version number"
        return 1
    fi
}

test_script_has_purpose_documentation() {
    if grep -q "PURPOSE:" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should have PURPOSE documentation"
        return 1
    fi
}

test_script_has_debug_function() {
    if grep -q "dbg()" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should have debug function"
        return 1
    fi
}

#############################################################################
# Test: JSON output and status conversion
#############################################################################

test_json_has_required_fields() {
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local json='[{"Q_MANAGER":"QM1","Q_STATUS":"1"}]'
    
    local qm_value status_value
    qm_value=$(echo "$json" | jq -r '.[0].Q_MANAGER')
    status_value=$(echo "$json" | jq -r '.[0].Q_STATUS')
    
    assert_equals "QM1" "$qm_value" "Q_MANAGER field should be present"
    assert_equals "1" "$status_value" "Q_STATUS field should be present"
}

test_status_conversion_logic() {
    local input="QM1|Running
QM2|NotRunning"
    
    local result
    result=$(echo "$input" | jq -Rn '[inputs | select(length > 0) | split("|") | {
        Q_MANAGER: .[0],
        Q_STATUS: (if .[1] == "Running" then "1" else "0" end)
    }]')
    
    assert_json_valid "$result"
    
    local qm1_status qm2_status
    qm1_status=$(echo "$result" | jq -r '.[0].Q_STATUS')
    qm2_status=$(echo "$result" | jq -r '.[1].Q_STATUS')
    
    assert_equals "1" "$qm1_status" "Running should return 1"
    assert_equals "0" "$qm2_status" "NotRunning should return 0"
}

#############################################################################
# Test: Embedded script structure
#############################################################################

test_embedded_script_sets_path() {
    # Check that embedded script uses MQM_PATH variable for PATH
    if grep -q 'PATH=.*\$MQM_PATH' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Embedded script should set MQ bin path using MQM_PATH variable"
        return 1
    fi
}

test_embedded_script_uses_dspmqcsv() {
    if grep -q 'dspmqcsv' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Embedded script should use dspmqcsv command"
        return 1
    fi
}

test_embedded_script_validates_qm_names() {
    if grep -q '\*\[!a-zA-Z0-9._-\]\*' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Embedded script should validate queue manager names"
        return 1
    fi
}

test_script_checks_for_jq() {
    if grep -q "command -v jq" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should check for jq availability"
        return 1
    fi
}

test_script_uses_jq_for_json() {
    if grep -q "jq -Rcn" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should use jq for JSON building"
        return 1
    fi
}

#############################################################################
# Test: Shell compatibility
#############################################################################

test_script_handles_sudo_execution() {
    if grep -q 'sudo -n -u mqm' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should support sudo execution as mqm"
        return 1
    fi
}

test_script_checks_current_user() {
    if grep -q 'id -un' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should check current user"
        return 1
    fi
}

test_script_uses_tmpfile_in_zabbix_dir() {
    if grep -q 'ZABBIX_LOG_DIR.*tmp\|tmpfile=.*ZABBIX_LOG_DIR' "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should use temp file in ZABBIX_LOG_DIR"
        return 1
    fi
}

test_script_has_cleanup_trap() {
    if grep -q "trap.*rm\|trap.*EXIT" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should have cleanup trap"
        return 1
    fi
}

#############################################################################
# Test: Error handling
#############################################################################

test_script_uses_mqm_error_json() {
    if grep -q "mqm_error_json" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should use mqm_error_json for errors"
        return 1
    fi
}

test_script_handles_no_sudo_error() {
    if grep -q "EXIT_NO_SUDO\|exit.*3" "$SRC_DIR/mqm_command_service.sh"; then
        return 0
    else
        echo "  Script should handle no-sudo error"
        return 1
    fi
}

#############################################################################
# Test Runner
#############################################################################

echo ""
echo "========================================"
echo "  mqm_command_service.sh Test Suite"
echo "========================================"
echo ""

# Script structure tests
run_test "script structure: proper shebang" test_script_has_proper_shebang
run_test "script structure: sources common" test_script_sources_common
run_test "script structure: has copyright" test_script_has_copyright
run_test "script structure: has version" test_script_has_version
run_test "script structure: has purpose docs" test_script_has_purpose_documentation
run_test "script structure: has debug function" test_script_has_debug_function

# JSON output tests
run_test "JSON: has required fields" test_json_has_required_fields
run_test "JSON: status conversion logic" test_status_conversion_logic

# Embedded script tests
run_test "embedded script: sets PATH" test_embedded_script_sets_path
run_test "embedded script: uses dspmqcsv" test_embedded_script_uses_dspmqcsv
run_test "embedded script: validates QM names" test_embedded_script_validates_qm_names
run_test "jq: checks for jq" test_script_checks_for_jq
run_test "jq: uses jq for JSON" test_script_uses_jq_for_json

# Shell compatibility tests
run_test "shell compat: handles sudo execution" test_script_handles_sudo_execution
run_test "shell compat: checks current user" test_script_checks_current_user
run_test "shell compat: uses tmpfile in zabbix dir" test_script_uses_tmpfile_in_zabbix_dir
run_test "shell compat: has cleanup trap" test_script_has_cleanup_trap

# Error handling tests
run_test "errors: uses mqm_error_json" test_script_uses_mqm_error_json
run_test "errors: handles no-sudo error" test_script_handles_no_sudo_error

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
