#!/usr/bin/env bash
set -euo pipefail

# add-linux-server.sh — Register a Linux server and install the VCTC monitoring agent
#
# Usage:
#   ./add-linux-server.sh <name> <hostname> <ssh-target> [description]
#
# Arguments:
#   <name>        Display name in the dashboard  (e.g. "DO-Droplet-01")
#   <hostname>    Short hostname for DB matching  (e.g. "do-droplet-01")
#   <ssh-target>  SSH connection string           (e.g. "root@1.2.3.4" or "ubuntu@droplet.example.com")
#   [description] Optional description
#
# Examples:
#   ./add-linux-server.sh "DO-Web-01" "do-web-01" "root@143.198.x.x"
#   ./add-linux-server.sh "DO-Web-01" "do-web-01" "root@143.198.x.x" "Main web droplet"

NAME="${1:?Usage: $0 <name> <hostname> <ssh-target> [description]}"
HOSTNAME_VAL="${2:?hostname required}"
SSH_TARGET="${3:?ssh-target required (e.g. root@1.2.3.4)}"
DESCRIPTION="${4:-Linux Server}"

GOVENTURA="sefner@goventura.info"
DB_PATH="/home/sefner/timesheet-app/it-monitor.db"
API_URL="https://goventura.info/api/it/checkin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/agent-linux.sh"

if [[ ! -f "$AGENT_SCRIPT" ]]; then
    echo "ERROR: agent-linux.sh not found at $AGENT_SCRIPT" >&2
    exit 1
fi

echo ""
echo "==> Registering '$NAME' ($HOSTNAME_VAL) in IT monitor..."

API_KEY=$(ssh "$GOVENTURA" python3 - << PYEOF
import sqlite3, secrets
db = sqlite3.connect('$DB_PATH')
key = secrets.token_hex(32)
try:
    db.execute(
        "INSERT INTO servers (name, hostname, description, api_key) VALUES (?,?,?,?)",
        ('$NAME', '$HOSTNAME_VAL', '$DESCRIPTION', key)
    )
    db.commit()
    print(key)
except Exception:
    # Already exists — return existing key
    row = db.execute("SELECT api_key FROM servers WHERE hostname=?", ('$HOSTNAME_VAL',)).fetchone()
    print(row[0] if row else 'ERROR: insert failed and server not found')
db.close()
PYEOF
)

if [[ "$API_KEY" == ERROR* ]]; then
    echo "ERROR: Failed to register server: $API_KEY" >&2
    exit 1
fi

echo "    Registered. API key: ${API_KEY:0:12}..."
echo ""

# Write config to a temp file locally (so we control the content exactly)
CONFIG_TMP=$(mktemp)
cat > "$CONFIG_TMP" << EOF
API_URL="$API_URL"
API_KEY="$API_KEY"
SERVICES_TO_MONITOR=()
EOF

echo "==> Copying agent to $SSH_TARGET..."
scp -q "$AGENT_SCRIPT" "$SSH_TARGET:/tmp/vctc-agent.sh"
scp -q "$CONFIG_TMP" "$SSH_TARGET:/tmp/vctc-agent-config.sh"
rm "$CONFIG_TMP"

echo "==> Installing and running first check-in..."
ssh "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -euo pipefail

# Install agent
chmod 755 /tmp/vctc-agent.sh
cp /tmp/vctc-agent.sh /usr/local/bin/vctc-agent.sh
rm /tmp/vctc-agent.sh

# Install config
mkdir -p /etc/vctc-agent
mv /tmp/vctc-agent-config.sh /etc/vctc-agent/config.sh
chmod 600 /etc/vctc-agent/config.sh

# Install cron
printf '*/30 * * * * root /usr/local/bin/vctc-agent.sh >> /var/log/vctc-agent.log 2>&1\n' \
    > /etc/cron.d/vctc-agent
chmod 644 /etc/cron.d/vctc-agent

echo "Running first check-in..."
/usr/local/bin/vctc-agent.sh
REMOTE

echo ""
echo "✓ Done! '$NAME' is now being monitored."
echo "  Dashboard: https://goventura.info/it"
echo ""
