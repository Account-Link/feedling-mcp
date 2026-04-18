#!/usr/bin/env bash
# Feedling VPS setup script
# Run as ubuntu user on the EC2 instance
# Usage: bash deploy/setup.sh

set -e

REPO_DIR="$HOME/feedling-mcp-v1"
VENV_DIR="$HOME/feedling-venv"

echo "=== 1. Install Caddy ==="
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy

echo "=== 2. Install Caddy config ==="
sudo cp "$REPO_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl enable caddy
sudo systemctl restart caddy

echo "=== 3. Create Python venv and install deps ==="
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$REPO_DIR/backend/requirements.txt"

echo "=== 4. Install systemd services ==="
sudo cp "$REPO_DIR/deploy/feedling-backend.service"     /etc/systemd/system/
sudo cp "$REPO_DIR/deploy/feedling-mcp.service"         /etc/systemd/system/
sudo cp "$REPO_DIR/deploy/feedling-chat-bridge.service" /etc/systemd/system/
sudo systemctl daemon-reload

echo "=== 5. Enable and start backend + MCP ==="
sudo systemctl enable feedling-backend feedling-mcp
sudo systemctl start  feedling-backend feedling-mcp

echo ""
echo "=== Done ==="
echo "feedling-chat-bridge is installed but NOT enabled by default."
echo "Hermes users: sudo systemctl enable --now feedling-chat-bridge"
echo ""
echo "Check status:"
echo "  sudo systemctl status feedling-backend feedling-mcp"
echo "  curl https://mcp.feedling.app/  (after DNS is pointed to this server)"
