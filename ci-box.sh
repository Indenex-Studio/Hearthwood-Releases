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
# .NET settings found by dotnet_autofix on this box, kept for later runs (only DOTNET_* settings, no security changes).
FIX_ENV=""
[ -f /var/lib/hw-ci/dotnet-fix ] && . /var/lib/hw-ci/dotnet-fix
# NO_AUTOSTART=1: the runner units do not start at boot by themselves (the Windows setup starts the wanted number).
INSTALL_SECTION=$'[Install]\nWantedBy=multi-user.target'; [ "${NO_AUTOSTART:-0}" = 1 ] && INSTALL_SECTION=""
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
release_names() { local i; for i in $(seq $((COUNT - RELEASE + 1)) "$COUNT"); do [ "$i" -ge 1 ] && echo "$PREFIX$i"; done; }
labels_for() { local l=hetzner; release_names | grep -qx "$1" && l="$l,release"; [ -n "$EXTRA_LABEL" ] && l="$l,$EXTRA_LABEL"; echo "$l"; }
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
# What the Hearthwood CI jobs expect: git, curl, jq, zip, python3, flock/timeout (util-linux, coreutils). zstd: without
# it actions/cache falls back to gzip, and caches saved by the other runners (zstd) are not found.
# .NET, Godot and the SpacetimeDB CLI install themselves into the runner's home.
# Godot (headless exports and the key check) needs the libraries below; Mesa gives it software rendering.
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      ca-certificates curl git jq unzip zip xz-utils zstd python3 tzdata util-linux \
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
$(for e in $FIX_ENV; do echo "Environment=$e"; done)
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
  local e; for e in $FIX_ENV; do a+=(-e "$e"); done
  [ -n "${CHECK_MOUNT:-}" ] && a+=(-v "$CHECK_MOUNT")
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
    || { dotnet_autofix; return; }
  say "Module build check passed."
}
# The module build crashed in the runner container. Tries .NET's own CPU-feature settings one at a time (each must
# build twice in a row, with the runner's normal limits and restrictions), keeps the first that works for every runner
# on this box (/var/lib/hw-ci/dotnet-fix), and rewrites the services with it. .NET is downloaded once.
dotnet_autofix() {
  say ".NET crashed. Trying .NET's CPU-feature settings (about 2 minutes each)…"
  local C=/var/cache/hwcheck
  if [ ! -x "$C/dn/dotnet" ] || [ ! -x "$C/spacetimedb-cli" ]; then
    rm -rf "$C"; mkdir -p "$C"
    $DL -o "$C/di.sh" https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.sh
    bash "$C/di.sh" --channel 8.0 --install-dir "$C/dn" >/dev/null
    $DL https://github.com/clockworklabs/SpacetimeDB/releases/download/v2.12.0/spacetime-x86_64-unknown-linux-gnu.tar.gz | tar xz -C "$C"
  fi
  chmod -R a+rX "$C"
  local T='set -e; W=$(mktemp -d); cp -a /hwc/dn /hwc/spacetimedb-cli /hwc/spacetimedb-standalone $W/; cd $W; export HOME=$W DOTNET_ROOT=$W/dn PATH=$W/dn:$W:$PATH DOTNET_NOLOGO=1
    spacetimedb-cli init --lang csharp --server-only --non-interactive --dotnet-version 8 --project-path $W/m hwcheck >/dev/null
    spacetimedb-cli build -p $W/m/spacetimedb >$W/b.log 2>&1 || { grep -m1 -iE "exited with code|signal" $W/b.log | cut -c1-150; exit 1; }
    test -s $W/m/spacetimedb/bin/Release/net8.0/wasi-wasm/AppBundle/StdbModule.wasm'
  local tries=(
    "DOTNET_EnableAVX512F=0"
    "DOTNET_EnableAVX512F=0 DOTNET_TieredPGO=0"
    "DOTNET_EnableAVX512F=0 DOTNET_EnableAVX2=0"
    "DOTNET_EnableAVX512F=0 DOTNET_EnableAVX2=0 DOTNET_TieredPGO=0 DOTNET_TieredCompilation=0"
  )
  local env ok k
  for env in "${tries[@]}"; do
    ok=1
    for k in 1 2; do
      FIX_ENV="$env" CHECK_MOUNT="$C:/hwc:ro" in_runner "$T" >/tmp/hwfix.log 2>&1 || { ok=0; break; }
    done
    if [ "$ok" = 1 ]; then
      say "Works with: $env. Using it for every runner on this box."
      FIX_ENV="$env"; printf 'FIX_ENV="%s"\n' "$FIX_ENV" >/var/lib/hw-ci/dotnet-fix
      write_units
      return 0
    fi
    echo "  still crashes with $env ($(tail -1 /tmp/hwfix.log | cut -c1-120))"
  done
  lscpu | grep -m1 'Model name'
  die "none of .NET's settings stopped the crash, so the runners were NOT started (they would only fail jobs). Run: bash $0 diagnose   and send both outputs to Justin."
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

# After "diagnose" passes but the runners still crash: adds the real runners' extra settings one at a time (each
# build runs twice, since the crash comes and goes), then all together. Uses the copy "diagnose" downloaded.
diagnose2() {
  need_root
  local C=/var/cache/hwcheck
  [ -x "$C/dn/dotnet" ] || die "run: bash $0 diagnose   first (it downloads .NET once)."
  local T='set -e; W=$(mktemp -d); cp -a /hwc/dn /hwc/spacetimedb-cli /hwc/spacetimedb-standalone $W/; cd $W; export HOME=$W DOTNET_ROOT=$W/dn PATH=$W/dn:$W:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
    spacetimedb-cli init --lang csharp --server-only --non-interactive --dotnet-version 8 --project-path $W/m hwcheck >/dev/null
    spacetimedb-cli build -p $W/m/spacetimedb >$W/b.log 2>&1 || { tail -3 $W/b.log; exit 1; }
    test -s $W/m/spacetimedb/bin/Release/net8.0/wasi-wasm/AppBundle/StdbModule.wasm'
  systemctl start hw-ci-network.service >/dev/null 2>&1 || true
  local base=(--rm -v "$C:/hwc:ro" --user runner --cpus="$CPUS" --memory="$MEM")
  local net=(--network "$NET" --sysctl=net.ipv6.conf.all.disable_ipv6=1) caps=(--cap-drop=all) nnp=(--security-opt=no-new-privileges)
  local envs=(-e DOTNET_EnableWriteXorExecute=0 -e DOTNET_gcServer=0)
  try2() { local name="$1" k r="PASS"; shift
    for k in 1 2; do podman run "$@" --entrypoint /bin/bash "$IMAGE" -c "$T" >/tmp/hwdiag.log 2>&1 || { r="FAIL"; break; }; done
    echo "  $r  $name$( [ "$r" = FAIL ] && echo ": $(grep -m1 -iE 'signal|exited with code' /tmp/hwdiag.log | cut -c1-100)")"; }
  say "Adding the runners' settings one at a time (two builds each, about 10 minutes in all)…"
  try2 "runner network"                       "${base[@]}" "${net[@]}"
  try2 "capabilities dropped"                 "${base[@]}" "${caps[@]}"
  try2 "no-new-privileges"                    "${base[@]}" "${nnp[@]}"
  try2 ".NET settings (W^X off, workstation GC)" "${base[@]}" "${envs[@]}"
  try2 "all of them, like a real runner"      "${base[@]}" "${net[@]}" "${caps[@]}" "${nnp[@]}" "${envs[@]}"
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
  diagnose2) diagnose2 ;;
  check)    need_root; MTU_FIXED=1; MTU="$(sed -n 's/^Options=mtu=//p' "$UNIT_DIR/hw-ci.network" 2>/dev/null)"; net_check; dotnet_check ;;
  stop)     need_root; stop_all ;;
  start)    need_root; start_all ;;
  teardown) teardown ;;
  watchdog-install) install_watchdog ;;
  watchdog-log)     tail -n 40 /var/log/hw-watchdog.log 2>/dev/null || echo "(the watchdog has not needed to do anything yet)"; systemctl list-timers hw-watchdog.timer --no-pager 2>/dev/null | head -3 ;;
  *) die "unknown command '$1' (setup, status, check, diagnose, diagnose2, stop, start, teardown, watchdog-install, watchdog-log)" ;;
esac
