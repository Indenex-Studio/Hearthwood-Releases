#!/usr/bin/env bash
# Hearthwood: re-split the Hetzner CCX63 runners 50/50 between big and small (D-777).
# Run as root on the box (it uses the runner scripts the box was set up with, in /root/hw):
#
#   wget raw.githubusercontent.com/indenex-studio/hearthwood-releases/claude/project-thread-7et3wa/ccx63-rebalance2.sh && bash ccx63-rebalance2.sh
#   bash /root/hw/ccx63-rebalance2.sh            14 big + 14 small (default)
#   BIG=12 SMALL=12 bash /root/hw/ccx63-rebalance2.sh
#   bash /root/hw/ccx63-rebalance2.sh keepcaps   same, if the box was set up with "keepcaps" (or "plain")
#
# Big runners: 2 threads, 4 GB, labels hetzner,big (the last 2 also "release"). Small: 1 thread, 2.5 GB, hetzner,small.
# 14 + 14 uses 42 of the 44 threads the box spares, and 91 GB of its 192 GB.
# It removes the current runners from this box and sets up the new split. Jobs running on this box right now are
# stopped and need a re-run, so run it when the queue is quiet if you can. It takes about 10 minutes (the runner image
# is rebuilt). It asks for one registration token, used for every runner.
# Old runners whose names are not reused (e.g. <host>-s15..s36) show as offline on the GitHub runners page:
# remove them there, or GitHub drops them by itself after 14 days.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Downloaded with wget into another folder: use the runner scripts the box was set up with.
[ -f "$HERE/ccx63-split.sh" ] || HERE=/root/hw
SPLIT="$HERE/ccx63-split.sh"
[ -f "$SPLIT" ] && [ -f "$HERE/ci-box.sh" ] || { echo "ccx63-split.sh and ci-box.sh must be next to this script ($HERE)."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run this as root."; exit 1; }

BIG="${BIG:-14}"
SMALL="${SMALL:-14}"
MODE="${1:-setup}"
case "$MODE" in setup|keepcaps|plain) ;; *) echo "usage: bash $0 [keepcaps|plain]"; exit 1 ;; esac
HOST="$(hostname -s)"
UNITS=/etc/containers/systemd

# How many of each the box has now (from the runner units), so teardown removes all of them.
OLD_BIG=$( { find "$UNITS" -maxdepth 1 -name "$HOST-b*.container" 2>/dev/null || true; } | wc -l)
OLD_SMALL=$( { find "$UNITS" -maxdepth 1 -name "$HOST-s*.container" 2>/dev/null || true; } | wc -l)
echo "Now:   $OLD_BIG big + $OLD_SMALL small runners."
echo "After: $BIG big (2 threads, 4 GB) + $SMALL small (1 thread, 2.5 GB) = $(( BIG * 2 + SMALL )) threads, $(( BIG * 4 + SMALL * 5 / 2 )) GB."
[ $(( BIG * 2 + SMALL )) -le $(( $(nproc) - 4 )) ] || { echo "That needs more than the $(( $(nproc) - 4 )) threads this box spares; lower BIG or SMALL."; exit 1; }
read -rp "Running jobs on this box will stop. Go ahead? [y/N] " a
[ "${a,,}" = y ] || exit 0

cat <<MSG

One thing from you (used for every runner):
  1. Open https://github.com/organizations/Indenex-Studio/settings/actions/runners/new
  2. In the "Configure" box, copy the long code after --token  (it's valid for 1 hour)
  3. Paste it here and press Enter (it won't be shown)

MSG
read -rsp "Token: " t; echo
t="$(echo "$t" | tr a-z A-Z | tr -d '[:space:]')"
[ -n "$t" ] || { echo "No token given."; exit 1; }

echo "Removing the current runners from this box…"
# teardown asks each class (small, then big) "[y/N]" and then for an optional removal token: answer y and skip the token, twice.
if [ "$OLD_SMALL" -gt 0 ] || [ "$OLD_BIG" -gt 0 ]; then
  printf 'y\n\ny\n\n' | SMALL="$OLD_SMALL" STD="$OLD_BIG" bash "$SPLIT" teardown
fi

# Ubuntu's automatic updates can hold the package lock; setup fails if it runs then.
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || pgrep -f /usr/bin/unattended-upgrade >/dev/null; do echo "Waiting for Ubuntu updates to finish…"; sleep 10; done
echo "Setting up $BIG big + $SMALL small…"
HW_TOKEN="$t" SMALL="$SMALL" STD="$BIG" bash "$SPLIT" "$MODE"
unset t
echo
SMALL="$SMALL" STD="$BIG" bash "$SPLIT" status
echo "Done. Later status: SMALL=$SMALL STD=$BIG bash $SPLIT status"
