#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
#
# mqm_status_service.sh - Monitor IBM MQ Queue Manager Status
#
# PURPOSE:
#   This script queries all queue managers on the system and outputs their
#   current status in JSON format. The output is used by Zabbix for monitoring
#   and is also cached for use by other MQ monitoring scripts.
#
# WHAT IT DOES:
#   1. Runs the 'dspmq -x' command to get all queue managers and their status
#   2. Parses the output to extract queue manager names and running state
#   3. Converts status to numeric values:
#      - 0 = Not running (stopped, ended, etc.)
#      - 1 = Running (active and processing messages)
#      - 2 = Running as standby (backup server, ready to take over)
#   4. Outputs JSON array to stdout AND saves to cache file
#
# OUTPUT FORMAT:
#   [{"Q_MANAGER":"QM1","Q_STATUS":1},{"Q_MANAGER":"QM2","Q_STATUS":0}]
#
# CACHE FILE:
#   /opt/zabbix/logs/queue_manager_cache.json (used by other MQ scripts)
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

# Source common functions (but override set -e behavior)
. "$SCRIPT_DIR/mqm_common.sh"

# Configuration - can be overridden via environment variables
: "${ZABBIX_LOG_DIR:=/opt/zabbix/logs}"
: "${CACHE_FILE:=$ZABBIX_LOG_DIR/queue_manager_cache.json}"

# Note: PATH is set by mqm_common.sh using MQM_PATH variable

# Debug output function
dbg() {
    if [[ -n "${DEBUG:-}" ]]; then
        print "[DEBUG] $*" >&2
    fi
}

# Ensure dspmq is available
if ! command -v dspmq >/dev/null 2>&1; then
    mqm_error_json "dspmq command not found. Please ensure IBM MQ is installed and in PATH."
    exit 1
fi

# Check write permission to output directory
if [[ ! -d "$ZABBIX_LOG_DIR" ]]; then
    mqm_error_json "Directory '$ZABBIX_LOG_DIR' does not exist."
    exit 2
fi
if [[ ! -w "$ZABBIX_LOG_DIR" ]]; then
    mqm_error_json "Cannot write to '$ZABBIX_LOG_DIR'. Check directory permissions."
    exit 2
fi

# Check jq is available
if ! command -v jq >/dev/null 2>&1; then
    mqm_error_json "jq command not found. Please install jq."
    exit 1
fi

# Build JSON output using jq (single pipeline, proper escaping)
# dspmq -x output format: QMNAME(QM1)                                             STATUS(Running)
json_output=$(dspmq -x 2>/dev/null | grep '^QMNAME' | \
    sed 's/QMNAME(\([^)]*\)).*STATUS(\([^)]*\)).*/\1|\2/' | \
    jq -Rcn '[inputs | select(length > 0) | split("|") | {
        Q_MANAGER: .[0],
        Q_STATUS: (if .[1] == "Running" then 1 
                   elif .[1] == "Running as standby" then 2 
                   else 0 end)
    }]') || json_output="[]"

dbg "JSON output: $json_output"

# Save JSON output using atomic write (temp file + rename)
temp_cache="${CACHE_FILE}.tmp.$$"
if echo "$json_output" > "$temp_cache" 2>/dev/null; then
    mv -f "$temp_cache" "$CACHE_FILE" 2>/dev/null || {
        rm -f "$temp_cache"
        mqm_error_json "Failed to write cache file" >&2
    }
else
    rm -f "$temp_cache" 2>/dev/null
    mqm_error_json "Failed to write temporary file" >&2
fi

# Output to stdout for Zabbix agent
echo "$json_output"