#!/usr/bin/env bash
# Hearthwood: CI runners on your own desktop (Bazzite, or any Linux with rootless Podman).
# Adapted from the Upkeep Scoop desktop script; the two sets live side by side and don't touch each other.
#
#   bash hearthwood-desktop-runners.sh            set everything up (asks for one GitHub token)
#   bash hearthwood-desktop-runners.sh status     what each runner is doing
#   bash hearthwood-desktop-runners.sh stop       pause them (gaming night); they stay registered
#                                                 STOP THEM BEFORE PLAYING: with the runners busy, the game server
#                                                 on this machine slows down and the game rubberbands.
#   bash hearthwood-desktop-runners.sh start      resume them
#   bash hearthwood-desktop-runners.sh update     rebuild the image and restart
#   bash hearthwood-desktop-runners.sh remove     stop and delete everything local
#   bash hearthwood-desktop-runners.sh relabel    make the last RELEASE (2) runners take only main builds/releases
#   bash hearthwood-desktop-runners.sh render     rewrite and restart only the render runner (leaves the CI runners alone)
#
# Second machine (a laptop): put the word laptop first, e.g.  bash hearthwood-desktop-runners.sh laptop
# (also: laptop status | laptop stop | laptop start | laptop update | laptop remove). That mode makes 3 runners named
# hearthwood-l1..l2 (labels hetzner,laptop) plus one render runner hearthwood-render-l (labels gpu,laptop, using
# the NVIDIA GPU through Podman's CDI), no release label, capped at 6 cores and 12 GB in total. The names differ
# from the desktop's, so the two sets never take over each other's registrations. If the desktop is also on,
# render jobs go to whichever render runner is free. Skip the render runner with NO_RENDER=1.
#
# What it does: builds one container image (Ubuntu 24.04 + the GitHub Actions runner,
# checksum-checked, + what Godot needs), registers with the Indenex-Studio org in runner group
# "hearthwood":
#   - COUNT CI runners hearthwood-d1..dN, labels hetzner,desktop: they take every normal CI job,
#     same as the Hetzner boxes.
#   - one render runner hearthwood-render, labels gpu,desktop: it only takes render jobs, so
#     renders never wait behind a build (that is how renders get priority). It gets your GPU and
#     your screen session (Wayland) so Godot renders with the real GPU. It only works while you
#     are logged in to the desktop; render jobs wait otherwise.
# All run as systemd user services (Podman quadlets) that start at boot and restart if they crash.
#
# Tuning: set before the command, e.g.  COUNT=6 CPUS=2 bash hearthwood-desktop-runners.sh
#   COUNT, CPUS and MEM are per CI runner; TOTAL_CPU and TOTAL_MEM cap all Hearthwood runners together.
#
# Safety: rootless Podman, nothing privileged, no access to your home folder or files, no
# Podman/Docker socket. Each runner gets a CPU and memory cap and low CPU priority, so games
# and apps win. The render runner also sees your GPU and Wayland socket (needed to draw).
# The registration token is only kept in memory while the script runs.
# ONLY use these runners with private repositories: they run whatever code a PR contains.
set -euo pipefail

# "laptop" as the first word switches to the laptop profile (set before the defaults below are read).
if [ "${1:-}" = laptop ]; then
  shift
  : "${PREFIX:=hearthwood-l}" "${COUNT:=2}" "${RELEASE:=0}" "${NO_RENDER:=0}" "${RENDER:=hearthwood-render-l}" "${TOTAL_CPU:=600%}" "${TOTAL_MEM:=12G}"
  LAPTOP=1
fi
ORG="Indenex-Studio"
GROUP="hearthwood"
COUNT="${COUNT:-8}"              # how many CI runners (jobs at once)
RELEASE="${RELEASE:-2}"          # the last RELEASE of them only take main builds and releases (label "release")
CPUS="${CPUS:-2}"                # CPU cores each CI runner may use at most
MEM="${MEM:-4g}"                 # memory each runner may use at most (Godot exports are hungry)
TOTAL_CPU="${TOTAL_CPU:-1200%}"  # all Hearthwood runners together: 1200% = 12 CPU threads
TOTAL_MEM="${TOTAL_MEM:-20G}"    # all Hearthwood runners together (same caps as the Upkeep Scoop set; the two never run at once)
IMAGE="localhost/hw-ci-runner:latest"
PREFIX="${PREFIX:-hearthwood-d}"
NO_RENDER="${NO_RENDER:-0}"      # 1 = no render runner (a machine without the desktop session/GPU setup)
LAPTOP="${LAPTOP:-0}"
RENDER="${RENDER:-hearthwood-render}"
UNIT_DIR="$HOME/.config/containers/systemd"
SLICE_DIR="$HOME/.config/systemd/user"
BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hw-ci-runner"
HELPER_DIR="$HOME/.local/share/hw-ci-runner"   # small helper scripts the services run (kept out of the cache)

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
names() { local i; for i in $(seq 1 "$COUNT"); do echo "$PREFIX$i"; done; [ "$NO_RENDER" = 1 ] || echo "$RENDER"; }
release_names() { local i; for i in $(seq $((COUNT - RELEASE + 1)) "$COUNT"); do [ "$i" -ge 1 ] && echo "$PREFIX$i"; done; }
labels_for() {
  if [ "$1" = "$RENDER" ]; then if [ "$LAPTOP" = 1 ]; then echo "gpu,laptop"; else echo "gpu,desktop"; fi
  elif release_names | grep -qx "$1"; then echo "release,desktop"
  elif [ "$LAPTOP" = 1 ]; then echo "hetzner,laptop"
  else echo "hetzner,desktop"; fi
}

# Re-registers the release runners with the "release" label (GitHub's page can't edit labels of these runners).
relabel_release() {
  local n
  for n in $(release_names); do
    systemctl --user stop "$n.service" 2>/dev/null || true
    podman rm -f "$n" >/dev/null 2>&1 || true
    podman volume rm -f "hw-ci-$n" >/dev/null 2>&1 || true
  done
  register_all
  for n in $(release_names); do systemctl --user start "$n.service"; done
  sleep 15; status_all
  say "Done: $(release_names | tr '\n' ' ')now only take jobs labelled release."
}

preflight() {
  command -v podman >/dev/null || die "podman isn't installed (Bazzite ships it; on other distros install podman first)."
  local v; v="$(podman version --format '{{.Client.Version}}' 2>/dev/null || echo 0)"
  [ "$(printf '%s\n4.4\n' "${v%%-*}" | sort -V | head -1)" = "4.4" ] || die "podman $v is too old (4.4+ needed for quadlets)."
  systemctl --user show-environment >/dev/null 2>&1 || die "systemd user services aren't available in this shell. Run it from a normal desktop terminal."
  [ "$(uname -m)" = x86_64 ] || die "this setup is for x86_64."
}

build_image() {
  say "Building the runner image (first time takes a few minutes)…"
  mkdir -p "$BUILD_DIR"
  cat >"$BUILD_DIR/entry.sh" <<'EOF'
#!/bin/bash
# Runs inside the container as the unprivileged user "runner".
set -euo pipefail
cd /opt/actions-runner
STATE=/state
FILES=(.runner .credentials .credentials_rsaparams)
case "${1:-run}" in
  register)
    ./config.sh --unattended --replace --url "https://github.com/$ORG" --token "$RUNNER_TOKEN" \
      --runnergroup "$GROUP" --name "$RUNNER_NAME" --labels "$LABELS" --work _work
    for f in "${FILES[@]}"; do cp -a "$f" "$STATE/"; done
    echo "registered $RUNNER_NAME" ;;
  run)
    for f in "${FILES[@]}"; do
      [ -f "$STATE/$f" ] || { echo "not registered yet: run the setup script again" >&2; exit 3; }
      cp -a "$STATE/$f" .
    done
    exec ./run.sh ;;
  *) echo "unknown command $1" >&2; exit 2 ;;
esac
EOF
  cat >"$BUILD_DIR/Containerfile" <<'EOF'
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# What the Hearthwood CI jobs expect: git, curl, jq, zip, python3, flock/timeout (util-linux,
# coreutils). .NET, Godot and the SpacetimeDB CLI install themselves into the runner's home.
# Godot needs the X11/Wayland/font/Vulkan libraries below, plus Mesa drivers for the render runner.
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      ca-certificates curl git jq unzip zip xz-utils python3 tzdata util-linux \
      libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 \
      libgl1 libegl1 libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 \
      libdbus-1-3 libasound2t64 libpulse0 libvulkan1 mesa-vulkan-drivers libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*
# Newer Mesa (kisak PPA): Ubuntu 24.04's own Mesa is too old for the Radeon RX 9070 XT (RDNA4).
RUN apt-get update -q && apt-get install -y -q --no-install-recommends software-properties-common gpg-agent \
    && add-apt-repository -y ppa:kisak/kisak-mesa \
    && apt-get update -q && apt-get upgrade -y -q && apt-get install -y -q --no-install-recommends mesa-vulkan-drivers libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*
# GitHub CLI: some workflow steps call gh.
RUN curl -fsSL --retry 5 -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -q && apt-get install -y -q --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* && gh --version
RUN useradd -m -u 1001 -s /bin/bash runner
# The GitHub Actions runner: latest release, checked against GitHub's published SHA-256.
RUN set -eux; mkdir -p /opt/actions-runner; cd /tmp; \
    curl -fsSL --retry 5 -H 'Accept: application/vnd.github+json' -o rel.json https://api.github.com/repos/actions/runner/releases/latest; \
    ver="$(jq -r '.tag_name | ltrimstr("v")' rel.json)"; \
    asset="actions-runner-linux-x64-$ver.tar.gz"; \
    url="$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' rel.json)"; \
    sha="$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // "" | ltrimstr("sha256:")' rel.json)"; \
    echo "$sha" | grep -Eq '^[0-9a-f]{64}$'; \
    curl -fsSL --retry 5 -o runner.tgz "$url"; \
    echo "$sha  runner.tgz" | sha256sum -c -; \
    tar xzf runner.tgz -C /opt/actions-runner; rm runner.tgz rel.json; \
    /opt/actions-runner/bin/installdependencies.sh; rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner /opt/actions-runner
COPY --chmod=755 entry.sh /usr/local/bin/entry.sh
USER runner
ENTRYPOINT ["/usr/local/bin/entry.sh"]
CMD ["run"]
EOF
  podman build --pull=newer -t "$IMAGE" "$BUILD_DIR"
}

registered() { podman run --rm --user runner -v "hw-ci-$1:/state:U" --entrypoint test "$IMAGE" -f /state/.runner 2>/dev/null; }

register_all() {
  local need=() n
  for n in $(names); do podman volume exists "hw-ci-$n" || podman volume create "hw-ci-$n" >/dev/null; done
  for n in $(names); do registered "$n" || need+=("$n"); done
  if [ "${#need[@]}" -eq 0 ]; then say "All runners are already registered."; return; fi
  cat <<EOF

Now one thing from you:
  1. Open https://github.com/organizations/$ORG/settings/actions/runners/new
  2. In the "Configure" box, copy the long code after --token  (it's valid for 1 hour)
  3. Paste it here and press Enter (it won't be shown)

EOF
  local token; read -rsp "Token: " token; echo
  [ -n "$token" ] || die "no token given."
  export RUNNER_TOKEN="$token"
  for n in "${need[@]}"; do
    say "Registering $n…"
    RUNNER_NAME="$n" ORG="$ORG" GROUP="$GROUP" LABELS="$(labels_for "$n")" \
      podman run --rm --user runner -v "hw-ci-$n:/state:U" \
      -e RUNNER_TOKEN -e RUNNER_NAME -e ORG -e GROUP -e LABELS "$IMAGE" register
  done
  unset RUNNER_TOKEN token
}

gpu_args() {
  # NVIDIA (Bazzite's nvidia images ship the container toolkit) or AMD/Intel (/dev/dri).
  if [ -e /dev/nvidia0 ]; then
    if [ -e /etc/cdi/nvidia.yaml ] || [ -e /var/run/cdi/nvidia.yaml ] || nvidia-ctk cdi list 2>/dev/null | grep -q 'nvidia.com/gpu=all'; then
      echo "--device nvidia.com/gpu=all"
    else
      echo "   (NVIDIA GPU found but no container GPU config. One fix, then run this again:  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml )" >&2
      echo "--device /dev/dri"
    fi
  else
    echo "--device /dev/dri"
  fi
}

write_units() {
  say "Installing the services…"
  mkdir -p "$UNIT_DIR" "$SLICE_DIR"
  cat >"$SLICE_DIR/hw-ci.slice" <<EOF
[Unit]
Description=Hearthwood CI runners (shared CPU and memory budget)

[Slice]
CPUQuota=$TOTAL_CPU
MemoryMax=$TOTAL_MEM
CPUWeight=20
EOF
  local n i=0 host cpuset_ok=0 first c cores
  host="$(nproc)"
  if grep -qw cpuset "/sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers" 2>/dev/null; then
    cpuset_ok=1
  else
    echo "   (cpuset isn't delegated to your user; runners get CPU caps but no core pinning)"
  fi
  for n in $(names); do
    [ "$n" = "$RENDER" ] && continue
    cores=""
    if [ "$cpuset_ok" = 1 ]; then
      first=$(( (i * CPUS) % host ))
      for c in $(seq 0 $((CPUS - 1))); do cores="${cores:+$cores,}$(( (first + c) % host ))"; done
    fi
    i=$((i + 1))
    cat >"$UNIT_DIR/$n.container" <<EOF
# Hearthwood CI runner (made by hearthwood-desktop-runners.sh)
[Unit]
Description=Hearthwood CI runner $n
Wants=network-online.target
After=network-online.target

[Container]
Image=$IMAGE
ContainerName=$n
User=runner
Volume=hw-ci-$n:/state:U,z
NoNewPrivileges=true
DropCapability=ALL
PodmanArgs=--cpus=$CPUS --memory=$MEM --cpu-shares=256 --pids-limit=4096${cores:+ --cpuset-cpus=$cores}

[Service]
Slice=hw-ci.slice
Restart=always
RestartSec=30
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
  done
  [ "$NO_RENDER" = 1 ] || write_render_unit
  systemctl --user daemon-reload
  loginctl enable-linger "$USER" 2>/dev/null || echo "   (couldn't enable start-at-boot; the runners will start when you log in)"
}

# The desktop's Wayland socket is wayland-0 on some sessions and wayland-1 (KDE on Bazzite) or higher on others, and
# it only exists once you are logged in. The render unit mounts one fixed name, $XDG_RUNTIME_DIR/hw-render-wayland,
# and this helper (run by the unit before each start) points that name at whichever wayland-N socket exists now,
# waiting for one if you are not logged in yet. A start that finds none fails and systemd retries 30 s later.
write_wayland_helper() {
  mkdir -p "$HELPER_DIR"
  cat >"$HELPER_DIR/render-wayland.sh" <<'EOF'
#!/bin/bash
# Made by hearthwood-desktop-runners.sh: links the desktop's Wayland socket for the render runner.
rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for _ in $(seq 1 110); do
  pick=""
  if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$rt/$WAYLAND_DISPLAY" ]; then pick="$WAYLAND_DISPLAY"; fi
  if [ -z "$pick" ]; then
    for s in "$rt"/wayland-[0-9]*; do [ -S "$s" ] && { pick="${s##*/}"; break; }; done
  fi
  if [ -n "$pick" ]; then
    ln -sfn "$pick" "$rt/hw-render-wayland"
    echo "render runner uses $rt/$pick"
    exit 0
  fi
  sleep 5
done
echo "no Wayland socket (wayland-N) in $rt yet: log in to the desktop; systemd tries again shortly" >&2
exit 1
EOF
  chmod 755 "$HELPER_DIR/render-wayland.sh"
}

# Render runner: your GPU and your Wayland session, mapped to the container's runner user. Inside the container the
# socket is always /tmp/runtime/wayland-0, whatever its name on the desktop.
write_render_unit() {
  mkdir -p "$UNIT_DIR"
  write_wayland_helper
  cat >"$UNIT_DIR/$RENDER.container" <<EOF
# Hearthwood render runner (made by hearthwood-desktop-runners.sh)
[Unit]
Description=Hearthwood render runner (GPU)
Wants=network-online.target
After=network-online.target

[Container]
Image=$IMAGE
ContainerName=$RENDER
User=runner
UserNS=keep-id:uid=1001,gid=1001
Volume=hw-ci-$RENDER:/state:U
Volume=%t/hw-render-wayland:/tmp/runtime/wayland-0
Environment=XDG_RUNTIME_DIR=/tmp/runtime WAYLAND_DISPLAY=wayland-0
SecurityLabelDisable=true
NoNewPrivileges=true
DropCapability=ALL
PodmanArgs=$(gpu_args) --group-add keep-groups --memory=$MEM --pids-limit=4096

[Service]
Slice=hw-ci.slice
ExecStartPre=$HELPER_DIR/render-wayland.sh
Restart=always
RestartSec=30
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
}

# Rewrites and restarts only the render runner (the CI runners are left exactly as they are, on or off).
fix_render() {
  [ "$NO_RENDER" = 1 ] && die "NO_RENDER=1 is set: this machine has no render runner."
  [ -f "$UNIT_DIR/$RENDER.container" ] || die "no $RENDER service here yet; run the full setup first: bash $0"
  podman image exists "$IMAGE" || die "the runner image is missing; run: bash $0 update"
  say "Rewriting the $RENDER service so it finds your Wayland screen (wayland-0, wayland-1, ...)…"
  write_render_unit
  systemctl --user daemon-reload
  systemctl --user reset-failed "$RENDER.service" 2>/dev/null || true
  systemctl --user restart "$RENDER.service" || { journalctl --user -u "$RENDER.service" -n 20 --no-pager; die "$RENDER didn't start (log above)."; }
  sleep 15
  status_all | grep -E "^$RENDER |On GitHub" || true
  say "Done."
}

unit() { echo "$1.service"; }

start_all()  { local n; for n in $(names); do systemctl --user start "$(unit "$n")" || echo "   ($n didn't start; the render runner needs you logged in to the desktop)"; done; say "Runners started."; }
stop_all()   { local n; for n in $(names); do systemctl --user stop "$(unit "$n")" 2>/dev/null || true; done; say "Runners stopped. Start again with: bash $0 start"; }

status_all() {
  local n st
  for n in $(names); do
    st="$(systemctl --user is-active "$(unit "$n")" 2>/dev/null || true)"
    printf '%-22s service: %-9s ' "$n" "${st:-unknown}"
    if [ "$st" = active ]; then
      podman logs --tail 50 "$n" 2>/dev/null | grep -E 'Running job|completed with result|Listening for Jobs' | tail -1 || echo
    else echo; fi
  done
  echo "On GitHub: https://github.com/organizations/$ORG/settings/actions/runners"
}

remove_all() {
  read -rp "Stop and delete the Hearthwood desktop runners from this computer? [y/N] " a
  [ "${a,,}" = y ] || exit 0
  stop_all
  local n
  for n in $(names); do rm -f "$UNIT_DIR/$n.container"; podman rm -f "$n" >/dev/null 2>&1 || true; podman volume rm -f "hw-ci-$n" >/dev/null 2>&1 || true; done
  rm -f "$SLICE_DIR/hw-ci.slice"; rm -rf "$HELPER_DIR"
  systemctl --user daemon-reload
  podman rmi -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$BUILD_DIR"
  say "Done. Last step: on https://github.com/organizations/$ORG/settings/actions/runners click each hearthwood-d* and $RENDER runner and Remove it."
}

case "${1:-setup}" in
  setup)  preflight; build_image; register_all; write_units; start_all; sleep 20; status_all
          say "All set. Pause with: bash $0 stop   ·   resume with: bash $0 start" ;;
  status) status_all ;;
  stop|pause) stop_all ;;
  start|resume) start_all ;;
  update) preflight; build_image; write_units; stop_all; start_all ;;
  remove) remove_all ;;
  relabel) preflight; relabel_release ;;
  render) preflight; fix_render ;;
  *) die "unknown command '$1' (setup, status, stop, start, update, remove, relabel, render)" ;;
esac
