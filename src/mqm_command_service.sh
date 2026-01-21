#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
#
# mqm_command_service.sh - Monitor IBM MQ Command Server Status
#
# PURPOSE:
#   This script checks the command server status for each active queue manager
#   by running dspmqcsv. The output is used by Zabbix for monitoring.
#
# WHAT IT DOES:
#   1. Reads active queue managers from the cache file
#   2. Runs 'dspmqcsv' command for each queue manager as the mqm user
#   3. Checks if "Running" appears in the output
#   4. Outputs JSON array with status (1=Running, 0=Not running)
#
# OUTPUT FORMAT:
#   [{"Q_MANAGER":"QM1","Q_STATUS":"1"},{"Q_MANAGER":"QM2","Q_STATUS":"0"}]
#
# Compatible with: ksh93 (AIX native), bash 4+
#############################################################################

# NOTE: Do NOT use 'set -e' here - it causes silent failures with while/read loops

# Determine script directory (works in both ksh93 and bash)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Source common functions
. "$SCRIPT_DIR/mqm_common.sh"

# Note: PATH is set by mqm_common.sh using MQM_PATH variable

# Configuration
: "${ZABBIX_LOG_DIR:=/opt/zabbix/logs}"
STATUS_PATTERN="Running"
EXIT_SUCCESS=0
EXIT_NO_SUDO=3

# Debug output function
dbg() {
    if [[ -n "${DEBUG:-}" ]]; then
        print "[DEBUG] $*" >&2
    fi
}

# Check jq is available
if ! command -v jq >/dev/null 2>&1; then
    mqm_error_json "jq command not found. Please install jq."
    exit 1
fi

# Get active queue managers using common function
Q_MANAGERS=$(get_active_queue_managers) || {
    # Error already printed as JSON by the common function
    exit $?
}

# If no active queue managers, output empty JSON array and exit
if [[ "$Q_MANAGERS" = "[]" || -z "$Q_MANAGERS" ]]; then
    dbg "No active queue managers found"
    echo "[]"
    exit "$EXIT_SUCCESS"
fi

dbg "Active QMs: $Q_MANAGERS"

# Convert space-separated Q_MANAGERS string into a newline-separated list
Q_MANAGERS_NL=$(printf '%s\n' $Q_MANAGERS)

# --------------------------------------------------------------------------
# Embedded script (run as mqm user) - outputs "QM_NAME|STATUS" per line
# Uses MQM_PATH environment variable (exported by mqm_common.sh)
# --------------------------------------------------------------------------
MQSC_SCRIPT='
PATH="'"$MQM_PATH"':$PATH"
export PATH

while IFS= read -r queue; do
    # Skip empty lines
    if [ -z "$queue" ]; then
        continue
    fi
    
    # Validate queue manager name (alphanumeric, dots, underscores, hyphens only)
    case "$queue" in
        *[!a-zA-Z0-9._-]*)
            echo "${queue}|INVALID"
            continue
            ;;
    esac
    
    # Run dspmqcsv and check if "Running" appears in output
    output=$(dspmqcsv "$queue" 2>/dev/null)
    case "$output" in
        *Running*) echo "${queue}|Running" ;;
        *)         echo "${queue}|NotRunning" ;;
    esac
done
'

# Create temporary file for output
tmpfile="${ZABBIX_LOG_DIR}/mqm_command_$$.tmp"

# Ensure cleanup on exit
trap 'rm -f "$tmpfile"' EXIT

# --------------------------------------------------------------------------
# Execute embedded script as mqm user
# --------------------------------------------------------------------------
if [[ "$(id -un 2>/dev/null)" = "mqm" ]]; then
    dbg "Running as mqm user directly"
    echo "$Q_MANAGERS_NL" | /bin/sh -c "$MQSC_SCRIPT" > "$tmpfile" 2>/dev/null
elif command -v sudo >/dev/null 2>&1 && sudo -n -u mqm /bin/sh -c 'true' 2>/dev/null; then
    dbg "Running via sudo as mqm"
    if [[ -x /bin/ksh ]]; then
        echo "$Q_MANAGERS_NL" | sudo -n -u mqm /bin/ksh -c "$MQSC_SCRIPT" > "$tmpfile" 2>/dev/null
    elif [[ -x /bin/bash ]]; then
        echo "$Q_MANAGERS_NL" | sudo -n -u mqm /bin/bash -c "$MQSC_SCRIPT" > "$tmpfile" 2>/dev/null
    else
        echo "$Q_MANAGERS_NL" | sudo -n -u mqm /bin/sh -c "$MQSC_SCRIPT" > "$tmpfile" 2>/dev/null
    fi
else
    mqm_error_json "Cannot run as mqm non-interactively (configure sudoers)."
    exit "$EXIT_NO_SUDO"
fi

# --------------------------------------------------------------------------
# Build JSON output using jq (single pipeline, proper escaping)
# Input format: QM_NAME|Running or QM_NAME|NotRunning
# --------------------------------------------------------------------------
json_output=$(cat "$tmpfile" | jq -Rcn '[inputs | select(length > 0) | split("|") | {
    Q_MANAGER: .[0],
    Q_STATUS: (if .[1] == "Running" then "1" else "0" end)
}]') || json_output="[]"

dbg "JSON output: $json_output"

# Output to stdout for Zabbix agent
echo "$json_output"