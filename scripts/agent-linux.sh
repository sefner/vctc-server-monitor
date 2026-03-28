#!/usr/bin/env bash
# VCTC Linux Monitoring Agent
# Config file: /etc/vctc-agent/config.sh
# Install to: /usr/local/bin/vctc-agent.sh
# Cron entry: */30 * * * * root /usr/local/bin/vctc-agent.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CONFIG_FILE="/etc/vctc-agent/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ -z "${API_URL:-}" ]]; then
    echo "ERROR: API_URL is not set in $CONFIG_FILE" >&2
    exit 1
fi

if [[ -z "${API_KEY:-}" ]]; then
    echo "ERROR: API_KEY is not set in $CONFIG_FILE" >&2
    exit 1
fi

export API_URL API_KEY

# Optional: array of systemd service names to monitor
# SERVICES_TO_MONITOR=()
SERVICES_TO_MONITOR=("${SERVICES_TO_MONITOR[@]+"${SERVICES_TO_MONITOR[@]}"}")

# ---------------------------------------------------------------------------
# Temp file cleanup
# ---------------------------------------------------------------------------
JOURNAL_TMPFILE=""
cleanup() {
    if [[ -n "$JOURNAL_TMPFILE" && -f "$JOURNAL_TMPFILE" ]]; then
        rm -f "$JOURNAL_TMPFILE"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# OS Info
# ---------------------------------------------------------------------------
echo "Collecting OS info..."
OS_INFO=""
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_INFO="${PRETTY_NAME:-Linux}"
    KERNEL=$(uname -r)
    OS_INFO="${OS_INFO} (kernel ${KERNEL})"
else
    OS_INFO="Linux $(uname -r)"
fi
export OS_INFO

# ---------------------------------------------------------------------------
# Uptime
# ---------------------------------------------------------------------------
echo "Collecting uptime..."
UPTIME_SECONDS=""
if [[ -f /proc/uptime ]]; then
    UPTIME_SECONDS=$(awk '{printf "%d", $1}' /proc/uptime)
fi
export UPTIME_SECONDS

# ---------------------------------------------------------------------------
# CPU Usage (1-second sample from /proc/stat)
# ---------------------------------------------------------------------------
echo "Collecting CPU usage..."
CPU_USAGE=""
read_cpu_stat() {
    awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8}' /proc/stat
}

CPU_STAT1=$(read_cpu_stat)
sleep 1
CPU_STAT2=$(read_cpu_stat)

# Use bash arithmetic for CPU delta calculation
cpu1=($CPU_STAT1)
cpu2=($CPU_STAT2)

idle1=${cpu1[3]}
idle2=${cpu2[3]}

total1=0
for v in "${cpu1[@]}"; do total1=$((total1 + v)); done

total2=0
for v in "${cpu2[@]}"; do total2=$((total2 + v)); done

total_diff=$((total2 - total1))
idle_diff=$((idle2 - idle1))

if [[ $total_diff -gt 0 ]]; then
    CPU_USAGE=$(awk "BEGIN {printf \"%.2f\", (1 - $idle_diff / $total_diff) * 100}")
else
    CPU_USAGE="0.00"
fi
export CPU_USAGE

# ---------------------------------------------------------------------------
# RAM Usage from /proc/meminfo
# ---------------------------------------------------------------------------
echo "Collecting RAM usage..."
RAM_USAGE_PCT=""
MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
MEM_AVAILABLE=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

if [[ -n "$MEM_TOTAL" && "$MEM_TOTAL" -gt 0 ]]; then
    RAM_USAGE_PCT=$(awk "BEGIN {printf \"%.2f\", (1 - $MEM_AVAILABLE / $MEM_TOTAL) * 100}")
fi
export RAM_USAGE_PCT

# ---------------------------------------------------------------------------
# Disk Usage from df
# ---------------------------------------------------------------------------
echo "Collecting disk usage..."
# df -B1: sizes in bytes; skip pseudo/virtual filesystems
SKIP_FSTYPES="tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|udev|cgroup|cgroup2|pstore|efivarfs|bpf|tracefs|debugfs|securityfs|hugetlbfs|mqueue|fusectl|configfs|ramfs"

DISK_DATA=$(df -B1 --output=source,fstype,size,avail,target 2>/dev/null | tail -n +2 || true)

DISK_LINES=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r source fstype size avail target <<< "$line"
    # Skip virtual/pseudo filesystems
    if echo "$fstype" | grep -qE "^(${SKIP_FSTYPES})$"; then
        continue
    fi
    # Only real mountpoints starting with /
    if [[ "$target" != /* ]]; then
        continue
    fi
    # Skip sources that don't look like real devices (no letter/digit start)
    # Allow /dev/... and device mapper paths
    DISK_LINES+=("${source}|||${fstype}|||${size}|||${avail}|||${target}")
done <<< "$DISK_DATA"

# Export as newline-separated string for Python
DISK_RAW=""
for entry in "${DISK_LINES[@]+"${DISK_LINES[@]}"}"; do
    DISK_RAW="${DISK_RAW}${entry}"$'\n'
done
export DISK_RAW

# ---------------------------------------------------------------------------
# Pending Updates
# ---------------------------------------------------------------------------
echo "Collecting pending updates..."
PENDING_UPDATES=""
APT_LISTS_DIR="/var/lib/apt/lists"
APT_CACHE_AGE_SECONDS=3600  # 1 hour

# Check age of apt cache
APT_CACHE_STALE=true
if [[ -d "$APT_LISTS_DIR" ]]; then
    # Find the most recently modified file in apt lists
    NEWEST_FILE=$(find "$APT_LISTS_DIR" -maxdepth 1 -name '*_Packages' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || true)
    if [[ -n "$NEWEST_FILE" ]]; then
        NOW_EPOCH=$(date +%s)
        FILE_EPOCH=$(printf "%.0f" "$NEWEST_FILE")
        AGE=$((NOW_EPOCH - FILE_EPOCH))
        if [[ $AGE -lt $APT_CACHE_AGE_SECONDS ]]; then
            APT_CACHE_STALE=false
        fi
    fi
fi

if $APT_CACHE_STALE; then
    echo "APT cache is stale or missing, running apt-get update..."
    apt-get update -qq 2>/dev/null || echo "WARNING: apt-get update failed, proceeding with stale cache" >&2
fi

# Count upgradable packages
PENDING_UPDATES=$(apt-get --just-print upgrade 2>/dev/null \
    | grep -c '^Inst ' || true)
export PENDING_UPDATES

# ---------------------------------------------------------------------------
# Last Update Installed (from /var/log/dpkg.log)
# ---------------------------------------------------------------------------
echo "Collecting last update timestamp..."
LAST_UPDATE_INSTALLED=""
DPKG_LOG="/var/log/dpkg.log"
if [[ -f "$DPKG_LOG" ]]; then
    # Find the last "upgrade" or "install" action line
    LAST_LINE=$(grep -E ' (upgrade|install) ' "$DPKG_LOG" | tail -1 || true)
    if [[ -n "$LAST_LINE" ]]; then
        # Format: "2024-01-15 10:23:45 upgrade package:arch old new"
        LAST_UPDATE_INSTALLED=$(echo "$LAST_LINE" | awk '{print $1, $2}')
    fi
fi
export LAST_UPDATE_INSTALLED

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
echo "Collecting service statuses..."
SERVICE_ENTRIES=()
for svc in "${SERVICES_TO_MONITOR[@]+"${SERVICES_TO_MONITOR[@]}"}"; do
    [[ -z "$svc" ]] && continue
    # Get systemd active state
    ACTIVE_STATE=$(systemctl is-active "$svc" 2>/dev/null || true)
    DISPLAY_NAME=$(systemctl show -p Description --value "$svc" 2>/dev/null || echo "$svc")

    case "$ACTIVE_STATE" in
        active)   STATUS="Running" ;;
        failed)   STATUS="Failed" ;;
        *)        STATUS="Stopped" ;;
    esac

    # Escape for safe export: use a delimiter unlikely to appear in names
    SERVICE_ENTRIES+=("${svc}|||${DISPLAY_NAME}|||${STATUS}")
done

SERVICES_RAW=""
for entry in "${SERVICE_ENTRIES[@]+"${SERVICE_ENTRIES[@]}"}"; do
    SERVICES_RAW="${SERVICES_RAW}${entry}"$'\n'
done
export SERVICES_RAW

# ---------------------------------------------------------------------------
# Journal Errors (last 24h, priority err and above)
# ---------------------------------------------------------------------------
echo "Collecting journal errors..."
JOURNAL_TMPFILE=$(mktemp /tmp/vctc-journal-XXXXXX.json)

# Export journal entries as JSON lines; handle case where journalctl unavailable
if command -v journalctl >/dev/null 2>&1; then
    journalctl \
        --since "24 hours ago" \
        --priority=err \
        --output=json \
        --no-pager \
        2>/dev/null > "$JOURNAL_TMPFILE" || true
fi
export JOURNAL_TMPFILE

# ---------------------------------------------------------------------------
# Python3: assemble JSON payload and POST to API
# ---------------------------------------------------------------------------
echo "Sending checkin to $API_URL..."

python3 << 'PYEOF'
import os
import sys
import json
import math
import urllib.request
import urllib.error
from collections import defaultdict
from datetime import datetime, timezone

def safe_float(val, default=None):
    try:
        f = float(val) if val else None
        if f is None or not math.isfinite(f):
            return default
        return f
    except (ValueError, TypeError):
        return default

def safe_int(val, default=None):
    try:
        return int(val) if val else default
    except (ValueError, TypeError):
        return default

# --- OS Info ---
os_info = os.environ.get('OS_INFO') or None

# --- Uptime ---
uptime_seconds = safe_int(os.environ.get('UPTIME_SECONDS'))

# --- CPU ---
cpu_usage = safe_float(os.environ.get('CPU_USAGE'))
if cpu_usage is not None:
    cpu_usage = round(cpu_usage, 2)

# --- RAM ---
ram_usage_pct = safe_float(os.environ.get('RAM_USAGE_PCT'))
if ram_usage_pct is not None:
    ram_usage_pct = round(ram_usage_pct, 2)

# --- Disks ---
disks = []
disk_raw = os.environ.get('DISK_RAW', '')
for line in disk_raw.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split('|||')
    if len(parts) != 5:
        continue
    source, fstype, size_bytes, avail_bytes, target = parts
    try:
        size_b = int(size_bytes)
        avail_b = int(avail_bytes)
    except ValueError:
        continue
    if size_b <= 0:
        continue
    total_gb = round(size_b / (1024 ** 3), 3)
    free_gb = round(avail_b / (1024 ** 3), 3)
    used_pct = round((1 - avail_b / size_b) * 100, 2)
    disks.append({
        'drive': target,
        'total_gb': total_gb,
        'free_gb': free_gb,
        'used_pct': used_pct,
    })

# --- Pending Updates ---
pending_updates = safe_int(os.environ.get('PENDING_UPDATES'))

# --- Last Update Installed ---
last_update_installed = os.environ.get('LAST_UPDATE_INSTALLED') or None
if last_update_installed:
    last_update_installed = last_update_installed.strip()[:80] or None

# --- Services ---
services = []
services_raw = os.environ.get('SERVICES_RAW', '')
for line in services_raw.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split('|||')
    if len(parts) != 3:
        continue
    name, display_name, status = parts
    if status not in ('Running', 'Stopped', 'Failed'):
        status = 'Stopped'
    services.append({
        'name': name[:120],
        'display_name': display_name[:200],
        'status': status,
    })
if not services:
    services = None

# --- Journal Errors ---
event_log_errors = []
journal_tmpfile = os.environ.get('JOURNAL_TMPFILE', '')
if journal_tmpfile and os.path.isfile(journal_tmpfile):
    # Deduplicate by (SYSLOG_IDENTIFIER, MESSAGE)
    # key -> {time, source, message, count, id, level}
    seen = {}
    try:
        with open(journal_tmpfile, 'r', errors='replace') as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    entry = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue

                source = (entry.get('SYSLOG_IDENTIFIER') or
                          entry.get('_COMM') or
                          entry.get('_EXE') or
                          'unknown')
                message = (entry.get('MESSAGE') or '')
                if isinstance(message, list):
                    # journald sometimes stores as byte array
                    try:
                        message = bytes(message).decode('utf-8', errors='replace')
                    except Exception:
                        message = str(message)

                # Truncate for dedup key (use full for storage)
                dedup_key = (str(source)[:160], str(message)[:200])

                priority = str(entry.get('PRIORITY', '3'))
                level = 'Error'
                if priority in ('0', '1', '2'):
                    level = 'Critical'

                # Timestamp: __REALTIME_TIMESTAMP is microseconds since epoch
                ts_us = entry.get('__REALTIME_TIMESTAMP')
                time_str = ''
                if ts_us:
                    try:
                        ts_sec = int(ts_us) / 1_000_000
                        dt = datetime.fromtimestamp(ts_sec, tz=timezone.utc)
                        time_str = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
                    except Exception:
                        time_str = str(ts_us)[:80]

                msg_id = 0
                try:
                    msg_id = int(entry.get('MESSAGE_ID') or entry.get('SYSLOG_MSGID') or 0)
                except (ValueError, TypeError):
                    msg_id = 0

                if dedup_key in seen:
                    seen[dedup_key]['count'] += 1
                    # Keep the latest timestamp
                    if time_str > seen[dedup_key]['time']:
                        seen[dedup_key]['time'] = time_str
                else:
                    seen[dedup_key] = {
                        'time': time_str[:80],
                        'log': 'journal',
                        'source': str(source)[:160],
                        'id': msg_id,
                        'level': level,
                        'message': str(message)[:1000],
                        'count': 1,
                    }

        event_log_errors = list(seen.values())
        # Sort by time descending, limit to 100 entries
        event_log_errors.sort(key=lambda x: x['time'], reverse=True)
        event_log_errors = event_log_errors[:100]
    except Exception as e:
        print(f'WARNING: Failed to parse journal data: {e}', file=sys.stderr)

# --- Build payload ---
payload = {
    'os_info': os_info,
    'disks': disks if disks else None,
    'pending_updates': pending_updates,
    'last_update_installed': last_update_installed,
    'services': services,
    'uptime_seconds': uptime_seconds,
    'cpu_usage': cpu_usage,
    'ram_usage_pct': ram_usage_pct,
    'event_log_errors': event_log_errors if event_log_errors else [],
    'restic_snapshots': [],
    'restic_backup_history': [],
    'domain_services': None,
    'scheduled_tasks': [],
}

checkin_url = os.environ.get('API_URL', '')
api_key = os.environ.get('API_KEY', '')

payload_bytes = json.dumps(payload).encode('utf-8')

req = urllib.request.Request(
    checkin_url,
    data=payload_bytes,
    headers={
        'Content-Type': 'application/json',
        'x-api-key': api_key,
    },
    method='POST',
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        status_code = resp.getcode()
        body = resp.read().decode('utf-8', errors='replace')
        print(f'SUCCESS: Check-in complete (HTTP {status_code})')
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', errors='replace')
    print(f'ERROR: HTTP {e.code} from server: {body[:500]}', file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as e:
    print(f'ERROR: Failed to reach {checkin_url}: {e.reason}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'ERROR: Unexpected error during HTTP POST: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
