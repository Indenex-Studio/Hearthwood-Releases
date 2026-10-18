# Hearthwood: CI runners on a Windows 10/11 PC, run inside a private Linux (WSL2) that this script sets up.
#
# Run everything below in a PowerShell opened with "Run as administrator".
#
#   hearthwood-windows-runners.ps1 setup                     install, register and start the runners (asks for one token)
#   hearthwood-windows-runners.ps1 status                    what is running and what each runner is doing
#   hearthwood-windows-runners.ps1 stop                      pause everything and give the memory back (they stay registered)
#   hearthwood-windows-runners.ps1 start                     resume
#   hearthwood-windows-runners.ps1 scale -Count 4            run only 4 runners (no new token needed)
#   hearthwood-windows-runners.ps1 scale -Cores 8 -MemoryGB 24    give the runners at most 8 threads and 24 GB
#   hearthwood-windows-runners.ps1 teardown                  stop and delete everything
#
# What you get: runners named friend-w1..wN (labels hetzner,friend; the last two also release) in the Indenex-Studio
# runner group "hearthwood". Setup registers as many as the PC can hold (2 threads and 4 GB each, keeping 4 threads
# and a quarter of the RAM for Windows) and starts that many. Scaling later only starts or stops them.
#
# How it is kept safe: the runners live in their own small Linux system (a WSL2 distro called HearthwoodCI) and each job
# runs in its own container inside it. Your Windows drives are NOT visible inside it (automount and interop are turned
# off), so the code the runners build cannot read your files or start Windows programs. It does use your CPU and RAM
# while a job runs, and it can reach your home network like any program on the PC. The repository is private and
# only people on the project can start jobs.
#
# Notes:
#  - .wslconfig (your WSL memory/processor limits, in your user folder) is changed to match -Cores/-MemoryGB. It applies to
#    every WSL2 distro on the PC. The original is saved as .wslconfig.hearthwood-backup and put back by teardown.
#  - Changing -Cores/-MemoryGB restarts WSL (all WSL windows close, running jobs are lost). Changing only -Count does not.
#  - The runners start when you log in to Windows (a hidden scheduled task keeps the Linux system running).
#  - Not tested on a real PC yet. If a step fails, send the red text to the person who gave you this script.
#
# Written for Windows PowerShell 5.1 and newer.
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'status', 'stop', 'start', 'scale', 'teardown')]
  [string]$Command = 'setup',
  [int]$Count = 0,        # how many runners to run (at most what setup registered)
  [int]$Cores = 0,        # threads the Linux system may use in total
  [int]$MemoryGB = 0      # GB of RAM the Linux system may use in total
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Distro   = 'HearthwoodCI'
$Dir      = 'C:\HearthwoodCI'
$Prefix   = 'friend-w'
$Label    = 'friend'
$Task     = 'HearthwoodRunnersKeepAlive'
$BoxUrl   = 'https://raw.githubusercontent.com/Indenex-Studio/Hearthwood-Releases/main/ci-box.sh'
# Mode of ci-box.sh: setup-plain = containers without the extra restrictions (the Linux VM is the safety boundary here),
# no pinning of runners to cores (so -Cores can change freely).
$BoxMode  = 'setup-plain'
$RootfsUrls = @(
  'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz',
  'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
)
$Settings = Join-Path $Dir 'settings.json'
$WslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$WslBackup = Join-Path $env:USERPROFILE '.wslconfig.hearthwood-backup'

function Say([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die([string]$m) { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a short Linux command in the runner system as root. Input (a string) goes to its standard input.
function Run-Linux([string]$Cmd, [string]$InputText = $null) {
  if ($null -ne $InputText) { $InputText | & wsl.exe -d $Distro -u root -- sh -c $Cmd }
  else { & wsl.exe -d $Distro -u root -- sh -c $Cmd }
  if ($LASTEXITCODE -ne 0) { throw "Linux command failed (exit $LASTEXITCODE): $Cmd" }
}

# Writes a text file inside the runner system (LF line endings).
function Put-File([string]$Path, [string]$Text, [bool]$Executable = $false) {
  $lf = ($Text -replace "`r`n", "`n").TrimEnd("`n") + "`n"
  Run-Linux "tr -d '\r' > $Path" $lf   # Windows PowerShell adds CR LF when piping
  if ($Executable) { Run-Linux "chmod 755 $Path" }
}

function Distro-Exists {
  $names = (& wsl.exe -l -q) -replace "`0", ''
  return ($names -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $Distro
}

function Wsl-Installed {
  try { & wsl.exe --version *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Computed-Count([int]$c, [int]$m) {
  $n = [math]::Min([math]::Floor($c / 2), [math]::Floor($m / 4))
  return [int][math]::Max(1, $n)
}

function Load-Settings {
  if (-not (Test-Path $Settings)) { Die "Not set up yet. Run: setup" }
  return (Get-Content $Settings -Raw | ConvertFrom-Json)
}
function Save-Settings($s) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  ($s | ConvertTo-Json) | Set-Content -Path $Settings -Encoding ASCII
}

# Sets memory, processors, swap and the idle timeout in [wsl2] of .wslconfig, keeping everything else.
function Set-WslConfig([int]$cores, [int]$memGB) {
  if ((Test-Path $WslConfig) -and -not (Test-Path $WslBackup)) { Copy-Item $WslConfig $WslBackup }
  $keys = @('memory', 'processors', 'swap', 'vmidletimeout')
  $out = New-Object System.Collections.Generic.List[string]
  $inWsl2 = $false; $seen = $false
  $lines = @()
  if (Test-Path $WslConfig) { $lines = Get-Content $WslConfig }
  foreach ($l in $lines) {
    if ($l -match '^\s*\[(.+)\]\s*$') {
      $inWsl2 = ($Matches[1].Trim().ToLower() -eq 'wsl2')
      $out.Add($l)
      if ($inWsl2) {
        $seen = $true
        $out.Add("memory=${memGB}GB"); $out.Add("processors=$cores"); $out.Add('swap=8GB'); $out.Add('vmIdleTimeout=-1')
      }
      continue
    }
    if ($inWsl2 -and ($l -match '^\s*([A-Za-z]+)\s*=')) {
      if ($keys -contains $Matches[1].ToLower()) { continue }
    }
    $out.Add($l)
  }
  if (-not $seen) {
    $out.Add('[wsl2]'); $out.Add("memory=${memGB}GB"); $out.Add("processors=$cores"); $out.Add('swap=8GB'); $out.Add('vmIdleTimeout=-1')
  }
  Set-Content -Path $WslConfig -Value $out -Encoding ASCII
}

function Ensure-KeepAlive {
  if (-not (Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue)) {
    $action = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "-d $Distro -u root --exec sleep infinity"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Principal $principal -Settings $set -Force | Out-Null
  }
  Enable-ScheduledTask -TaskName $Task | Out-Null
  Start-ScheduledTask -TaskName $Task
}

# Waits until Linux has finished booting (systemd up).
function Wait-Boot {
  for ($i = 0; $i -lt 60; $i++) {
    $st = (& wsl.exe -d $Distro -u root -- systemctl is-system-running 2>$null)
    if ($st -match 'running|degraded') { return }
    Start-Sleep -Seconds 2
  }
  throw 'The Linux system did not finish starting.'
}

# Writes the settings the Linux side reads (/etc/hw-runner.env) and applies the wanted runner count.
function Apply-Linux([int]$max, [int]$want, [int]$cores, [int]$memGB) {
  $capCpu = "$($cores * 100)%"
  $capMem = "$([math]::Max(2, $memGB - 2))G"
  $envText = @"
PREFIX=$Prefix
EXTRA_LABEL=$Label
RELEASE=2
COUNT=$max
WANT=$want
NO_AUTOSTART=1
TOTAL_CPU=$capCpu
TOTAL_MEM=$capMem
"@
  Put-File '/etc/hw-runner.env' $envText
  Run-Linux '/usr/local/bin/hw-scale'
}

function Install-Helpers {
  Put-File '/usr/local/bin/hwbox' @'
#!/bin/bash
# Runs ci-box.sh with this machine's runner settings.
set -a; . /etc/hw-runner.env; set +a
exec bash /root/ci-box.sh "$@"
'@ $true
  Put-File '/usr/local/bin/hw-scale' @'
#!/bin/bash
# Applies the CPU/memory caps and runs the first WANT runners, stops the rest.
. /etc/hw-runner.env
systemctl set-property --runtime hw-ci.slice CPUQuota="$TOTAL_CPU" MemoryMax="$TOTAL_MEM" 2>/dev/null || true
for i in $(seq 1 "$COUNT"); do
  u="$PREFIX$i.service"
  if [ "$i" -le "$WANT" ]; then systemctl start "$u" || true; else systemctl stop "$u" 2>/dev/null || true; fi
done
'@ $true
  Put-File '/etc/systemd/system/hw-scale.service' @'
[Unit]
Description=Start the wanted number of Hearthwood runners
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hw-scale

[Install]
WantedBy=multi-user.target
'@
}

function Do-Setup {
  if (-not (Test-Admin)) { Die 'Open PowerShell with "Run as administrator" and run this again.' }
  if ([Environment]::OSVersion.Version.Build -lt 19041) { Die 'This needs Windows 10 version 2004 (build 19041) or newer, or Windows 11.' }
  $threads = [int](Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
  $ramGB = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $defCores = [int][math]::Max(2, $threads - 4)
  $defMem = [int][math]::Floor($ramGB * 0.75)
  $useCores = $defCores; if ($Cores -gt 0) { $useCores = $Cores }
  $useMem = $defMem; if ($MemoryGB -gt 0) { $useMem = $MemoryGB }
  $max = Computed-Count $useCores $useMem
  if ($Count -gt 0) { $max = $Count }
  Say "This PC: $threads threads, $ramGB GB. The runners may use $useCores threads and $useMem GB: $max runners."

  # 1. WSL itself (a restart of Windows may be needed once)
  if (-not (Wsl-Installed)) { & wsl.exe --update 2>&1 | Out-Null }
  if (-not (Wsl-Installed)) {
    Say 'Installing WSL (Windows Subsystem for Linux)...'
    & wsl.exe --install --no-distribution
    Write-Host ''
    Write-Host 'WSL is installed. RESTART Windows now, then run the same command again.' -ForegroundColor Yellow
    return
  }

  # 2. Our own Linux system, separate from any other WSL distro on this PC
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  if (-not (Distro-Exists)) {
    $tar = Join-Path $Dir 'rootfs.tar.gz'
    $ok = $false
    foreach ($u in $RootfsUrls) {
      try { Say "Downloading Ubuntu (about 350 MB)..."; Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $tar; $ok = $true; break } catch { Write-Host "  (could not get $u)" }
    }
    if (-not $ok) { Die 'Could not download the Ubuntu image. Check the internet connection and run this again.' }
    Say 'Creating the Linux system...'
    & wsl.exe --import $Distro (Join-Path $Dir 'distro') $tar --version 2
    if ($LASTEXITCODE -ne 0) { Die 'wsl --import failed.' }
    Remove-Item $tar -Force
    Put-File '/etc/wsl.conf' @'
[boot]
systemd=true

[automount]
enabled=false

[interop]
enabled=false
appendWindowsPath=false
'@
  }

  # 3. Limits for the Linux system, then restart WSL so systemd and the limits apply
  Set-WslConfig $useCores $useMem
  Say 'Restarting WSL (any open WSL windows close)...'
  & wsl.exe --shutdown
  Start-Sleep -Seconds 3
  Ensure-KeepAlive
  Wait-Boot

  # 4. The runner script, then registration (one token for all of them)
  Say 'Installing the tools inside the Linux system...'
  Run-Linux 'apt-get update -q && apt-get install -y -q curl ca-certificates'
  Run-Linux "curl -fsSL -o /root/ci-box.sh $BoxUrl"
  $capMem = [math]::Max(2, $useMem - 2)
  Put-File '/etc/hw-runner.env' @"
PREFIX=$Prefix
EXTRA_LABEL=$Label
RELEASE=2
COUNT=$max
WANT=0
NO_AUTOSTART=1
TOTAL_CPU=$($useCores * 100)%
TOTAL_MEM=${capMem}G
"@
  Install-Helpers
  Write-Host ''
  Write-Host 'Now one thing from you:' -ForegroundColor Yellow
  Write-Host '  1. Open https://github.com/organizations/Indenex-Studio/settings/actions/runners/new  (you need to be an owner of the organization; if not, ask Justin for the token)'
  Write-Host '  2. In the "Configure" box, copy the long code after --token  (valid for 1 hour)'
  Write-Host '  3. Paste it here and press Enter (it is not shown)'
  Write-Host ''
  $sec = Read-Host 'Token' -AsSecureString
  $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
  if (-not $token) { Die 'No token given.' }
  Say "Building the runner image and registering $max runners (this takes several minutes)..."
  Run-Linux "/usr/local/bin/hwbox $BoxMode" ($token + "`n")
  $token = $null

  # 5. Run the wanted number, and again at every Windows start
  Run-Linux 'systemctl daemon-reload && systemctl enable hw-scale.service'
  Copy-Item -Path $PSCommandPath -Destination (Join-Path $Dir 'hearthwood-runners.ps1') -Force -ErrorAction SilentlyContinue
  Set-Content -Path (Join-Path $Dir 'hw.cmd') -Encoding ASCII -Value '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hearthwood-runners.ps1" %*'
  $want = $max
  Save-Settings @{ max = $max; want = $want; cores = $useCores; memGB = $useMem }
  Apply-Linux $max $want $useCores $useMem
  Start-Sleep -Seconds 15
  Do-Status
  Say "Done. Later commands (in an admin PowerShell):  $Dir\hw.cmd status  |  stop  |  start  |  scale -Count 4  |  teardown"
}

function Do-Status {
  $s = Load-Settings
  if (-not (Distro-Exists)) { Die 'The Linux system is missing. Run: setup' }
  Write-Host "Registered: $($s.max)   running (wanted): $($s.want)   threads: $($s.cores)   memory: $($s.memGB) GB"
  $run = (& wsl.exe -l --running) -replace "`0", ''
  if ($run -notmatch $Distro) { Write-Host 'The Linux system is stopped (use: start).'; return }
  Run-Linux 'hwbox status'
}

function Do-Stop {
  $s = Load-Settings
  Say 'Stopping the runners...'
  if (Distro-Exists) { try { Apply-Linux ([int]$s.max) 0 ([int]$s.cores) ([int]$s.memGB) } catch { Write-Host "  ($_)" } }
  Disable-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Out-Null
  Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
  & wsl.exe --terminate $Distro 2>&1 | Out-Null
  Say 'Stopped, and the memory is given back. It stays stopped after a restart of Windows. Resume with: start'
}

function Do-Start {
  $s = Load-Settings
  Ensure-KeepAlive
  Wait-Boot
  Apply-Linux ([int]$s.max) ([int]$s.want) ([int]$s.cores) ([int]$s.memGB)
  Start-Sleep -Seconds 10
  Do-Status
}

function Do-Scale {
  $s = Load-Settings
  $newCores = [int]$s.cores; if ($Cores -gt 0) { $newCores = $Cores }
  $newMem = [int]$s.memGB; if ($MemoryGB -gt 0) { $newMem = $MemoryGB }
  $limitsChanged = (($newCores -ne [int]$s.cores) -or ($newMem -ne [int]$s.memGB))
  $want = [int]$s.want
  if ($Count -gt 0) { $want = $Count }
  elseif ($limitsChanged) { $want = Computed-Count $newCores $newMem }
  if ($want -gt [int]$s.max) { Write-Host "Only $($s.max) runners are registered; using $($s.max). To get more, run: setup -Count $want"; $want = [int]$s.max }
  $fit = Computed-Count $newCores $newMem
  if ($want -gt $fit) { Write-Host "Note: $want runners need about $($want * 2) threads and $($want * 4) GB; you gave $newCores threads and $newMem GB, so jobs may be slow." -ForegroundColor Yellow }
  Save-Settings @{ max = [int]$s.max; want = $want; cores = $newCores; memGB = $newMem }
  if ($limitsChanged) {
    Say 'New limits: restarting WSL (any open WSL windows close, running jobs are lost)...'
    Set-WslConfig $newCores $newMem
    & wsl.exe --shutdown
    Start-Sleep -Seconds 3
    Ensure-KeepAlive
    Wait-Boot
  }
  Apply-Linux ([int]$s.max) $want $newCores $newMem
  Start-Sleep -Seconds 5
  Do-Status
}

function Do-Teardown {
  if (-not (Test-Admin)) { Die 'Open PowerShell with "Run as administrator" and run this again.' }
  $a = Read-Host 'Stop and delete the Hearthwood runners from this PC? [y/N]'
  if ($a.Trim().ToLower() -ne 'y') { return }
  if (Distro-Exists) {
    Ensure-KeepAlive
    try {
      Wait-Boot
      Write-Host 'Optional: paste a removal token so the runners also leave GitHub (Enter to skip; Justin can remove them on the runners page).'
      $sec = Read-Host 'Token' -AsSecureString
      $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
      Run-Linux '/usr/local/bin/hwbox teardown' ("y`n$tok`n")
    } catch { Write-Host "  (could not clean up inside Linux: $_)" }
  }
  Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
  if (Distro-Exists) { & wsl.exe --unregister $Distro | Out-Null }
  if (Test-Path $WslBackup) { Move-Item -Force $WslBackup $WslConfig } elseif (Test-Path $WslConfig) {
    # Remove only the lines this script wrote.
    $keep = Get-Content $WslConfig | Where-Object { $_ -notmatch '^\s*(memory|processors|swap|vmIdleTimeout)\s*=' }
    Set-Content -Path $WslConfig -Value $keep -Encoding ASCII
  }
  & wsl.exe --shutdown
  Set-Location $env:USERPROFILE
  Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
  Say 'Done. If you did not give a removal token, ask Justin to remove the offline friend-w runners on the runners page.'
}

switch ($Command) {
  'setup'    { Do-Setup }
  'status'   { Do-Status }
  'stop'     { Do-Stop }
  'start'    { Do-Start }
  'scale'    { Do-Scale }
  'teardown' { Do-Teardown }
}
