# emkyu

IBM MQ Queue Manager monitoring scripts for Zabbix integration.

## Overview

This project provides shell scripts to monitor IBM MQ Queue Manager status and output results in JSON format suitable for Zabbix monitoring.

**Compatibility:** ksh93 (AIX native), bash 4+ (Linux)

## Project Structure

```
emkyu/
├── src/
│   ├── mqm_common.sh              # Shared functions library
│   ├── mqm_status_service.sh      # Queue manager status (creates cache)
│   ├── mqm_command_service.sh     # Command server status monitoring
│   └── mqm_listen_msg.sh          # Listener monitoring
├── test/
│   ├── run_all_tests.sh           # Test runner
│   ├── test_mqm_common.sh         # Tests for mqm_common.sh
│   ├── test_mqm_status_service.sh # Tests for mqm_status_service.sh
│   ├── test_mqm_command_service.sh# Tests for mqm_command_service.sh
│   └── test_mqm_listen_msg.sh     # Tests for mqm_listen_msg.sh
└── README.md
```

---

## ⚠️ CONFIGURATION REQUIRED BEFORE USE

> **IMPORTANT:** Review and update all paths marked with 🔧 below before deploying.

### 🔧 1. Main Script Paths (Environment Variables)

These can be overridden via environment variables **without editing scripts**:

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `ZABBIX_LOG_DIR` | `/opt/zabbix/logs` | Directory for cache and temp files |
| `QM_FILE` | `/opt/zabbix/logs/queue_manager_cache.json` | Queue manager cache file |
| `CACHE_FILE` | `/opt/zabbix/logs/queue_manager_cache.json` | Status cache output |
| `MQM_PATH` | `/opt/mqm/bin` | IBM MQ binary path (centralized) |

**Override at runtime:**
```bash
export ZABBIX_LOG_DIR="/your/custom/path"
export QM_FILE="/your/custom/path/cache.json"
export MQM_PATH="/your/custom/mqm/bin"  # If MQ installed elsewhere
./mqm_status_service.sh
```

### 🔧 2. MQ Binary Path Configuration (Centralized)

The MQ binary path is now **centralized** in a single location. All scripts (including embedded scripts that run as the `mqm` user) use the `MQM_PATH` environment variable defined in `mqm_common.sh`.

| File | Variable | Default Value | Description |
|------|----------|---------------|-------------|
| `mqm_common.sh` | `MQM_PATH` | `/opt/mqm/bin` | Single source of truth for MQ path |

**To change the MQ path:**

Option 1 - Environment variable (recommended):
```bash
export MQM_PATH="/custom/mqm/bin"
./mqm_status_service.sh
```

Option 2 - Edit `mqm_common.sh` once (line ~28):
```bash
: "${MQM_PATH:=/custom/mqm/bin}"
```

This single change propagates to all scripts and their embedded MQSC_SCRIPT blocks automatically.

### 🔧 3. Temp File Locations

Temp files are created in `ZABBIX_LOG_DIR`. The scripts create files like:
- `mqm_status_$$.tmp`
- `mqm_command_$$.tmp`
- `mqm_listen_$$.tmp`

Ensure the Zabbix user can write to this directory.

### 🔧 4. Sudoers Configuration (Required for Zabbix)

The scripts need to run MQ commands as the `mqm` user. Create sudoers entry:

```bash
# Create file: /etc/sudoers.d/zabbix-mqm
# Use visudo: visudo -f /etc/sudoers.d/zabbix-mqm

# Add these lines:
Defaults:zabbix !requiretty
zabbix ALL=(mqm) NOPASSWD: /bin/sh, /bin/bash, /bin/ksh
```

```bash
# Set permissions
chmod 440 /etc/sudoers.d/zabbix-mqm
```

**On AIX:** Add directly to `/etc/sudoers` using `visudo`.

### 🔧 5. Directory Setup

```bash
# Create required directories
sudo mkdir -p /opt/zabbix/logs
sudo chown zabbix:zabbix /opt/zabbix/logs
sudo chmod 755 /opt/zabbix/logs
```

---

## Quick Start Checklist

- [ ] Install `jq` on target system
- [ ] Verify MQ path: `ls /opt/mqm/bin/dspmq` (or set `MQM_PATH` environment variable)
- [ ] Create `/opt/zabbix/logs` directory with zabbix ownership
- [ ] Configure sudoers for zabbix → mqm
- [ ] Test: `sudo -u zabbix sudo -n -u mqm /bin/sh -c 'echo works'`
- [ ] Run `mqm_status_service.sh` first to create cache
- [ ] Configure Zabbix UserParameters

---

## Scripts

### mqm_status_service.sh

**Purpose:** Queries all queue managers and outputs their status. This script **creates the cache file** used by other scripts.

**Run this script first** (via cron or Zabbix scheduled task) to populate the cache.

| Output Field | Value | Meaning |
|--------------|-------|---------|
| `Q_STATUS` | `0` | Not running (stopped/ended) |
| `Q_STATUS` | `1` | Running (active) |
| `Q_STATUS` | `2` | Running as standby |

**Output example:**
```json
[{"Q_MANAGER":"QM1","Q_STATUS":1},{"Q_MANAGER":"QM2","Q_STATUS":0}]
```

### mqm_command_service.sh

**Purpose:** Queries command server status via `dspmqcsv` for each active queue manager.

| Output Field | Value | Meaning |
|--------------|-------|---------|
| `Q_STATUS` | `"0"` | Command server not running |
| `Q_STATUS` | `"1"` | Command server running |

**Output example:**
```json
[{"Q_MANAGER":"QM1","Q_STATUS":"1"},{"Q_MANAGER":"QM2","Q_STATUS":"0"}]
```

### mqm_listen_msg.sh

**Purpose:** Monitors MQ listener status for each active queue manager.

**Output example:**
```json
[{"Q_MANAGER":"QM1","Q_COUNT":2,"LISTENER":"LISTENER1,LISTENER2"}]
```

### mqm_common.sh

Shared library providing common functions:

| Function | Description |
|----------|-------------|
| `get_active_queue_managers` | Returns space-separated list of active QMs |
| `check_jq_installed` | Validates jq is available |
| `check_qm_file_exists` | Validates cache file exists |
| `mqm_error_json` | Outputs error messages in JSON format |

**Usage:**
```bash
# Source in your script
. /path/to/mqm_common.sh

# Override defaults before sourcing
export QM_FILE="/custom/path/cache.json"
. /path/to/mqm_common.sh
```

---

## Requirements

| Requirement | Details | Installation |
|-------------|---------|--------------|
| **jq** | JSON processor | `apt install jq` / `yum install jq` / AIX: download from jq website |
| **IBM MQ** | MQ client or server | Binaries in `/opt/mqm/bin` |
| **Shell** | ksh93 or bash 4+ | AIX: native ksh93, Linux: bash |
| **User** | mqm user access | See permissions section above |

---

## Zabbix Integration

### UserParameter Configuration

Add to `/etc/zabbix/zabbix_agentd.d/mq.conf`:

```ini
# Queue Manager Status (run every 1-5 minutes to update cache)
UserParameter=mq.qm.status,/path/to/src/mqm_status_service.sh

# Command Server Status
UserParameter=mq.command.status,/path/to/src/mqm_command_service.sh

# Listener Status
UserParameter=mq.listener.status,/path/to/src/mqm_listen_msg.sh
```

### Recommended Polling Schedule

| Script | Interval | Notes |
|--------|----------|-------|
| `mqm_status_service.sh` | 1-5 min | Creates cache, run first |
| `mqm_command_service.sh` | 1-5 min | Depends on cache |
| `mqm_listen_msg.sh` | 1-5 min | Depends on cache |

### Timeout Configuration

```ini
# /etc/zabbix/zabbix_agentd.conf
Timeout=10                    # Agent timeout (> DSPMQ_TIMEOUT)
```

---

## Testing

Run the test suite:

```bash
# Run all tests
bash test/run_all_tests.sh

# Run individual test suites
bash test/test_mqm_common.sh
bash test/test_mqm_status_service.sh
bash test/test_mqm_command_service.sh
bash test/test_mqm_listen_msg.sh
```

**Test coverage:** 99 tests covering:
- Script structure and compatibility
- Error handling and JSON formatting
- Queue manager retrieval and parsing
- jq-based JSON building
- Cache file operations
- AIX/Linux shell compatibility

---

## Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| `jq command not found` | jq missing | Install jq package |
| `dspmq command not found` | MQ not in PATH | Update PATH in script AND embedded MQSC_SCRIPT |
| `Cannot write to /opt/zabbix/logs` | Permission denied | `chown zabbix:zabbix /opt/zabbix/logs` |
| `Cache file does not exist` | `mqm_status_service.sh` not run | Run status script first |
| `Cannot run as mqm non-interactively` | Sudo not configured | Configure sudoers (see above) |
| Empty JSON output `[]` | No running queue managers | Check `dspmq -x` output |

### Debug Mode

Enable debug output:
```bash
DEBUG=1 ./mqm_status_service.sh
DEBUG=1 ./mqm_command_service.sh
DEBUG=1 ./mqm_listen_msg.sh
```

### Manual Testing

```bash
# Test dspmq directly
/opt/mqm/bin/dspmq -x

# Test as mqm user
sudo -u mqm /opt/mqm/bin/dspmq -x

# Test sudo from zabbix user
sudo -u zabbix sudo -n -u mqm /bin/sh -c 'echo works'

# Test script with debug
DEBUG=1 ./mqm_status_service.sh
```

### Verifying Embedded Script Paths

If you get "command not found" errors, the embedded script PATH may be wrong:

```bash
# Check what path is set in embedded script
grep -A2 "MQSC_SCRIPT=" src/mqm_command_service.sh | head -5

# Verify MQ binaries location on your system
which dspmq
which dspmqcsv
which runmqsc
```

---

## License

(C) COPYRIGHT Kyndryl Corp. 2022-2024. All Rights Reserved.