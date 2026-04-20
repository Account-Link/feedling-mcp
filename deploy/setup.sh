#!/usr/bin/env bash
# Feedling VPS setup script
# Run as ubuntu user on the EC2 instance
# Usage: bash deploy/setup.sh [--install-caddy]
#
# By default this script:
#   1. Creates a Python venv
#   2. Installs deps
#   3. Writes ~/feedling.env (multi-tenant mode — no shared API key)
#   4. Installs + starts feedling-backend and feedling-mcp systemd units
# Pass --install-caddy to also install Caddy and enable HTTPS.

set -e

REPO_DIR="$HOME/feedling-mcp"
VENV_DIR="$HOME/feedling-venv"
DATA_DIR="$HOME/feedling-data"
ENV_FILE="$HOME/feedling.env"
INSTALL_CADDY=0
for arg in "$@"; do
    case "$arg" in
        --install-caddy) INSTALL_CADDY=1 ;;
    esac
done

echo "=== 1. Create Python venv and install deps ==="
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
"$VENV_DIR/bin/pip" install -r "$REPO_DIR/backend/requirements.txt"

echo "=== 2. Create data dir ==="
mkdir -p "$DATA_DIR"

echo "=== 3. Ensure env file exists ==="
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<EOF
FEEDLING_DATA_DIR=$DATA_DIR
FEEDLING_FLASK_URL=http://127.0.0.1:5001
FEEDLING_MCP_PORT=5002
FEEDLING_MCP_TRANSPORT=sse
EOF
    chmod 600 "$ENV_FILE"
    echo "    wrote $ENV_FILE (multi-tenant — users register via iOS and receive per-user api_keys)"
else
    echo "    $ENV_FILE already exists — leaving alone"
fi

echo "=== 4. Install systemd services ==="
sudo cp "$REPO_DIR/deploy/feedling-backend.service" /etc/systemd/system/
sudo cp "$REPO_DIR/deploy/feedling-mcp.service"     /etc/systemd/system/
sudo systemctl daemon-reload

echo "=== 5. Enable and start backend + MCP ==="
sudo systemctl enable feedling-backend feedling-mcp
sudo systemctl restart feedling-backend feedling-mcp

if [ "$INSTALL_CADDY" = "1" ]; then
    echo "=== 6. Install Caddy (HTTPS reverse proxy) ==="
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt-get update
    sudo apt-get install -y caddy
    sudo cp "$REPO_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
    sudo systemctl enable --now caddy
    echo "    Caddy installed. Point DNS for api.<domain> and mcp.<domain>"
    echo "    at this VPS, then 'sudo systemctl reload caddy'."
fi

echo ""
echo "=== Done ==="
echo "Multi-tenant mode: users register via iOS (POST /v1/users/register) and"
echo "receive a per-user api_key. There is no shared server-side API key."
echo ""
echo "Check status:"
echo "  sudo systemctl status feedling-backend feedling-mcp"
echo "  curl -s http://127.0.0.1:5001/healthz"
