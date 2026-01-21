#!/usr/bin/ksh93
#############################################################################
# (C) COPYRIGHT Kyndryl Corp. 2022-2024
# All Rights Reserved
# Licensed Material - Property of Kyndryl
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with Kyndryl Corp.
# Version 1.2
# 
# Common functions for MQM monitoring scripts
# Compatible with: ksh93 (AIX native), bash 4+
#
# Usage: source this file in your script
#   . /path/to/mqm_common.sh
#
# Functions:
#   get_active_queue_managers - Returns space-separated list of active QMs
#   check_jq_installed        - Validates jq is available
#   check_qm_file_exists      - Validates cache file exists
#   mqm_error_json            - Outputs error in JSON format
#############################################################################

# Prevent multiple sourcing
[[ -n "${_MQM_COMMON_LOADED:-}" ]] && return 0
_MQM_COMMON_LOADED=1

# Configuration - can be overridden before sourcing
: "${MQM_PATH:=/opt/mqm/bin}"
export MQM_PATH
: "${QM_FILE:=/opt/zabbix/logs/queue_manager_cache.json}"

# Add MQM binaries to PATH if not already present
case ":$PATH:" in
    *":$MQM_PATH:"*) ;;
    *) PATH="$MQM_PATH:$PATH" ;;
esac

# Exit codes
MQM_EXIT_SUCCESS=0
MQM_EXIT_NO_JQ=1
MQM_EXIT_NO_FILE=2
MQM_EXIT_PARSE_ERROR=3

#############################################################################
# mqm_error_json - Format an error message as JSON
#
# PURPOSE:
#   When something goes wrong, this function takes a plain text error message
#   and wraps it in JSON format. This is important because Zabbix (our 
#   monitoring system) expects data in JSON format, even error messages.
#
# WHAT IT DOES:
#   - Takes any error message you give it
#   - Wraps it in JSON like: {"error": "your message here"}
#   - Prints the result so other tools can read it
#
# EXAMPLE:
#   Input:  mqm_error_json "File not found"
#   Output: {"error": "File not found"}
#
# ARGUMENTS:
#   $1 - The error message text (e.g., "Something went wrong")
#
# OUTPUTS:
#   Prints a JSON object to the screen (stdout)
#############################################################################
mqm_error_json() {
    typeset message="${1:-Unknown error}"
    # Escape double quotes for JSON safety
    typeset escaped_message="${message//\"/\\\"}"
    printf '{"error": "%s"}\n' "$escaped_message"
}

#############################################################################
# check_jq_installed - Verify that the 'jq' tool is available
#
# PURPOSE:
#   'jq' is a command-line tool that reads and manipulates JSON data.
#   Our scripts need jq to parse the queue manager cache file (which is 
#   stored in JSON format). This function checks if jq is installed on
#   the system before we try to use it.
#
# WHAT IT DOES:
#   - Looks for the 'jq' program on the system
#   - If found: Returns success (code 0)
#   - If NOT found: Prints a JSON error message and returns failure (code 1)
#
# WHY THIS MATTERS:
#   Without jq, we cannot read the queue manager data, so the script
#   would fail. This check gives a clear error message instead of a
#   confusing "command not found" error.
#
# RETURNS:
#   0 = jq is installed and ready to use
#   1 = jq is missing (error message already printed)
#
# NOTE: This function does NOT stop the script - the calling code
#       must decide what to do if jq is missing.
#############################################################################
check_jq_installed() {
    if ! command -v jq >/dev/null 2>&1; then
        mqm_error_json "jq is not installed. Please install it to run this script."
        return "$MQM_EXIT_NO_JQ"
    fi
    return "$MQM_EXIT_SUCCESS"
}

#############################################################################
# check_qm_file_exists - Verify the queue manager cache file is present
#
# PURPOSE:
#   IBM MQ can have multiple "queue managers" - think of them as separate
#   mailrooms that handle different message queues. We store a list of
#   these queue managers in a cache file (JSON format) to avoid querying
#   MQ directly every time (which would be slow).
#
#   This function checks if that cache file exists before we try to read it.
#
# WHAT IT DOES:
#   - Checks if the cache file exists at the expected location
#     (default: /opt/zabbix/logs/queue_manager_cache.json)
#   - If found: Returns success (code 0)
#   - If NOT found: Prints a JSON error message and returns failure (code 2)
#
# WHY THIS MATTERS:
#   The cache file is created by another process. If it's missing, either:
#   - The cache hasn't been created yet
#   - The file was deleted or moved
#   - The path is configured incorrectly
#
# RETURNS:
#   0 = File exists and is ready to read
#   2 = File is missing (error message already printed)
#
# NOTE: This function does NOT stop the script - the calling code
#       must decide what to do if the file is missing.
#############################################################################
check_qm_file_exists() {
    if [[ ! -f "$QM_FILE" ]]; then
        mqm_error_json "The file '$QM_FILE' does not exist."
        return "$MQM_EXIT_NO_FILE"
    fi
    return "$MQM_EXIT_SUCCESS"
}

#############################################################################
# get_active_queue_managers - Get a list of running queue managers
#
# PURPOSE:
#   IBM MQ uses "queue managers" to handle message queues. A server can
#   have multiple queue managers, but only some may be running at any time.
#   This function reads our cache file and returns only the queue managers
#   that are currently active (running).
#
# WHAT IT DOES:
#   1. Checks that 'jq' is installed (needed to read JSON)
#   2. Checks that the cache file exists
#   3. Reads the cache file and filters for active queue managers
#      (those with Q_STATUS=1, meaning "running")
#   4. Returns their names as a space-separated list
#
# EXAMPLE:
#   If the cache file contains:
#     [{"Q_MANAGER": "QM1", "Q_STATUS": 1},
#      {"Q_MANAGER": "QM2", "Q_STATUS": 0},
#      {"Q_MANAGER": "QM3", "Q_STATUS": 1}]
#
#   This function returns: "QM1 QM3"
#   (QM2 is skipped because Q_STATUS=0 means it's not running)
#
# OUTPUTS:
#   - On success: Prints space-separated queue manager names (e.g., "QM1 QM3")
#   - If no active managers: Prints "[]"
#   - On error: Prints JSON error message
#
# RETURNS:
#   0 = Success (list printed to stdout)
#   1 = jq not installed
#   2 = Cache file missing
#   3 = Failed to parse/read the cache file
#
# USAGE EXAMPLE:
#   Q_MANAGERS=$(get_active_queue_managers) || exit $?
#   # Now Q_MANAGERS contains something like "QM1 QM3"
#############################################################################
get_active_queue_managers() {
    # Validate prerequisites - return on error (don't exit)
    check_jq_installed || return $?
    check_qm_file_exists || return $?
    
    # Read queue managers from the JSON file
    typeset q_managers
    if ! q_managers=$(jq -r '.[] | select(.Q_STATUS==1) | .Q_MANAGER' "$QM_FILE" 2>/dev/null); then
        mqm_error_json "Failed to parse queue manager cache file"
        return "$MQM_EXIT_PARSE_ERROR"
    fi
    
    # Check if Q_MANAGERS is empty (no active queue managers)
    if [[ -z "$q_managers" ]]; then
        echo '[]'
        return "$MQM_EXIT_SUCCESS"
    fi
    
    # Convert newlines to spaces for space-separated output
    echo "$q_managers" | tr '\n' ' ' | sed 's/ $//'
    return "$MQM_EXIT_SUCCESS"
}