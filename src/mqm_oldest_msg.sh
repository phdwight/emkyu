#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
#
# mqm_oldest_msg.sh - Monitor IBM MQ Oldest Message Age
#
# PURPOSE:
#   This script queries the oldest message age (MSGAGE) for all queues across
#   active queue managers and outputs the results in JSON format for Zabbix.
#
# WHAT IT DOES:
#   1. Reads active queue managers from the cache file
#   2. Runs 'runmqsc DISPLAY QSTATUS(*) ALL' for each queue manager as mqm user
#   3. Extracts MSGAGE (message age in seconds) for each queue
#   4. Filters out SYSTEM.* queues and dead-letter queues (unless INCLUDE_SYSTEM=1)
#   5. Outputs JSON array with message age information
#
# OUTPUT FORMAT:
#   [{"Q_MANAGER":"QM1","Q_NAME":"MY.QUEUE","Q_MSGAGE":120}]
#
# ENVIRONMENT VARIABLES:
#   DEBUG=1          - Enable debug output
#   INCLUDE_SYSTEM=1 - Include SYSTEM.* queues in output
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
# Create embedded script file (run as mqm user) - outputs tab-separated MSGAGE data
# Using a temp file avoids complex quoting issues with heredocs and special chars
# --------------------------------------------------------------------------
tmpscript="/tmp/mqm_oldest_msg_$$.sh"
tmpoutput="/tmp/mqm_oldest_msg_$$.out"

# Ensure cleanup on exit
trap 'rm -f "$tmpscript" "$tmpoutput"' EXIT

cat > "$tmpscript" << 'MQSC_EOF'
#!/bin/sh
LC_ALL=C
export LC_ALL

# Read args
DEBUG="${1:-}"
INCLUDE_SYSTEM="${2:-0}"
MQM_PATH="${3:-/opt/mqm/bin}"

PATH="$MQM_PATH:$PATH"
export PATH

# Optional debug
dbg() { [ -n "$DEBUG" ] && echo "[DEBUG-inner] $*" >&2; }

# Build tab-separated rows: QM QUEUE MSGAGE
ROWS=""

while read -r QM; do
    [ -z "$QM" ] && continue
    dbg "Processing QM: $QM"

    # Get dead-letter queue name once for this QM
    DEAD_QUEUE=$(echo 'DISPLAY QMGR DEADQ' \
        | runmqsc "$QM" 2>/dev/null \
        | sed -n 's/.*DEADQ(\([^)]*\)).*/\1/p' \
        | tr -d '[:space:]' \
        | head -n1)
    dbg "DLQ for $QM: ${DEAD_QUEUE:-<none>}"

    # Single MQSC call to fetch all local queue statuses with MSGAGE
    MQ_OUT=$(echo "DISPLAY QSTATUS(*) ALL" | runmqsc "$QM" 2>/dev/null)
    if [ -z "$MQ_OUT" ]; then dbg "No MQ_OUT for $QM (runmqsc missing or no output)"; fi
    
    # Count QUEUE() lines
    qcount=$(echo "$MQ_OUT" | grep -c 'QUEUE(' || true)
    if [ "$qcount" -eq 0 ]; then
        dbg "No QUEUE() lines for $QM with QSTATUS ALL; trying DISPLAY QSTATUS(*)"
        MQ_OUT=$(echo "DISPLAY QSTATUS(*)" | runmqsc "$QM" 2>/dev/null)
        qcount=$(echo "$MQ_OUT" | grep -c 'QUEUE(' || true)
    fi
    
    # Debug: show how many QUEUE() lines were returned
    if [ -n "$DEBUG" ]; then
        dbg "MQ_OUT queue lines for $QM: $qcount"
        if [ "$DEBUG" = "2" ]; then echo "$MQ_OUT" | sed -n '1,80p' >&2; fi
    fi

    # Parse and emit rows using awk
    include_system="${INCLUDE_SYSTEM:-0}"
    ROWS_QM=$(echo "$MQ_OUT" | awk -v qm="$QM" -v deadq="$DEAD_QUEUE" -v includeSystem="$include_system" '
        BEGIN { name=""; msg="" }
        /^[[:space:]]*QUEUE\(/ {
            # Emit previous (with defaulting) before starting new block
            if (name != "") {
                v = (msg ~ /^[0-9]+$/) ? msg : 0
                if (includeSystem == 1 || (name !~ /^SYSTEM\./ && (deadq == "" || name != deadq))) {
                    printf "%s\t%s\t%s\n", qm, name, v
                }
            }
            name=$0
            gsub(/.*QUEUE\(|\).*/, "", name)
            gsub(/[[:space:]]+/, "", name)
            msg=""
            next
        }
        /MSGAGE\(/ {
            val=$0; gsub(/.*MSGAGE\(|\).*/, "", val); gsub(/[[:space:]]+/, "", val)
            msg=val
        }
        END {
            if (name != "") {
                v = (msg ~ /^[0-9]+$/) ? msg : 0
                if (includeSystem == 1 || (name !~ /^SYSTEM\./ && (deadq == "" || name != deadq))) {
                    printf "%s\t%s\t%s\n", qm, name, v
                }
            }
        }
    ')

    if [ -n "$ROWS_QM" ]; then
        ROWS="${ROWS}${ROWS_QM}
"
        dbg "Rows collected for $QM: $(echo "$ROWS_QM" | wc -l)"
    fi
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
    echo "$Q_MANAGERS_NL" | /bin/sh "$tmpscript" "${DEBUG:-}" "${INCLUDE_SYSTEM:-0}" "$MQM_PATH" > "$tmpoutput"
elif command -v sudo >/dev/null 2>&1 && sudo -n -u mqm /bin/sh -c 'true' 2>/dev/null; then
    dbg "Running via sudo as mqm"
    echo "$Q_MANAGERS_NL" | sudo -n -u mqm /bin/sh "$tmpscript" "${DEBUG:-}" "${INCLUDE_SYSTEM:-0}" "$MQM_PATH" > "$tmpoutput"
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
# Input format: QM<TAB>QUEUE<TAB>MSGAGE
# --------------------------------------------------------------------------
if [[ ! -s "$tmpoutput" ]] || [[ -z "$(tr -d '[:space:]' < "$tmpoutput")" ]]; then
    dbg "Output file is empty or contains only whitespace"
    echo "[]"
else
    jq -c -R -n '
        [ inputs
          | select(length>0)
          | capture("^(?<q_manager>\\S+)\\t(?<q_name>\\S+)\\t(?<age>\\d+)")
          | { Q_MANAGER: .q_manager
            , Q_NAME: .q_name
            , Q_MSGAGE: (.age|tonumber) }
        ]' < "$tmpoutput" || echo "[]"
fi