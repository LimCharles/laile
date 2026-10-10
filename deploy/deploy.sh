#!/bin/sh
# Deploys Laile to a Lighthouse instance from this Mac.
#   deploy/deploy.sh <instance-ip> [ssh-key]
# Copies the repo (no .git or build output), Server/.env as the server's environment, then builds
# and starts the containers. The site is https://<ip-with-dashes>.sslip.io unless LAILE_DOMAIN is set.
set -eu
IP="$1"
KEY="${2:-$HOME/.ssh/id_laile_lighthouse}"
USER_AT="${LAILE_SSH_USER:-ubuntu}@$IP"
DOMAIN="${LAILE_DOMAIN:-$(echo "$IP" | tr . -).sslip.io}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new"

echo "Copying to $USER_AT ..."
rsync -az --delete -e "$SSH" \
  --exclude .git --exclude '.build' --exclude 'DerivedData' --exclude 'Server/laile.sqlite*' \
  --exclude 'Server/voice-cache' --exclude 'submission' --exclude 'iOS' --exclude 'Packages/LaileKit' \
  "$ROOT/" "$USER_AT:laile/"
scp -i "$KEY" "$ROOT/Server/.env" "$USER_AT:laile/deploy/server.env"

echo "Building and starting on the instance (first build takes a while) ..."
$SSH "$USER_AT" "sh -s" <<REMOTE
set -eu
if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | sudo sh; fi
# Swift needs memory to build; add swap on small instances.
if [ "\$(swapon --show | wc -l)" -eq 0 ]; then
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
cd laile/deploy
echo "LAILE_DOMAIN=$DOMAIN" > .env
sudo docker compose up -d --build
sudo docker compose ps
REMOTE
echo "Done: https://$DOMAIN/portal"
