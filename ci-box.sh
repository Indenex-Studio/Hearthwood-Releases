#!/usr/bin/env bash
# Hearthwood: many CI runners on ONE rented Ubuntu box (e.g. Hetzner CCX63 48 cores, or a DigitalOcean
# CPU-Optimized droplet), set up and torn down by the hour. Run as root on a fresh Ubuntu 24.04 box.
#
#   bash hearthwood-big-box-runners.sh setup      install, register and start the runners (asks for one token)
#   bash hearthwood-big-box-runners.sh status     what each runner is doing
#   bash hearthwood-big-box-runners.sh check      test a big download and a SpacetimeDB module build inside a runner container
#   bash hearthwood-big-box-runners.sh stop       pause them (they stay registered)
#   bash hearthwood-big-box-runners.sh start      resume them
#   bash hearthwood-big-box-runners.sh teardown   stop and delete everything on this box (then delete the box)
#   bash hearthwood-big-box-runners.sh watchdog-install   add the watchdog to a box that is already set up (setup does it itself;
#                                                  also fine on boxes whose runners came from hetzner-runner.sh)
#   bash hearthwood-big-box-runners.sh watchdog-log       what the watchdog restarted, and when it runs next
#   bash hearthwood-big-box-runners.sh trim               remove unused images and trim the disk (Windows "shrink" uses it)
#
# Disk: the watchdog restarts an idle runner whose container has grown past DISK_CAP_GB (default 20, set in /etc/hw-runner.env;
# 0 turns it off), which gives it a clean container, so runners never pile up weeks of checkouts, caches and builds.
#
# What you get: COUNT runners (default: as many as the box can spare, up to 20) named <hostname>-b1..bN in runner group "hearthwood", label
# "hetzner", so they take every normal CI job like the other Hetzner boxes. Each runner is its own Podman
# container: 2 cores and 4 GB at most, its own network and /tmp, so the SpacetimeDB server (port 3000,
# one-per-machine lock) never collides between jobs. Containers run as the unprivileged user "runner",
# with no extra privileges and no Docker/Podman socket. All of them together stay under TOTAL_CPU/TOTAL_MEM.
#
# Tuning: set before the command, e.g.  COUNT=12 bash hearthwood-big-box-runners.sh setup
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
PREFIX="${PREFIX:-$HOST-b}"          # runner names; another machine type (e.g. the Windows PC) sets its own
EXTRA_LABEL="${EXTRA_LABEL:-}"          # one more label for these runners, e.g. friend
BASE_LABEL="${BASE_LABEL:-hetzner}"     # the label that takes normal CI jobs; a fast lane sets "release" instead, so it never takes PR checks
CORE_OFFSET="${CORE_OFFSET:-0}"         # first core to pin to, so a second runner class on the same box (ccx63-split.sh) uses other cores
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

# Fallback if dotnet still crashes: "setup-keepcaps" (or KEEP_CAPS=1) leaves the container capabilities as they are.
DROP_CAPS="DropCapability=ALL"; [ "${KEEP_CAPS:-0}" = 1 ] && DROP_CAPS=""
NO_NEW_PRIVS="NoNewPrivileges=true"; PLAIN=0
# NO_AUTOSTART=1: the runner units do not start at boot by themselves (the Windows setup starts the wanted number).
INSTALL_SECTION=$'[Install]\nWantedBy=multi-user.target'; [ "${NO_AUTOSTART:-0}" = 1 ] && INSTALL_SECTION=""
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
release_names() { local i; for i in $(seq $((COUNT - RELEASE + 1)) "$COUNT"); do [ "$i" -ge 1 ] && echo "$PREFIX$i"; done; }
# integration-235: a runner with 8 GB or more also gets "mem8", which the release's Publish job asks for (PUBLISH_RUNNER).
labels_for() { local l="$BASE_LABEL"; release_names | grep -qx "$1" && l="$l,release"; [ -n "$EXTRA_LABEL" ] && l="$l,$EXTRA_LABEL"; [ "${MEM%[gG]}" -ge 8 ] 2> /dev/null && l="$l,mem8"; echo "$l"; }
names() { local i; for i in $(seq 1 "$COUNT"); do echo "$PREFIX$i"; done; }
is_wsl() { grep -qi microsoft /proc/version; }
NET="systemd-hw-ci"   # the podman network made from hw-ci.network
# The MTU of the link to the internet (eth0 on WSL), for a container MTU that fits inside it.
host_mtu() {
  local dev; dev="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  cat "/sys/class/net/${dev:-eth0}/mtu" 2>/dev/null || echo 1500
}
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
  apt-get install -y -q podman curl jq ca-certificates iproute2
  is_wsl && apt-get install -y -q ethtool
  local v; v="$(podman version --format '{{.Client.Version}}')"
  [ "$(printf '%s\n4.4\n' "${v%%-*}" | sort -V | head -1)" = "4.4" ] || die "podman $v is too old (4.4+ needed)."
  # 8 GB swap so a runaway Godot export gets slow instead of killed.
  # (Not under WSL, where Windows manages swap through .wslconfig.)
  if ! grep -qi microsoft /proc/version && ! swapon --show | grep -q /swapfile; then
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
  [ -n "${HW_TOKEN:-}" ] || cat <<EOF

Now one thing from you:
  1. Open https://github.com/organizations/$ORG/settings/actions/runners/new
  2. In the "Configure" box, copy the long code after --token  (it's valid for 1 hour)
  3. Paste it here and press Enter (it won't be shown)

EOF
  if [ -n "${HW_TOKEN:-}" ]; then REPLY_TOKEN="$HW_TOKEN"; else ask_token "Token: "; fi
  export RUNNER_TOKEN="$REPLY_TOKEN"
  for n in "${need[@]}"; do
    say "Registering $n…"
    RUNNER_NAME="$n" ORG="$ORG" GROUP="$GROUP" LABELS="$(labels_for "$n")" \
      podman run --rm --user runner -v "$STATE_DIR/$n:/state:z" \
      -e RUNNER_TOKEN -e RUNNER_NAME -e ORG -e GROUP -e LABELS "$IMAGE" register
  done
  unset RUNNER_TOKEN REPLY_TOKEN
}

write_units() {
  say "Installing the services…"
  # Running runners keep their old settings until restarted, so stop them; setup starts them again at the end.
  stop_all >/dev/null
  mkdir -p "$UNIT_DIR"
  # Units left over from an earlier setup with more runners: stop and remove them so they do not start again.
  local f old
  for f in "$UNIT_DIR/$PREFIX"*.container; do
    [ -e "$f" ] || continue
    old="$(basename "$f" .container)"
    names | grep -qx "$old" || { systemctl stop "$old.service" 2>/dev/null || true; rm -f "$f"; }
  done
  cat >/etc/systemd/system/hw-ci.slice <<EOF
[Unit]
Description=Hearthwood CI runners (shared CPU and memory budget)

[Slice]
CPUQuota=$TOTAL_CPU
MemoryMax=$TOTAL_MEM
EOF
  # Own network for the runners with a smaller packet size. On WSL2 (and behind some VPNs and routers) the default
  # 1500 loses big downloads: small requests work, checkout works, then a large download (dotnet, cache, Godot)
  # hangs at near-zero CPU. Set MTU=1500 to turn this off. IPv6 is also off inside the containers (often no route).
  local hm; hm="$(host_mtu)"
  if [ -z "${MTU:-}" ]; then MTU=1400; [ "$hm" -lt 1460 ] && MTU=$(( hm - 60 )); fi
  say "Container packet size (MTU) $MTU (internet link: $hm)."
  # If the runners' network already exists with another MTU, remove it so it is made again with this one.
  if podman network exists "$NET" 2>/dev/null; then
    if [ "$(podman network inspect "$NET" --format '{{index .Options "mtu"}}' 2>/dev/null)" != "$MTU" ]; then
      stop_all >/dev/null; podman network rm -f "$NET" >/dev/null || true
    fi
  fi
  cat >"$UNIT_DIR/hw-ci.network" <<EOF
[Network]
Options=mtu=$MTU
EOF
  # WSL2: the Windows virtual switch can drop large forwarded packets when the Linux side offloads segmenting or
  # checksums, which stalls big downloads in containers while small requests and the VM's own downloads work.
  # Turn those offloads off on the link at every boot.
  if is_wsl; then
    cat >/etc/systemd/system/hw-ci-offload.service <<'EOF'
[Unit]
Description=Hearthwood CI: no segment or checksum offload on the WSL link (big container downloads stall otherwise)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in /sys/class/net/eth*; do ethtool -K "$(basename "$d")" tx off sg off tso off gso off gro off 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now hw-ci-offload.service >/dev/null 2>&1 || true
  fi
  local n i=0 first c cores
  for n in $(names); do
    # Pin each runner to its own cores so two jobs never fight over the same ones.
    first=$(( (CORE_OFFSET + i * CPUS) % CORES )); cores=""
    for c in $(seq 0 $((CPUS - 1))); do cores="${cores:+$cores,}$(( (first + c) % CORES ))"; done
    i=$((i + 1))
    EXTRA_ARGS="--pids-limit=4096 --cpuset-cpus=$cores"; [ "$PLAIN" = 1 ] && EXTRA_ARGS=""
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
Network=hw-ci.network
Volume=$STATE_DIR/$n:/state:z
$NO_NEW_PRIVS
$DROP_CAPS
# dotnet crashed (signal 11, exit 139) in these containers; write-xor-execute is the suspected cause (turned off here).
Environment=DOTNET_EnableWriteXorExecute=0
# Workstation GC: server GC sizes itself by every core on the machine, not this runner's 2, inside a 4 GB cap.
Environment=DOTNET_gcServer=0
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
PodmanArgs=--cpus=$CPUS --memory=$MEM --sysctl=net.ipv6.conf.all.disable_ipv6=1 $EXTRA_ARGS

[Service]
Slice=hw-ci.slice
Restart=always
RestartSec=30
TimeoutStartSec=600

$INSTALL_SECTION
EOF
  done
  systemctl daemon-reload
}

# Runs a script in a throwaway container set up like a runner (same network, limits and restrictions).
in_runner() {
  local a=(--rm --network "$NET" --user runner --cpus="$CPUS" --memory="$MEM" --sysctl=net.ipv6.conf.all.disable_ipv6=1
           -e DOTNET_EnableWriteXorExecute=0 -e DOTNET_gcServer=0 -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1)
  [ -n "$DROP_CAPS" ] && a+=(--cap-drop=all)
  [ -n "$NO_NEW_PRIVS" ] && a+=(--security-opt=no-new-privileges)
  systemctl start hw-ci-network.service >/dev/null 2>&1 || true
  podman run "${a[@]}" --entrypoint /bin/bash "$IMAGE" -c "$1"
}
# The two things CI jobs died on: a big download (the SpacetimeDB CLI; it stalled on WSL) and compiling C# (.NET crashed
# with signal 11 on a big box). A download gives up below 20 KB/s for 30 s.
DL='curl -fsSL --connect-timeout 20 --speed-limit 20000 --speed-time 30 --max-time 300'
net_check_once() {
  in_runner "$DL -o /tmp/t.tgz https://github.com/clockworklabs/SpacetimeDB/releases/download/v2.12.0/spacetime-x86_64-unknown-linux-gnu.tar.gz && echo \"\$(( \$(stat -c %s /tmp/t.tgz) / 1048576 )) MB\""
}
# Builds a fresh SpacetimeDB C# module (the same "spacetime build" the game server uses; on one box only that
# crashed, while other .NET builds were fine). Downloads .NET 8 and the SpacetimeDB CLI, a few minutes.
dotnet_check() {
  say "Checking that a SpacetimeDB module compiles inside a runner container (a few minutes)…"
  in_runner "set -e; W=/tmp/hwcheck; mkdir -p \$W; cd \$W
    $DL -o di.sh https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.sh || $DL -o di.sh https://dot.net/v1/dotnet-install.sh
    bash di.sh --channel 8.0 --install-dir \$W/dn >/dev/null
    $DL https://github.com/clockworklabs/SpacetimeDB/releases/download/v2.12.0/spacetime-x86_64-unknown-linux-gnu.tar.gz | tar xz -C \$W
    export DOTNET_ROOT=\$W/dn PATH=\$W/dn:\$W:\$PATH
    spacetimedb-cli init --lang csharp --server-only --non-interactive --dotnet-version 8 --project-path \$W/m hwcheck >/dev/null
    spacetimedb-cli build -p \$W/m/spacetimedb 2>&1 | tail -5
    test -s \$W/m/spacetimedb/bin/Release/net8.0/wasi-wasm/AppBundle/StdbModule.wasm" \
    || die "the test module did not compile inside the runner container (.NET crashed or failed), so the runners were NOT started (they would only fail jobs). Send this output to Justin."
  say "Module build check passed."
}
# Checks a big download works inside the containers; if not, tries smaller packets before giving up.
net_check() {
  local got m
  say "Checking a big download inside a runner container…"
  if got="$(net_check_once)"; then say "Download check passed ($got)."; return 0; fi
  [ -n "${MTU_FIXED:-}" ] && die "the download check failed with MTU $MTU. Send this output to Justin."
  for m in 1280 1200; do
    say "The download stalled. Trying a smaller packet size ($m)…"
    stop_all >/dev/null; podman network rm -f "$NET" >/dev/null 2>&1 || true
    sed -i "s/^Options=mtu=.*/Options=mtu=$m/" "$UNIT_DIR/hw-ci.network"; systemctl daemon-reload
    if got="$(net_check_once)"; then MTU=$m; say "Download check passed with MTU $m ($got)."; return 0; fi
  done
  die "big downloads still stall inside the runner containers, so the runners were NOT started (they would only fail jobs). Send this output to Justin."
}

# Finds out where the module build crashes: on the box itself, in a plain container, and in containers with fewer
# restrictions. .NET and the CLI are downloaded once into /var/cache/hwcheck; each try works on a fresh copy.
diagnose() {
  need_root
  local C=/var/cache/hwcheck
  if [ ! -x "$C/dn/dotnet" ] || [ ! -x "$C/spacetimedb-cli" ]; then
    say "Downloading .NET 8 and the SpacetimeDB CLI once…"
    rm -rf "$C"; mkdir -p "$C"
    $DL -o "$C/di.sh" https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.sh
    bash "$C/di.sh" --channel 8.0 --install-dir "$C/dn" >/dev/null
    $DL https://github.com/clockworklabs/SpacetimeDB/releases/download/v2.12.0/spacetime-x86_64-unknown-linux-gnu.tar.gz | tar xz -C "$C"
  fi
  chmod -R a+rX "$C"
  local T='set -e; W=$(mktemp -d); cp -a /hwc/dn /hwc/spacetimedb-cli /hwc/spacetimedb-standalone $W/; cd $W; export HOME=$W DOTNET_ROOT=$W/dn PATH=$W/dn:$W:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
    spacetimedb-cli init --lang csharp --server-only --non-interactive --dotnet-version 8 --project-path $W/m hwcheck >/dev/null
    spacetimedb-cli build -p $W/m/spacetimedb >$W/b.log 2>&1 || { tail -3 $W/b.log; exit 1; }
    test -s $W/m/spacetimedb/bin/Release/net8.0/wasi-wasm/AppBundle/StdbModule.wasm'
  try() { local name="$1"; shift; if "$@" >/tmp/hwdiag.log 2>&1; then echo "  PASS  $name"; else echo "  FAIL  $name: $(grep -m1 -iE 'signal|error' /tmp/hwdiag.log | cut -c1-120)"; fi; }
  say "Building a test module four ways (about a minute each)…"
  ln -sfn "$C" /hwc
  try "on the box itself"           bash -c "$T"
  try "container, no limits"        podman run --rm -v "$C:/hwc:ro" --entrypoint /bin/bash "$IMAGE" -c "$T"
  try "container, runner limits"    podman run --rm -v "$C:/hwc:ro" --user runner --cpus="$CPUS" --memory="$MEM" --entrypoint /bin/bash "$IMAGE" -c "$T"
  try "container, no seccomp"       podman run --rm -v "$C:/hwc:ro" --user runner --cpus="$CPUS" --memory="$MEM" --security-opt seccomp=unconfined --entrypoint /bin/bash "$IMAGE" -c "$T"
  say "Done. Send this output to Justin."
}

# The watchdog: every 2 minutes it restarts a runner that sits "Idle" with a dead connection (after sleep or a network
# blip) and never touches one that is running a job. Works for these runners and for plain actions.runner.* services.
install_watchdog() {
  need_root
  say "Installing the runner watchdog…"
  apt-get install -y -q curl >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR"
  cat >/usr/local/bin/hw-watchdog <<'HWWD_EOF'
#!/bin/bash
# Hearthwood runner watchdog (run by hw-watchdog.timer every 2 minutes).
#
# A runner can look registered and "Idle" on GitHub while its connection is dead (the machine slept, WSL was
# paused, the network blipped), so queued jobs never reach it. This restarts such a runner. It only uses
# things on this machine, so it needs no GitHub token. It restarts a runner only when ALL of these hold:
#   - it is not running a job (no Runner.Worker process), so a job is never killed;
#   - its listener process is gone, or this machine just woke up / got its network back, or the runner has
#     been completely silent (no log line) for STALE_MIN minutes;
#   - it was not restarted in the last 10 minutes.
# Every action is logged to /var/log/hw-watchdog.log. Works for the Podman runners made by ci-box.sh and for
# plain "actions.runner.*" services (hetzner-runner.sh, ./svc.sh install).
UNIT_DIR=${HW_UNIT_DIR:-/etc/containers/systemd}
STATE=${HW_STATE:-/var/lib/hw-ci}
LOG=${HW_LOG:-/var/log/hw-watchdog.log}
ENVFILE=${HW_ENV:-/etc/hw-runner.env}
CGROOT=${HW_CGROOT:-/sys/fs/cgroup/system.slice}
PROCROOT=${HW_PROC:-/proc}
INTERVAL=120
STALE_MIN=${STALE_MIN:-45}
MIN_GAP=600
NETURL=${HW_NETURL:-https://github.com/}

mkdir -p "$STATE"
exec 9>"$STATE/watchdog.lock"; flock -n 9 || exit 0
now=$(date +%s)
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ] && tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
[ -e "$STATE/stopped" ] && exit 0   # "ci-box.sh stop": the runners were stopped on purpose

# Did this machine just wake up? (The clock jumps, or the Windows side left a note.)
last=$(cat "$STATE/watchdog.tick" 2>/dev/null || echo "$now"); echo "$now" > "$STATE/watchdog.tick"
if [ $(( now - last )) -gt $(( INTERVAL * 5 / 2 )) ]; then
  log "clock jumped $(( now - last )) s: the machine was asleep or paused"; touch "$STATE/watchdog.refresh"
fi

# Without a network a restart helps nobody: wait, and refresh the runners once it is back.
if ! curl -s -o /dev/null -m 15 "$NETURL"; then
  [ -e "$STATE/watchdog.neterr" ] || log "no network (could not reach $NETURL); waiting"
  touch "$STATE/watchdog.neterr" "$STATE/watchdog.refresh"; exit 0
fi
[ -e "$STATE/watchdog.neterr" ] && { log "network is back"; rm -f "$STATE/watchdog.neterr"; }
refresh=0
if [ -e "$STATE/watchdog.refresh" ]; then
  refresh=1; hwclock -s 2>/dev/null || true   # WSL clocks drift while Windows sleeps, and GitHub refuses a skewed clock
fi

# The runner services: Podman units made by ci-box.sh, then plain actions.runner.* services.
units=(); declare -A podman_unit
if [ -d "$UNIT_DIR" ]; then
  while read -r f; do [ -n "$f" ] && units+=("$(basename "$f" .container).service") && podman_unit[$(basename "$f" .container).service]=1; done < <(ls "$UNIT_DIR"/*.container 2>/dev/null | sort -V)
fi
# WANT in /etc/hw-runner.env (the Windows setup): only the first WANT Podman runners are meant to run.
if [ -f "$ENVFILE" ] && [ ${#units[@]} -gt 0 ]; then
  want=$(sed -n 's/^WANT=//p' "$ENVFILE" | tail -1)
  [ -n "$want" ] && units=("${units[@]:0:$want}")
fi
while read -r u; do [ -n "$u" ] && units+=("$u"); done < <(systemctl list-units --all --plain --no-legend 'actions.runner.*.service' 2>/dev/null | awk '{print $1}')

# The command lines of every process in a unit's cgroup (including the container's, nested below it).
unit_cmds() {
  local cg="$CGROOT/$1" p
  [ -d "$cg" ] || return 0
  for p in $(find "$cg" -name cgroup.procs -exec cat {} + 2>/dev/null); do tr '\0' ' ' < "$PROCROOT/$p/cmdline" 2>/dev/null; echo; done
}
# When this runner's own log was last written (seconds since 1970), or 0.
diag_mtime() {
  local u=$1 n=${1%.service} f d
  if [ -e "$UNIT_DIR/$n.container" ]; then
    podman exec "$n" sh -c 'ls -t /opt/actions-runner/_diag/Runner_*.log 2>/dev/null | head -1 | xargs -r stat -c %Y' 2>/dev/null || echo 0
  else
    d=$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null)
    f=$(ls -t "$d"/_diag/Runner_*.log 2>/dev/null | head -1)
    [ -n "$f" ] && stat -c %Y "$f" || echo 0
  fi
}
unit_since() { local t; t=$(systemctl show -p ActiveEnterTimestamp --value "$1" 2>/dev/null); [ -n "$t" ] && date -d "$t" +%s 2>/dev/null || echo 0; }

restart() {  # restart <unit> <why>
  local u=$1 f="$STATE/wd-${1%.service}.last" prev=0
  [ -f "$f" ] && prev=$(cat "$f")
  if [ $(( now - prev )) -lt $MIN_GAP ]; then return; fi
  log "restarting ${u%.service}: $2"; echo "$now" > "$f"
  systemctl restart "$u" 2>>"$LOG" || log "  restart of ${u%.service} failed"
}

for u in "${units[@]}"; do
  n=${u%.service}
  st=$(systemctl is-active "$u" 2>/dev/null)
  case "$st" in
    active) ;;
    activating|deactivating|reloading) continue ;;
    *)  # Stopped. Start it again only if it is meant to run: a Podman runner inside WANT, or a service that is enabled.
        if [ -n "${podman_unit[$u]:-}" ] || [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ]; then restart "$u" "service was $st"; fi
        continue ;;
  esac
  cmds=$(unit_cmds "$u")
  if echo "$cmds" | grep -q 'Runner.Worker'; then touch "$STATE/wd-$n.busy"; continue; fi   # running a job: hands off
  [ -n "$cmds" ] || continue                                                                  # cgroup not readable here: cannot judge
  if ! echo "$cmds" | grep -q 'Runner.Listener'; then restart "$u" "its listener process is gone"; continue; fi
  if [ "$refresh" = 1 ]; then restart "$u" "idle after the machine woke up or lost its network"; continue; fi
  m=$(diag_mtime "$u"); b=$(stat -c %Y "$STATE/wd-$n.busy" 2>/dev/null || echo 0); s=$(unit_since "$u")
  newest=$m; [ "$b" -gt "$newest" ] && newest=$b; [ "$s" -gt "$newest" ] && newest=$s
  if [ "$newest" -gt 0 ] && [ $(( now - newest )) -gt $(( STALE_MIN * 60 )) ]; then
    restart "$u" "idle and silent for $(( (now - newest) / 60 )) min"
  fi
done
[ "$refresh" = 1 ] && rm -f "$STATE/watchdog.refresh"
# Disk (integration fix for the friend's Windows PC, 2026-11-21: its runners had grown to about 500 GB). Each Podman runner keeps
# everything its jobs write (checkouts, Godot import caches, Rust builds, Godot and .NET downloads, exports) in its container's
# own layer for as long as the container lives, which can be weeks. The jobs' own clean-up (tools/ci/free-disk.sh) only acts when
# the disk looks full, and under WSL the disk always looks nearly empty (a 1 TB virtual disk) while the real file on C: grows.
# So every DISK_EVERY_MIN minutes: an idle runner whose layer is over DISK_CAP_GB is restarted, which throws its layer away (the
# runner comes back clean and fetches what it needs on its next job); unused images are removed; and freed space is trimmed so
# a sparse WSL disk gives it back to Windows. DISK_CAP_GB=0 in /etc/hw-runner.env turns the cap off.
DISK_CAP_GB=${DISK_CAP_GB:-$(sed -n 's/^DISK_CAP_GB=//p' "$ENVFILE" 2>/dev/null | tail -1)}; DISK_CAP_GB=${DISK_CAP_GB:-20}
DISK_EVERY_MIN=${DISK_EVERY_MIN:-30}
disk_last=$(cat "$STATE/disk.tick" 2>/dev/null || echo 0)
if [ ${#podman_unit[@]} -gt 0 ] && command -v podman >/dev/null && [ $(( now - disk_last )) -ge $(( DISK_EVERY_MIN * 60 )) ]; then
  echo "$now" > "$STATE/disk.tick"
  freed=0
  for u in "${units[@]}"; do
    [ -n "${podman_unit[$u]:-}" ] && [ "$DISK_CAP_GB" -gt 0 ] 2>/dev/null || continue
    n=${u%.service}
    [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] || continue
    up=$(podman container inspect -f '{{.GraphDriver.Data.UpperDir}}' "$n" 2>/dev/null)
    [ -n "$up" ] && [ -d "$up" ] || continue
    gb=$(( $(nice -n 19 ionice -c3 du -sxk "$up" 2>/dev/null | cut -f1) / 1048576 ))
    echo "$gb" > "$STATE/disk-$n.gb"
    [ "$gb" -ge "$DISK_CAP_GB" ] || continue
    # Only between jobs, checked again right before the restart (du can take a while).
    unit_cmds "$u" | grep -q 'Runner.Worker' && continue
    unit_cmds "$u" | grep -q 'Runner.Listener' || continue
    restart "$u" "its disk use is ${gb} GB (cap ${DISK_CAP_GB} GB); a fresh container drops it" && freed=1
  done
  # Images no runner uses (an older runner image left by a setup or update that rebuilt it), a day after the last check.
  if [ $(( now - $(cat "$STATE/prune.tick" 2>/dev/null || echo 0) )) -ge 86400 ]; then
    echo "$now" > "$STATE/prune.tick"
    podman image prune -f >/dev/null 2>&1 || true
    freed=1
  fi
  [ "$freed" = 1 ] && sleep 20 && command -v fstrim >/dev/null && fstrim -a >/dev/null 2>&1 || true
fi
exit 0
HWWD_EOF
  chmod 755 /usr/local/bin/hw-watchdog
  cat >/etc/systemd/system/hw-watchdog.service <<'EOF'
[Unit]
Description=Hearthwood runner watchdog (restarts idle runners with a dead connection)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hw-watchdog
EOF
  cat >/etc/systemd/system/hw-watchdog.timer <<'EOF'
[Unit]
Description=Hearthwood runner watchdog, every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hw-watchdog.timer >/dev/null
  say "Watchdog on. What it did: bash $0 watchdog-log"
}

start_all() { rm -f "$STATE_DIR/stopped"; local n; for n in $(names); do systemctl start "$n.service" || echo "   ($n didn't start)"; done; say "Runners started."; }
stop_all()  { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/stopped"; local n; for n in $(names); do systemctl stop "$n.service" 2>/dev/null || true; done; say "Runners stopped. Start again with: bash $0 start"; }

status_all() {
  local n st
  for n in $(names); do
    st="$(systemctl is-active "$n.service" 2>/dev/null || true)"
    printf '%-22s service: %-9s ' "$n" "${st:-unknown}"
    if [ "$st" = active ]; then
      podman logs --tail 50 "$n" 2>/dev/null | grep -E 'Running job|completed with result|Listening for Jobs' | tail -1 || echo
    else echo; fi
  done
  # Disk: what the watchdog last measured per runner (it restarts an idle one over DISK_CAP_GB), and the disk as a whole.
  local d=""; for n in $(names); do [ -f "$STATE_DIR/disk-$n.gb" ] && d="$d $n=$(cat "$STATE_DIR/disk-$n.gb")GB"; done
  [ -n "$d" ] && echo "Disk per runner:$d (cap ${DISK_CAP_GB:-20} GB each)"
  df -h / | awk 'NR == 2 { print "Linux disk in use: " $3 }'
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
  for n in $(names); do rm -f "$UNIT_DIR/$n.container"; rm -rf "${STATE_DIR:?}/$n"; podman rm -f "$n" >/dev/null 2>&1 || true; done
  # Another runner class on this box (ccx63-split.sh) still uses the shared network, slice, watchdog and image.
  if ls "$UNIT_DIR"/*.container >/dev/null 2>&1; then
    systemctl daemon-reload
    say "Done with $PREFIX*. Other runners on this box are left running."
    return
  fi
  rm -f "$UNIT_DIR/hw-ci.network"
  rm -f /etc/systemd/system/hw-ci.slice
  systemctl disable --now hw-watchdog.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hw-watchdog.service /etc/systemd/system/hw-watchdog.timer /usr/local/bin/hw-watchdog
  systemctl daemon-reload
  rm -rf "$STATE_DIR" "$BUILD_DIR"
  podman rmi -f "$IMAGE" >/dev/null 2>&1 || true
  say "Done. Runners named $PREFIX* that are still listed on https://github.com/organizations/$ORG/settings/actions/runners are offline; remove them there. Then delete this box in the provider console so it stops billing."
}

# Lowercase fallback (the console cannot type capitals): setup-keepcaps = setup without dropping container capabilities.
if [ "${1:-}" = setup-keepcaps ]; then DROP_CAPS=""; set -- setup; fi
# setup-plain: also no NoNewPrivileges, no pids limit, no core pinning. Only the CPU and memory caps stay. For finding out which restriction crashes dotnet.
# setup-big: only 2 runners with 8 GB each (and capabilities kept), in case 4 small ones are the problem.
if [ "${1:-}" = setup-big ]; then DROP_CAPS=""; COUNT=2; MEM=8g; RELEASE=1; set -- setup; fi
if [ "${1:-}" = setup-plain ]; then DROP_CAPS=""; NO_NEW_PRIVS=""; PLAIN=1; set -- setup; fi
case "${1:-setup}" in
  setup)    preflight; install_podman; build_image; register_all; write_units; net_check; dotnet_check; start_all; install_watchdog; sleep 20; status_all
            say "All set. Check: bash $0 status   ·   when done: bash $0 teardown, then delete the box." ;;
  status)   status_all ;;
  diagnose) diagnose ;;
  check)    need_root; MTU_FIXED=1; MTU="$(sed -n 's/^Options=mtu=//p' "$UNIT_DIR/hw-ci.network" 2>/dev/null)"; net_check; dotnet_check ;;
  stop)     need_root; stop_all ;;
  start)    need_root; start_all ;;
  teardown) teardown ;;
  watchdog-install) install_watchdog ;;
  # Frees what nothing needs any more and trims it, so a sparse WSL disk gives the space back (the Windows "shrink" runs this
  # with the runners stopped, which already threw their container layers away).
  trim)     need_root; podman container prune -f >/dev/null 2>&1 || true; podman image prune -f 2>/dev/null | wc -l | xargs -I{} echo "removed {} unused images"
            fstrim -av 2>/dev/null || true; df -h / | awk 'NR == 2 { print "Linux disk in use: " $3 }' ;;
  watchdog-log)     tail -n 40 /var/log/hw-watchdog.log 2>/dev/null || echo "(the watchdog has not needed to do anything yet)"; systemctl list-timers hw-watchdog.timer --no-pager 2>/dev/null | head -3 ;;
  *) die "unknown command '$1' (setup, status, check, diagnose, stop, start, teardown, trim, watchdog-install, watchdog-log)" ;;
esac
