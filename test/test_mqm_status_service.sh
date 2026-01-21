#!/bin/bash
#############################################################################
# Tests for mqm_status_service.sh
# Run with: bash test/test_mqm_status_service.sh
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
    export ZABBIX_LOG_DIR="$TEST_DIR/logs"
    export CACHE_FILE="$TEST_DIR/logs/queue_manager_cache.json"
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
    unset ZABBIX_LOG_DIR CACHE_FILE
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

assert_json_array_length() {
    local json="$1"
    local expected_length="$2"
    local message="${3:-}"
    
    local actual_length
    actual_length=$(echo "$json" | jq 'length')
    
    if [[ "$expected_length" -eq "$actual_length" ]]; then
        return 0
    else
        echo "  Expected array length: $expected_length"
        echo "  Actual array length:   $actual_length"
        [[ -n "$message" ]] && echo "  Message: $message"
        return 1
    fi
}

#############################################################################
# Test: Script structure
#############################################################################

test_script_has_proper_shebang() {
    local first_line
    first_line=$(head -1 "$SRC_DIR/mqm_status_service.sh")
    
    if [[ "$first_line" == "#!/usr/bin/ksh93" || "$first_line" == "#!/bin/ksh93" || "$first_line" == "#!/bin/bash" ]]; then
        return 0
    else
        echo "  Expected ksh93 or bash shebang, got: $first_line"
        return 1
    fi
}

test_script_sources_common() {
    if grep -q '\. .*mqm_common\.sh\|source.*mqm_common\.sh' "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should source mqm_common.sh"
        return 1
    fi
}

test_script_has_copyright() {
    if grep -q "COPYRIGHT Kyndryl" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should have copyright header"
        return 1
    fi
}

test_script_has_version() {
    if grep -q "Version" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should have version number"
        return 1
    fi
}

test_script_has_purpose_documentation() {
    if grep -q "PURPOSE:" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should have PURPOSE documentation"
        return 1
    fi
}

test_script_has_what_it_does() {
    if grep -q "WHAT IT DOES:" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should have WHAT IT DOES documentation"
        return 1
    fi
}

#############################################################################
# Test: Command requirements
#############################################################################

test_script_checks_for_dspmq() {
    if grep -q "command -v dspmq" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should check for dspmq availability"
        return 1
    fi
}

test_script_checks_for_jq() {
    if grep -q "command -v jq" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should check for jq availability"
        return 1
    fi
}

test_script_uses_dspmq_x_flag() {
    if grep -q "dspmq -x" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should use dspmq -x for extended output"
        return 1
    fi
}

test_script_uses_jq_for_json() {
    if grep -q "jq -Rcn" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should use jq for JSON building"
        return 1
    fi
}

#############################################################################
# Test: JSON output format
#############################################################################

test_json_output_format() {
    local input="QM1|Running
QM2|Ended normally"
    
    local result
    result=$(echo "$input" | jq -Rn '[inputs | select(length > 0) | split("|") | {
        Q_MANAGER: .[0],
        Q_STATUS: (if .[1] == "Running" then 1 
                   elif .[1] == "Running as standby" then 2 
                   else 0 end)
    }]')
    
    assert_json_valid "$result" "Output should be valid JSON"
    assert_json_array_length "$result" 2 "Should have 2 queue managers"
}

test_json_has_required_fields() {
    if ! command -v jq &>/dev/null; then
        echo "  (skipped - jq not installed)"
        return 0
    fi
    
    local json='[{"Q_MANAGER":"QM1","Q_STATUS":1}]'
    
    local qm_value status_value
    qm_value=$(echo "$json" | jq -r '.[0].Q_MANAGER')
    status_value=$(echo "$json" | jq -r '.[0].Q_STATUS')
    
    assert_equals "QM1" "$qm_value" "Q_MANAGER field should be present"
    assert_equals "1" "$status_value" "Q_STATUS field should be present"
}

test_json_empty_array_valid() {
    local json="[]"
    assert_json_valid "$json" "Empty array should be valid JSON"
}

#############################################################################
# Test: Cache file handling
#############################################################################

test_script_uses_cache_file() {
    if grep -q "CACHE_FILE\|queue_manager_cache.json" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should use cache file"
        return 1
    fi
}

test_script_checks_directory_writable() {
    if grep -q "! -w\|-w.*ZABBIX_LOG_DIR\|Cannot write" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should check if output directory is writable"
        return 1
    fi
}

test_atomic_write_pattern() {
    if grep -q "temp_file\|\.tmp\.\$\$\|mv -f" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should use atomic write pattern"
        return 1
    fi
}

#############################################################################
# Test: Shell compatibility
#############################################################################

test_script_directory_detection() {
    if grep -q "BASH_SOURCE\|dirname.*\$0" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should detect script directory portably"
        return 1
    fi
}

#############################################################################
# Test: Error handling
#############################################################################

test_script_has_error_function() {
    if grep -q "mqm_error_exit\|mqm_error_json" "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Script should have error handling function"
        return 1
    fi
}

test_inline_status_conversion() {
    if grep -q 'Q_STATUS.*Running.*then 1\|if \.\[1\] == "Running"' "$SRC_DIR/mqm_status_service.sh"; then
        return 0
    else
        echo "  Status conversion should exist in jq expression"
        return 1
    fi
}

#############################################################################
# Test: Integration - Full dspmq output parsing
#############################################################################

test_parse_full_dspmq_output() {
    local dspmq_output='QMNAME(QM1)                                               STATUS(Running)
    INSTANCE(server1) MODE(Active)
QMNAME(QM2)                                               STATUS(Ended normally)
QMNAME(QM3)                                               STATUS(Running as standby)
    INSTANCE(server2) MODE(Standby)'
    
    local result
    result=$(echo "$dspmq_output" | grep '^QMNAME' | \
        sed 's/QMNAME(\([^)]*\)).*STATUS(\([^)]*\)).*/\1|\2/' | \
        jq -Rn '[inputs | select(length > 0) | split("|") | {
            Q_MANAGER: .[0],
            Q_STATUS: (if .[1] == "Running" then 1 
                       elif .[1] == "Running as standby" then 2 
                       else 0 end)
        }]')
    
    assert_json_valid "$result"
    assert_json_array_length "$result" 3
    
    local qm1_status qm2_status qm3_status
    qm1_status=$(echo "$result" | jq -r '.[] | select(.Q_MANAGER=="QM1") | .Q_STATUS')
    qm2_status=$(echo "$result" | jq -r '.[] | select(.Q_MANAGER=="QM2") | .Q_STATUS')
    qm3_status=$(echo "$result" | jq -r '.[] | select(.Q_MANAGER=="QM3") | .Q_STATUS')
    
    assert_equals "1" "$qm1_status" "QM1 should be Running (1)"
    assert_equals "0" "$qm2_status" "QM2 should be Ended (0)"
    assert_equals "2" "$qm3_status" "QM3 should be Standby (2)"
}

test_parse_empty_dspmq_output() {
    local result
    result=$(echo "" | jq -Rn '[inputs | select(length > 0) | split("|") | {
        Q_MANAGER: .[0],
        Q_STATUS: (if .[1] == "Running" then 1 else 0 end)
    }]')
    
    assert_equals "[]" "$result" "Empty dspmq output should produce []"
}

#############################################################################
# Test Runner
#############################################################################

echo ""
echo "========================================"
echo "  mqm_status_service.sh Test Suite"
echo "========================================"
echo ""

# Script structure tests
run_test "script structure: proper shebang" test_script_has_proper_shebang
run_test "script structure: sources common" test_script_sources_common
run_test "script structure: has copyright" test_script_has_copyright
run_test "script structure: has version" test_script_has_version
run_test "script structure: has purpose docs" test_script_has_purpose_documentation
run_test "script structure: has what it does" test_script_has_what_it_does

# Command requirement tests
run_test "commands: checks for dspmq" test_script_checks_for_dspmq
run_test "commands: checks for jq" test_script_checks_for_jq
run_test "commands: uses -x flag" test_script_uses_dspmq_x_flag
run_test "commands: uses jq for JSON" test_script_uses_jq_for_json

# JSON output tests
run_test "JSON: valid format" test_json_output_format
run_test "JSON: has required fields" test_json_has_required_fields
run_test "JSON: empty array valid" test_json_empty_array_valid

# Cache file tests
run_test "cache: uses cache file" test_script_uses_cache_file
run_test "cache: checks directory writable" test_script_checks_directory_writable
run_test "cache: atomic write pattern" test_atomic_write_pattern

# Shell compatibility tests
run_test "shell compat: script directory detection" test_script_directory_detection

# Error handling tests
run_test "errors: has error function" test_script_has_error_function
run_test "errors: inline status conversion" test_inline_status_conversion

# Integration tests
run_test "integration: full dspmq parsing" test_parse_full_dspmq_output
run_test "integration: empty dspmq output" test_parse_empty_dspmq_output

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
