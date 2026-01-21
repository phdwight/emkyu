#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
#
# mqm_dead_letter_queue.sh - Monitor IBM MQ Dead Letter Queue Depths
#
# PURPOSE:
#   This script queries the dead letter queue depth for each active queue
#   manager and outputs the results in JSON format for Zabbix monitoring.
#
# WHAT IT DOES:
#   1. Reads active queue managers from the cache file
#   2. Runs 'runmqsc DISPLAY QMGR DEADQ' to get the DLQ name for each QM
#   3. Runs 'runmqsc DISPLAY QSTATUS(dlq) CURDEPTH' to get the current depth
#   4. Outputs JSON array with DLQ depth information
#
# OUTPUT FORMAT:
#   [{"Q_MANAGER":"QM1","Q_STATUS":0,"Q_DLNAME":"SYSTEM.DEAD.LETTER.QUEUE"}]
#
# ENVIRONMENT VARIABLES:
#   DEBUG=1 - Enable debug output
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
EXIT_SUCCESS=0
EXIT_NO_SUDO=3

# Debug output function (use echo for bash compatibility)
dbg() {
    if [[ -n "${DEBUG:-}" ]]; then
        echo "[DEBUG] $*" >&2
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
# Create embedded script file (run as mqm user) - outputs tab-separated DLQ data
# Using a temp file avoids complex quoting issues with heredocs and special chars
# --------------------------------------------------------------------------
tmpscript="/tmp/mqm_dead_letter_queue_$$.sh"
tmpoutput="/tmp/mqm_dead_letter_queue_$$.out"

# Ensure cleanup on exit
trap 'rm -f "$tmpscript" "$tmpoutput"' EXIT

cat > "$tmpscript" << 'MQSC_EOF'
#!/bin/sh
LC_ALL=C
export LC_ALL

# Read args
DEBUG="${1:-}"
MQM_PATH="${2:-/opt/mqm/bin}"

PATH="$MQM_PATH:$PATH"
export PATH

# Optional debug
dbg() { [ -n "$DEBUG" ] && echo "[DEBUG-inner] $*" >&2; }

# Build tab-separated rows: QM DEPTH DLNAME
ROWS=""

while read -r QM; do
    [ -z "$QM" ] && continue
    dbg "Processing QM: $QM"

    # Get dead-letter queue name for this QM
    DEAD_QUEUE=$(echo 'DISPLAY QMGR DEADQ' \
        | runmqsc "$QM" 2>/dev/null \
        | sed -n 's/.*DEADQ(\([^)]*\)).*/\1/p' \
        | tr -d '[:space:]' \
        | head -n1)

    if [ -z "$DEAD_QUEUE" ]; then
        # No DLQ configured: depth -1 and empty name
        dbg "No DEADQ set for $QM"
        ROWS="${ROWS}${QM}	-1	
"
        continue
    fi

    dbg "DLQ for $QM: $DEAD_QUEUE"

    # Get current depth of the dead letter queue
    CURDEPTH=$(echo "DISPLAY QSTATUS($DEAD_QUEUE) CURDEPTH" \
        | runmqsc "$QM" 2>/dev/null \
        | sed -n 's/.*CURDEPTH(\([0-9]*\)).*/\1/p' \
        | head -n1)

    if [ -z "$CURDEPTH" ]; then
        dbg "Could not retrieve CURDEPTH for $QM/$DEAD_QUEUE; setting -1"
        CURDEPTH=-1
    fi

    dbg "CURDEPTH for $QM/$DEAD_QUEUE: $CURDEPTH"
    ROWS="${ROWS}${QM}	${CURDEPTH}	${DEAD_QUEUE}
"
done

# Output rows (will be converted to JSON by main script)
printf "%s" "$ROWS"
MQSC_EOF

# Make script readable and executable by mqm user
chmod 755 "$tmpscript"

# --------------------------------------------------------------------------
# Execute embedded script as mqm user
# --------------------------------------------------------------------------
if [[ "$(id -un 2>/dev/null)" = "mqm" ]]; then
    dbg "Running as mqm user directly"
    echo "$Q_MANAGERS_NL" | /bin/sh "$tmpscript" "${DEBUG:-}" "$MQM_PATH" > "$tmpoutput"
elif command -v sudo >/dev/null 2>&1 && sudo -n -u mqm /bin/sh -c 'true' 2>/dev/null; then
    dbg "Running via sudo as mqm"
    echo "$Q_MANAGERS_NL" | sudo -n -u mqm /bin/sh "$tmpscript" "${DEBUG:-}" "$MQM_PATH" > "$tmpoutput"
else
    mqm_error_json "Cannot run as mqm non-interactively (configure sudoers)."
    exit "$EXIT_NO_SUDO"
fi

dbg "Output file: $tmpoutput"
dbg "Output file size: $(wc -c < "$tmpoutput" 2>/dev/null || echo 0) bytes"
if [[ -n "${DEBUG:-}" ]] && [[ -s "$tmpoutput" ]]; then
    dbg "Output file contents:"
    cat "$tmpoutput" >&2
fi

# --------------------------------------------------------------------------
# Convert rows to JSON array using jq
# Input format: QM<TAB>DEPTH<TAB>DLNAME
# --------------------------------------------------------------------------
if [[ ! -s "$tmpoutput" ]] || [[ -z "$(tr -d '[:space:]' < "$tmpoutput")" ]]; then
    dbg "Output file is empty or contains only whitespace"
    echo "[]"
else
    jq -c -R -n '
        [ inputs
          | select(length>0)
          | capture("^(?<q_manager>\\S+)\\t(?<depth>-?\\d+)\\t(?<dlname>[^\\t]*)")
          | { Q_MANAGER: .q_manager
            , Q_STATUS: (.depth|tonumber)
            , Q_DLNAME: .dlname }
        ]' < "$tmpoutput" || echo "[]"
fi