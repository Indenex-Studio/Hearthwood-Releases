#!/bin/bash
# Sets up one Hearthwood CI runner on a fresh Ubuntu box. Run as root:
#   bash hetzner-runner.sh <registration-token> [runner-group]
# The token comes from Indenex-Studio > Settings > Actions > Runners > New runner.
# It is upper-cased here, so it can be typed in a console that drops Shift.
set -e
TOKEN=$(echo "$1" | tr a-z A-Z)
GROUP=${2:-hearthwood}
if [ -z "$TOKEN" ]; then echo "usage: bash hetzner-runner.sh <token> [group]"; exit 1; fi

apt-get update
apt-get install -y curl jq git zip unzip python3 libfontconfig1 libx11-6

# 4 GB swap for the client export jobs
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner

# Latest runner version from the releases page redirect (no API, so no rate limit)
V=$(curl -sLo /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest | sed 's#.*/tag/v##')
case "$V" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Could not find the runner version (got '$V'). Try again in a minute."; exit 1 ;;
esac
DIR=/home/runner/hearthwood
mkdir -p "$DIR"
cd "$DIR"
if [ ! -f config.sh ]; then
  curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v$V/actions-runner-linux-x64-$V.tar.gz"
  tar xzf runner.tgz
  rm runner.tgz
fi
./bin/installdependencies.sh
chown -R runner:runner "$DIR"

if [ -f .runner ]; then
  echo "Already registered; making sure the service runs."
else
  sudo -u runner ./config.sh --url https://github.com/Indenex-Studio --token "$TOKEN" \
    --runnergroup "$GROUP" --labels hetzner --name "$(hostname)-hearthwood" --unattended
fi
[ -f .service ] || ./svc.sh install runner
./svc.sh start
echo "Done: $(hostname)-hearthwood is running in group $GROUP."
