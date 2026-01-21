#!/bin/bash
#############################################################################
# Run all tests for emkyu project
# Usage: bash test/run_all_tests.sh
#############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       emkyu Test Suite Runner          ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_suite() {
    local suite_name="$1"
    local suite_script="$2"
    
    ((TOTAL_SUITES++)) || true
    
    echo -e "${YELLOW}▶ Running: $suite_name${NC}"
    echo "----------------------------------------"
    
    if bash "$suite_script"; then
        ((PASSED_SUITES++)) || true
    else
        ((FAILED_SUITES++)) || true
    fi
    
    echo ""
}

# Run test suites
run_suite "mqm_common.sh tests" "$SCRIPT_DIR/test_mqm_common.sh"
run_suite "mqm_command_service.sh tests" "$SCRIPT_DIR/test_mqm_command_service.sh"
run_suite "mqm_status_service.sh tests" "$SCRIPT_DIR/test_mqm_status_service.sh"
run_suite "mqm_listen_msg.sh tests" "$SCRIPT_DIR/test_mqm_listen_msg.sh"

# Final summary
echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║            Final Summary               ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo "  Test Suites: $TOTAL_SUITES"
echo -e "  ${GREEN}Passed:${NC} $PASSED_SUITES"

if [[ $FAILED_SUITES -gt 0 ]]; then
    echo -e "  ${RED}Failed:${NC} $FAILED_SUITES"
    echo ""
    exit 1
else
    echo ""
    echo -e "  ${GREEN}${BOLD}All test suites passed!${NC}"
    echo ""
    exit 0
fi
