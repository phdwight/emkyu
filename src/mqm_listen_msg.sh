#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
#
# mqm_listen_msg.sh - Monitor IBM MQ Listener Status
#
# PURPOSE:
#   This script queries listener status for each active queue manager
#   and outputs the results in JSON format for Zabbix monitoring.
#
# WHAT IT DOES:
#   1. Reads active queue managers from the cache file
#   2. Runs 'runmqsc DISPLAY LSSTATUS(*)' for each queue manager as mqm user
#   3. Counts active listeners and extracts their names
#   4. Outputs JSON array with listener count and names
#
# OUTPUT FORMAT:
#   [{"Q_MANAGER":"QM1","Q_COUNT":2,"LISTENER":"LISTENER1,LISTENER2"}]
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
# Embedded script (run as mqm user) - outputs pipe-delimited: QM|COUNT|CSV_LISTENERS
# Uses MQM_PATH environment variable (exported by mqm_common.sh)
# --------------------------------------------------------------------------
MQSC_SCRIPT='
PATH="'"$MQM_PATH"':$PATH"
export PATH

while IFS= read -r QM; do
    # Skip empty lines
    if [ -z "$QM" ]; then
        continue
    fi
    
    # Validate queue manager name (alphanumeric, dots, underscores, hyphens only)
    case "$QM" in
        *[!a-zA-Z0-9._-]*)
            echo "${QM}|0|INVALID"
            continue
            ;;
    esac
    
    # Run DISPLAY LSSTATUS(*) command
    OUT=$(echo "DISPLAY LSSTATUS(*)" | runmqsc "$QM" 2>/dev/null)
    
    if [ -z "$OUT" ]; then
        echo "${QM}|0|"
        continue
    fi
    
    # Extract listener names and build CSV
    NAMES=$(echo "$OUT" | grep "LISTENER(" | grep -v "DISPLAY" | sed -n "s/.*LISTENER(\\([^)]*\\)).*/\\1/p")
    COUNT=0
    CSV=""
    for L in $NAMES; do
        COUNT=$((COUNT+1))
        if [ -z "$CSV" ]; then CSV="$L"; else CSV="${CSV},${L}"; fi
    done
    
    echo "${QM}|${COUNT}|${CSV}"
done
'

# Create temporary file for output
tmpfile="${ZABBIX_LOG_DIR}/mqm_listen_$$.tmp"

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
# Input format: QM|COUNT|CSV_LISTENERS
# --------------------------------------------------------------------------
if [[ ! -s "$tmpfile" ]]; then
    echo "[]"
    exit "$EXIT_SUCCESS"
fi

json_output=$(cat "$tmpfile" | jq -Rcn '[inputs | select(length > 0) | split("|") | {
    Q_MANAGER: .[0],
    Q_COUNT: (.[1] | tonumber),
    LISTENER: (.[2] // "")
}]') || json_output="[]"

dbg "JSON output: $json_output"

# Output to stdout for Zabbix agent
echo "$json_output"