#!/usr/bin/env bash
# integration-254: keep CI jobs on Justin's desktop out of his home folder.
#
# The podman d-slots (hearthwood-d*) are already shut in their containers. The native runners are not: the system
# services actions.runner.Indenex-Studio.* (gpu-2, gpu-3, gpu-4, bazzite-urgent, bazzite-urgent-gpu) run with User=ky
# from folders in his home, so a job (any pull request's code) could read his files: the SpacetimeDB login that owns the
# live world, the launcher's F8 GitHub token, ssh keys. This script runs each of them as a system user that cannot see
# /home or /var/home:
#
#   bash pm/desktop-runners-isolate.sh plan         read-only: what is there and what apply would do (no sudo needed)
#   sudo bash pm/desktop-runners-isolate.sh apply   copy each runner folder out, run the service as the CI user
#   sudo bash pm/desktop-runners-isolate.sh undo    put every service back exactly as apply found it
#
# How: a drop-in (/etc/systemd/system/<unit>.d/50-isolate.conf) sets User=, the copied folder, ProtectHome and
# InaccessiblePaths=/var/home (on Bazzite /home is /var/home, which ProtectHome alone does not cover), plus the GPU groups.
# The unit file itself is never edited, so undo is: remove the drop-in and the copy. The original folders stay where
# they are, untouched (the desktop Remote Control workers use actions-runner-urgent; only the service moves). The copy
# keeps the runner's registration, so nothing re-registers with GitHub.
#
# Settings: OWNER (default: SUDO_USER, else the current user), CI_USER (hearthwood-ci), CI_HOME (/var/lib/hearthwood-ci),
# UNIT_GLOB (actions.runner.Indenex-Studio.*.service). Safe to run again.
set -euo pipefail

OWNER="${OWNER:-${SUDO_USER:-$(id -un)}}"
CI_USER="${CI_USER:-hearthwood-ci}"
CI_HOME="${CI_HOME:-/var/lib/hearthwood-ci}"
UNIT_GLOB="${UNIT_GLOB:-actions.runner.Indenex-Studio.*.service}"
# Test hooks (tools/ci/test-desktop-isolate.sh): a fake root for /etc and CI_HOME, and a fake systemctl.
ROOT="${ISOLATE_ROOT:-}"
SYSTEMCTL="${ISOLATE_SYSTEMCTL:-systemctl}"
SYS_UNITS="$ROOT/etc/systemd/system"
RECORD="$ROOT$CI_HOME/isolate-record.tsv"   # unit, original folder, copy
# integration-259: the owner switches these runners (and the runner watchdog's timer) on and off with
# pm/hearthwood-desktop-runners.sh stop|start, with no password: a polkit rule allows start, stop and restart of those units only.
POLKIT="$ROOT/etc/polkit-1/rules.d/50-hearthwood-runners.rules"
OWNER_HOME="${OWNER_HOME:-$(getent passwd "$OWNER" | cut -d: -f6)}"
HOME_RE="^(/home/|/var/home/|${OWNER_HOME:-/home/}/)"   # a path in someone's home, which the CI user cannot see
# Shared tool trees under /home that hold no secrets stay visible, read-only, and stay on PATH (Homebrew on Bazzite: gh).
SHARED="${SHARED:-/home/linuxbrew}"
SHARED_RE="^($(echo "$SHARED" | tr ' ' '|'))(/|$)"

say() { printf '==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_root() { [ -n "$ROOT" ] || [ "$(id -u)" = 0 ] || die "run this with sudo."; }
value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# The owner's native runner units: unit name and file (only those that run as the owner).
units() {
  local f
  for f in "$SYS_UNITS"/$UNIT_GLOB; do
    [ -f "$f" ] && [ "$(value "$f" User)" = "$OWNER" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
  done | sort -u
}
runner_dir() { local d; d="$(value "$1" WorkingDirectory)"; [ -n "$d" ] || d="$(dirname "$(value "$1" ExecStart | awk '{print $1}')")"; echo "$d"; }
copy_of() { echo "$CI_HOME/$(basename "$1")"; }
dropin() { echo "$SYS_UNITS/$1.d/50-isolate.conf"; }

plan() {
  say "Owner $OWNER; native runner services move to user $CI_USER, folders copied to $CI_HOME."
  local n=0 name file dir
  while IFS=$'\t' read -r name file; do
    n=$((n + 1)); dir="$(runner_dir "$file")"
    say "$name: runs as $OWNER from $dir"
    printf '    -> runs as %s from %s (the original folder stays)\n' "$CI_USER" "$(copy_of "$dir")"
    [ -f "$(dropin "$name")" ] && echo "    already applied"
    # What its jobs take from the owner's session or home: these would be gone after apply.
    grep -hE "^(Environment|EnvironmentFile)=" "$file" | sed 's/^/    unit: /' || true
    [ -f "$dir/.env" ] && grep -E "/home/|DISPLAY|WAYLAND|XDG_RUNTIME" "$dir/.env" | sed 's/^/    runner .env: /' || true
    [ -f "$dir/.path" ] && tr ':' '\n' < "$dir/.path" | grep -E "$HOME_RE" | grep -vE "$SHARED_RE" | sed 's/^/    on its PATH from home (dropped): /' || true
    [ -f "$dir/.path" ] && tr ':' '\n' < "$dir/.path" | grep -E "$SHARED_RE" | sed 's/^/    on its PATH, kept (shared, read-only): /' || true
  done < <(units)
  [ "$n" -gt 0 ] || say "No runner services running as $OWNER in $SYS_UNITS (nothing to move)."
  say "apply also lets $OWNER start and stop these services and hw-watchdog.timer with no password ($POLKIT),"
  echo "    so 'bash pm/hearthwood-desktop-runners.sh stop' switches every runner off."
}

apply() {
  need_root
  if [ -z "$ROOT" ] && ! getent passwd "$CI_USER" > /dev/null; then
    useradd --system --home-dir "$CI_HOME" --create-home --shell /usr/sbin/nologin "$CI_USER"
    say "Made the system user $CI_USER."
  fi
  mkdir -p "$ROOT$CI_HOME"; touch "$RECORD"
  local name file dir copy groups="" g binds="" p real
  # Each shared tree, by its real path too (on Bazzite /home is a link to /var/home).
  for p in $SHARED; do
    real="$( [ -n "$ROOT" ] && echo "$p" || readlink -f "$p" 2> /dev/null || echo "$p")"
    binds="${binds}BindReadOnlyPaths=-$p"$'\n'
    [ "$real" != "$p" ] && binds="${binds}BindReadOnlyPaths=-$real"$'\n'
  done
  for g in video render; do { [ -n "$ROOT" ] || getent group "$g" > /dev/null; } && groups="$groups $g"; done
  while IFS=$'\t' read -r name file; do
    if grep -q "^$name	" "$RECORD"; then say "$name: already applied."; continue; fi
    dir="$(runner_dir "$file")"; copy="$(copy_of "$dir")"
    [ -d "$dir" ] || { say "$name: folder $dir is missing; left as it is."; continue; }
    "$SYSTEMCTL" stop "$name" || true
    # The runner's own files and registration; not _work (the jobs' checkouts) or _diag (old logs).
    mkdir -p "$ROOT$copy"
    (cd "$dir" && find . -mindepth 1 -maxdepth 1 ! -name _work ! -name _diag -exec cp -a {} "$ROOT$copy/" \;)
    # A PATH entry in the owner's home would point nowhere for the CI user: drop it, and say so.
    if [ -f "$ROOT$copy/.path" ]; then
      tr ':' '\n' < "$ROOT$copy/.path" | grep -E "$HOME_RE" | grep -vE "$SHARED_RE" | sed "s/^/    $name: dropped from PATH: /" || true
      tr -d '\n' < "$ROOT$copy/.path" | tr ':' '\n' | awk -v h="$HOME_RE" -v k="$SHARED_RE" '$0 !~ h || $0 ~ k' | paste -sd: - > "$ROOT$copy/.path.new" || true
      mv "$ROOT$copy/.path.new" "$ROOT$copy/.path"
    fi
    [ -z "$ROOT" ] && chown -R "$CI_USER:$CI_USER" "$copy"
    mkdir -p "$(dirname "$(dropin "$name")")"
    cat > "$(dropin "$name")" << EOF
# integration-254 (pm/desktop-runners-isolate.sh): this runner runs as $CI_USER from its own copy, and cannot see /home.
[Service]
User=$CI_USER
Group=$CI_USER
SupplementaryGroups=$groups
WorkingDirectory=$copy
ExecStart=
ExecStart=$copy/runsvc.sh
Environment=HOME=$CI_HOME
ProtectHome=tmpfs
TemporaryFileSystem=/var/home:ro
$binds
PrivateTmp=yes
NoNewPrivileges=yes
EOF
    printf '%s\t%s\t%s\n' "$name" "$dir" "$copy" >> "$RECORD"
    say "$name now runs as $CI_USER from $copy."
  done < <(units)
  # The owner's switch (integration-259): start, stop and restart of the runner services and the watchdog timer, nothing else.
  mkdir -p "$(dirname "$POLKIT")"
  cat > "$POLKIT" << EOF
// integration-259 (pm/desktop-runners-isolate.sh): $OWNER switches the Hearthwood runners on and off without a password
// (pm/hearthwood-desktop-runners.sh stop|start). Only start, stop and restart, only of these units. undo removes this file.
polkit.addRule(function(action, subject) {
  if (action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "$OWNER") return polkit.Result.NOT_HANDLED;
  var unit = action.lookup("unit") || "", verb = action.lookup("verb") || "";
  if (verb != "start" && verb != "stop" && verb != "restart") return polkit.Result.NOT_HANDLED;
  if (unit.indexOf("actions.runner.Indenex-Studio.") == 0 || unit == "hw-watchdog.timer" || unit == "hw-watchdog.service") return polkit.Result.YES;
  return polkit.Result.NOT_HANDLED;
});
EOF
  chmod 644 "$POLKIT"
  say "$OWNER can now switch the runners with: bash pm/hearthwood-desktop-runners.sh stop (or start), no password."
  "$SYSTEMCTL" daemon-reload
  cut -f1 "$RECORD" | while read -r name; do "$SYSTEMCTL" restart "$name" || say "$name did not start; see journalctl -u $name"; done
  # The same sandbox as the runners, checked for real: the owner's home is unreadable, the shared tools are there.
  if [ -z "$ROOT" ]; then
    if systemd-run --quiet --wait --pipe -p User="$CI_USER" -p ProtectHome=tmpfs -p TemporaryFileSystem=/var/home:ro \
        $(printf '%s' "$binds" | sed 's/^/-p /' | tr '\n' ' ') \
        sh -c "! ls '$OWNER_HOME' > /dev/null 2>&1 && ! ls /home/$OWNER > /dev/null 2>&1 && { [ ! -d /home/linuxbrew ] || [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; }"; then
      say "Checked: as $CI_USER, $OWNER_HOME cannot be read, and /home/linuxbrew can."
    else
      say "WARNING: the sandbox check failed (the home is readable, or linuxbrew is missing). Run undo, and tell Integration."
    fi
  fi
  say "Done. Undo with: sudo bash pm/desktop-runners-isolate.sh undo"
}

undo() {
  need_root
  [ -s "$RECORD" ] || { rm -f "$POLKIT"; say "Nothing to undo."; return 0; }
  local name dir copy
  while IFS=$'\t' read -r name dir copy; do
    "$SYSTEMCTL" stop "$name" || true
    rm -f "$(dropin "$name")"; rmdir "$(dirname "$(dropin "$name")")" 2> /dev/null || true
    rm -rf "${ROOT}${copy:?}"
    say "$name runs as $OWNER from $dir again."
  done < "$RECORD"
  "$SYSTEMCTL" daemon-reload
  cut -f1 "$RECORD" | while read -r name; do "$SYSTEMCTL" start "$name" || true; done
  rm -f "$RECORD" "$POLKIT"
  say "Undone. The user $CI_USER stays (userdel $CI_USER removes it)."
}

case "${1:-plan}" in
  plan) plan ;;
  apply) apply ;;
  undo) undo ;;
  *) die "usage: $0 plan|apply|undo" ;;
esac
