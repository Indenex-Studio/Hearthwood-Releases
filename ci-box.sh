#!/usr/bin/env bash
# Hearthwood: many CI runners on ONE rented Ubuntu box (e.g. Hetzner CCX63 48 cores, or a DigitalOcean
# CPU-Optimized droplet), set up and torn down by the hour. Run as root on a fresh Ubuntu 24.04 box.
#
#   bash ci-box.sh setup      install, register and start the runners (asks for one token)
#   bash ci-box.sh status     what each runner is doing
#   bash ci-box.sh stop       pause them (they stay registered)
#   bash ci-box.sh start      resume them
#   bash ci-box.sh teardown   stop and delete everything on this box (then delete the box)
#
# What you get: COUNT runners (default: as many as the box can spare, up to 20) named <hostname>-b1..bN in runner group "hearthwood", label
# "hetzner", so they take every normal CI job like the other Hetzner boxes. Each runner is its own Podman
# container: 2 cores and 4 GB at most, its own network and /tmp, so the SpacetimeDB server (port 3000,
# one-per-machine lock) never collides between jobs. Containers run as the unprivileged user "runner",
# with no extra privileges and no Docker/Podman socket. All of them together stay under TOTAL_CPU/TOTAL_MEM.
#
# Tuning: set before the command, e.g.  COUNT=12 bash ci-box.sh setup
#   COUNT (runners), CPUS and MEM (per runner), TOTAL_CPU (e.g. 4400%), TOTAL_MEM (e.g. 140G)
#
# Cost: the box bills while it exists, even when stopped. After the backlog is clear, run teardown and
# then delete the box in the Hetzner/DigitalOcean console.
# ONLY use with private repositories: the runners run whatever code a PR contains.
set -euo pipefail

ORG="Indenex-Studio"
GROUP="hearthwood"
COUNT="${COUNT:-auto}"
RELEASE="${RELEASE:-2}"   # the last RELEASE runners also take main builds and releases (label "release")
CPUS="${CPUS:-2}"
MEM="${MEM:-4g}"
IMAGE="localhost/hw-ci-runner:latest"
HOST="$(hostname -s)"
PREFIX="$HOST-b"
STATE_DIR="/var/lib/hw-ci"
UNIT_DIR="/etc/containers/systemd"
BUILD_DIR="/var/cache/hw-ci-build"
CORES="$(nproc)"
RAM_GB="$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))"
# Leave 4 cores and a quarter of the memory for the box itself (podman, disk cache, the console).
TOTAL_CPU="${TOTAL_CPU:-$(( (CORES > 8 ? CORES - 4 : CORES / 2) * 100 ))%}"
TOTAL_MEM="${TOTAL_MEM:-$(( RAM_GB * 3 / 4 ))G}"
if [ "$COUNT" = auto ]; then
  # One runner per CPUS cores and MEM of what the box can spare, at most 20.
  by_cpu=$(( (CORES > 8 ? CORES - 4 : CORES / 2) / CPUS )); by_mem=$(( RAM_GB * 3 / 4 / ${MEM%[gG]} ))
  COUNT=$(( by_cpu < by_mem ? by_cpu : by_mem )); [ "$COUNT" -gt 20 ] && COUNT=20; [ "$COUNT" -ge 1 ] || COUNT=1
fi

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
release_names() { local i; for i in $(seq $((COUNT - RELEASE + 1)) "$COUNT"); do [ "$i" -ge 1 ] && echo "$PREFIX$i"; done; }
names() { local i; for i in $(seq 1 "$COUNT"); do echo "$PREFIX$i"; done; }
need_root() { [ "$(id -u)" = 0 ] || die "run this as root (in the web console you already are)."; }

preflight() {
  need_root
  [ "$(uname -m)" = x86_64 ] || die "this setup is for x86_64."
  [ "$COUNT" -ge 1 ] || die "COUNT must be 1 or more."
  if [ $(( COUNT * CPUS )) -gt "$CORES" ]; then
    say "Note: $COUNT runners x $CPUS cores is more than the $CORES cores here; the total cap ($TOTAL_CPU) still applies."
  fi
  say "Box: $CORES cores, ${RAM_GB} GB. $COUNT runners, $CPUS cores and $MEM each, all together at most $TOTAL_CPU and $TOTAL_MEM."
}

install_podman() {
  say "Installing Podman…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q podman curl jq ca-certificates
  local v; v="$(podman version --format '{{.Client.Version}}')"
  [ "$(printf '%s\n4.4\n' "${v%%-*}" | sort -V | head -1)" = "4.4" ] || die "podman $v is too old (4.4+ needed)."
  # 8 GB swap so a runaway Godot export gets slow instead of killed.
  if ! swapon --show | grep -q /swapfile; then
    fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
}

build_image() {
  say "Building the runner image (a few minutes)…"
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
  unregister)
    for f in "${FILES[@]}"; do [ -f "$STATE/$f" ] && cp -a "$STATE/$f" .; done
    ./config.sh remove --token "$RUNNER_TOKEN" ;;
  run)
    for f in "${FILES[@]}"; do
      [ -f "$STATE/$f" ] || { echo "not registered yet: run setup again" >&2; exit 3; }
      cp -a "$STATE/$f" .
    done
    exec ./run.sh ;;
  *) echo "unknown command $1" >&2; exit 2 ;;
esac
EOF
  cat >"$BUILD_DIR/Containerfile" <<'EOF'
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# What the Hearthwood CI jobs expect: git, curl, jq, zip, python3, flock/timeout (util-linux, coreutils).
# .NET, Godot and the SpacetimeDB CLI install themselves into the runner's home.
# Godot (headless exports and the key check) needs the libraries below; Mesa gives it software rendering.
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      ca-certificates curl git jq unzip zip xz-utils python3 tzdata util-linux \
      libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 \
      libgl1 libegl1 libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 \
      libdbus-1-3 libasound2t64 libpulse0 libvulkan1 mesa-vulkan-drivers libgl1-mesa-dri \
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

registered() { [ -f "$STATE_DIR/$1/.runner" ]; }

# Reads a token without echo. The web console can drop Shift, and GitHub tokens are upper case, so it is upper-cased here.
ask_token() {
  local prompt="$1" t
  read -rsp "$prompt" t; echo
  t="$(echo "$t" | tr a-z A-Z | tr -d '[:space:]')"
  [ -n "$t" ] || die "no token given."
  REPLY_TOKEN="$t"
}

register_all() {
  local need=() n
  for n in $(names); do
    mkdir -p "$STATE_DIR/$n"; chown 1001:1001 "$STATE_DIR/$n"
    registered "$n" || need+=("$n")
  done
  if [ "${#need[@]}" -eq 0 ]; then say "All runners are already registered."; return; fi
  cat <<EOF

Now one thing from you:
  1. Open https://github.com/organizations/$ORG/settings/actions/runners/new
  2. In the "Configure" box, copy the long code after --token  (it's valid for 1 hour)
  3. Paste it here and press Enter (it won't be shown)

EOF
  ask_token "Token: "
  export RUNNER_TOKEN="$REPLY_TOKEN"
  for n in "${need[@]}"; do
    say "Registering $n…"
    RUNNER_NAME="$n" ORG="$ORG" GROUP="$GROUP" LABELS="$(release_names | grep -qx "$n" && echo hetzner,release || echo hetzner)" \
      podman run --rm --user runner -v "$STATE_DIR/$n:/state:z" \
      -e RUNNER_TOKEN -e RUNNER_NAME -e ORG -e GROUP -e LABELS "$IMAGE" register
  done
  unset RUNNER_TOKEN REPLY_TOKEN
}

write_units() {
  say "Installing the services…"
  mkdir -p "$UNIT_DIR"
  cat >/etc/systemd/system/hw-ci.slice <<EOF
[Unit]
Description=Hearthwood CI runners (shared CPU and memory budget)

[Slice]
CPUQuota=$TOTAL_CPU
MemoryMax=$TOTAL_MEM
EOF
  local n i=0 first c cores
  for n in $(names); do
    # Pin each runner to its own cores so two jobs never fight over the same ones.
    first=$(( (i * CPUS) % CORES )); cores=""
    for c in $(seq 0 $((CPUS - 1))); do cores="${cores:+$cores,}$(( (first + c) % CORES ))"; done
    i=$((i + 1))
    cat >"$UNIT_DIR/$n.container" <<EOF
# Hearthwood CI runner (made by hearthwood-big-box-runners.sh)
[Unit]
Description=Hearthwood CI runner $n
Wants=network-online.target
After=network-online.target

[Container]
Image=$IMAGE
ContainerName=$n
User=runner
Volume=$STATE_DIR/$n:/state:z
NoNewPrivileges=true
DropCapability=ALL
# dotnet crashed (signal 11, exit 139) in these containers; write-xor-execute is the suspected cause (turned off here).
Environment=DOTNET_EnableWriteXorExecute=0
PodmanArgs=--cpus=$CPUS --memory=$MEM --pids-limit=4096 --cpuset-cpus=$cores

[Service]
Slice=hw-ci.slice
Restart=always
RestartSec=30
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
  done
  systemctl daemon-reload
}

start_all() { local n; for n in $(names); do systemctl start "$n.service" || echo "   ($n didn't start)"; done; say "Runners started."; }
stop_all()  { local n; for n in $(names); do systemctl stop "$n.service" 2>/dev/null || true; done; say "Runners stopped. Start again with: bash $0 start"; }

status_all() {
  local n st
  for n in $(names); do
    st="$(systemctl is-active "$n.service" 2>/dev/null || true)"
    printf '%-22s service: %-9s ' "$n" "${st:-unknown}"
    if [ "$st" = active ]; then
      podman logs --tail 50 "$n" 2>/dev/null | grep -E 'Running job|completed with result|Listening for Jobs' | tail -1 || echo
    else echo; fi
  done
  echo "On GitHub: https://github.com/organizations/$ORG/settings/actions/runners"
}

teardown() {
  need_root
  read -rp "Stop and delete the Hearthwood runners from this box? [y/N] " a
  [ "${a,,}" = y ] || exit 0
  stop_all
  local n
  echo
  echo "Optional: paste a removal token so the runners also leave GitHub (Enter to skip; offline ones can be removed on the runners page)."
  read -rsp "Token: " t; echo
  t="$(echo "$t" | tr a-z A-Z | tr -d '[:space:]')"
  if [ -n "$t" ]; then
    export RUNNER_TOKEN="$t"
    for n in $(names); do
      podman run --rm --user runner -v "$STATE_DIR/$n:/state:z" -e RUNNER_TOKEN "$IMAGE" unregister || echo "   ($n could not be removed from GitHub; remove it on the runners page)"
    done
    unset RUNNER_TOKEN
  fi
  for n in $(names); do rm -f "$UNIT_DIR/$n.container"; podman rm -f "$n" >/dev/null 2>&1 || true; done
  rm -f /etc/systemd/system/hw-ci.slice
  systemctl daemon-reload
  rm -rf "$STATE_DIR" "$BUILD_DIR"
  podman rmi -f "$IMAGE" >/dev/null 2>&1 || true
  say "Done. Runners named $PREFIX* that are still listed on https://github.com/organizations/$ORG/settings/actions/runners are offline; remove them there. Then delete this box in the provider console so it stops billing."
}

case "${1:-setup}" in
  setup)    preflight; install_podman; build_image; register_all; write_units; start_all; sleep 20; status_all
            say "All set. Check: bash $0 status   ·   when done: bash $0 teardown, then delete the box." ;;
  status)   status_all ;;
  stop)     need_root; stop_all ;;
  start)    need_root; start_all ;;
  teardown) teardown ;;
  *) die "unknown command '$1' (setup, status, stop, start, teardown)" ;;
esac
