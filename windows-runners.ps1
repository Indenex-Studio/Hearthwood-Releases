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
#   hearthwood-windows-runners.ps1 update                    bring a PC that is already set up up to date (adds the watchdog; no token needed)
#   hearthwood-windows-runners.ps1 watchdog                  what the watchdog restarted lately
#   hearthwood-windows-runners.ps1 shrink                    give the runners' unused disk space back to Windows (update does it too)
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
#  - Disk: the Linux system lives in one file, C:\HearthwoodCI\distro\ext4.vhdx. Each runner's leftovers are capped at
#    DISK_CAP_GB (20 GB) and cleared between jobs. The file on C: only gets smaller when the disk is "sparse" (setup and
#    update turn that on where this Windows allows it) or after "shrink", which stops the runners for a few minutes.
#  - Not tested on a real PC yet. If a step fails, send the red text to the person who gave you this script.
#
# Written for Windows PowerShell 5.1 and newer.
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'finish', 'status', 'stop', 'start', 'scale', 'update', 'watchdog', 'shrink', 'teardown')]
  [string]$Command = 'setup',
  [int]$Count = 0,        # how many runners to run (at most what setup registered)
  [int]$Cores = 0,        # threads the Linux system may use in total
  [int]$MemoryGB = 0      # GB of RAM the Linux system may use in total
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Everything this script prints is also written to %USERPROFILE%\hearthwood-runners.log, so a closed window
# still leaves the error behind. Send that file to the person who gave you this script.
$LogFile = Join-Path $env:USERPROFILE 'hearthwood-runners.log'
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch { }

$Distro   = 'HearthwoodCI'
$Dir      = 'C:\HearthwoodCI'
$Prefix   = 'friend-w'
$Label    = 'friend'
$Task     = 'HearthwoodRunnersKeepAlive'
$BoxUrl   = 'https://raw.githubusercontent.com/Indenex-Studio/Hearthwood-Releases/main/ci-box.sh'
$SelfUrl  = 'https://raw.githubusercontent.com/Indenex-Studio/Hearthwood-Releases/main/windows-runners.ps1'
# Mode of ci-box.sh: setup-plain = containers without the extra restrictions (the Linux VM is the safety boundary here),
# no pinning of runners to cores (so -Cores can change freely).
$BoxMode  = 'setup-plain'
$RootfsUrls = @(
  'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz',
  'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
)
$Settings = Join-Path $Dir 'settings.json'
$Vhdx     = Join-Path $Dir 'distro\ext4.vhdx'
$DiskCapGB = 20   # an idle runner whose leftovers pass this is given a clean container (the Linux watchdog does it)
$WslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$WslBackup = Join-Path $env:USERPROFILE '.wslconfig.hearthwood-backup'

function Say([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
# Die throws instead of calling exit: exit would close the window when the script runs from a right-click or
# iex, and the message would vanish with it. The catch at the end of the script shows it and waits for Enter.
function Die([string]$m) { throw [System.InvalidOperationException]::new($m) }
function Wait-Enter {
  try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
}

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
DISK_CAP_GB=$DiskCapGB
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
  if (-not (Wsl-Installed)) { try { & wsl.exe --update 2>&1 | Out-Null } catch { } }
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
    # Each address gets two tries. A download counts only if the file is a gzip of a plausible size (the image is
    # about 350 MB) and, when the server says how big it is, exactly that size.
    foreach ($u in $RootfsUrls) {
      for ($try = 1; $try -le 2 -and -not $ok; $try++) {
        try {
          Say "Downloading Ubuntu (about 350 MB), try $try of 2 from $(([Uri]$u).Host)..."
          if (Test-Path $tar) { Remove-Item $tar -Force }
          $want = 0
          try { $want = [long](Invoke-WebRequest -UseBasicParsing -Method Head -Uri $u).Headers['Content-Length'] } catch { }
          Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $tar
          $have = (Get-Item $tar).Length
          $fs = [IO.File]::OpenRead($tar); $head = New-Object byte[] 2; [void]$fs.Read($head, 0, 2); $fs.Close()
          if ($have -lt 150MB) { throw "the file is only $([math]::Round($have / 1MB)) MB" }
          if ($want -gt 0 -and $have -ne $want) { throw "got $have bytes, expected $want" }
          if ($head[0] -ne 0x1f -or $head[1] -ne 0x8b) { throw 'the file is not a gzip archive' }
          $ok = $true
        } catch {
          Write-Host "  (download failed: $($_.Exception.Message))" -ForegroundColor Yellow
          Start-Sleep -Seconds 3
        }
      }
      if ($ok) { break }
    }
    if (-not $ok) { Die "Could not download the Ubuntu image from either address. Check the internet connection (and free disk space on C:), then run this again. Log: $LogFile" }
    Say 'Creating the Linux system...'
    & wsl.exe --import $Distro (Join-Path $Dir 'distro') $tar --version 2
    if ($LASTEXITCODE -ne 0) { Die "wsl --import failed (exit $LASTEXITCODE). If the text above mentions virtualization or 0x80370102, turn on virtualization (SVM/VT-x) in the BIOS; if it mentions a missing feature, restart Windows and run this again. Log: $LogFile" }
    Remove-Item $tar -Force
    [void](Set-Sparse)
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
DISK_CAP_GB=$DiskCapGB
"@
  Install-Helpers
  Write-Host ''
  Write-Host 'Now one thing from you:' -ForegroundColor Yellow
  Write-Host '  1. Open https://github.com/organizations/Indenex-Studio/settings/actions/runners/new  (you need to be an owner of the organization; if not, ask Justin for the token)'
  Write-Host '  2. In the "Configure" box, copy the long code after --token  (valid for 1 hour)'
  Write-Host '  3. Paste it here and press Enter (it is not shown). Running setup again with everything registered? Just press Enter.'
  Write-Host ''
  $sec = Read-Host 'Token' -AsSecureString
  $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
  # An empty token is fine when every runner is already registered (running setup again); ci-box.sh says if one is needed.
  Say "Building the runner image and registering $max runners (this takes several minutes)..."
  Run-Linux "/usr/local/bin/hwbox $BoxMode" ($token + "`n")
  $token = $null

  Finish-Setup $max $useCores $useMem
}

# --- Watchdog: restarts runners that sit "Idle" with a dead connection (after Windows sleep, a WSL pause or a network blip) ---
# Two parts. Inside Linux, hw-watchdog.timer (every 2 minutes, from ci-box.sh) restarts an idle runner whose listener is gone,
# or that woke up from sleep / got its network back, and never touches a runner that is running a job. On Windows, a hidden
# scheduled task (HearthwoodRunnersWatchdog, every 2 minutes) restarts the Linux system and its keep-alive if they stopped,
# and after Windows slept it fixes the Linux clock and tells the Linux watchdog. Sleep on mains power is turned off.
$WinTask = 'HearthwoodRunnersWatchdog'

function Install-LinuxWatchdog {
  Say 'Installing the runner watchdog inside Linux...'
  Run-Linux '/usr/local/bin/hwbox watchdog-install'
}

function Install-WinWatchdog {
  Say 'Installing the Windows watchdog (a hidden task every 2 minutes)...'
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $script = (@'
$ErrorActionPreference = 'SilentlyContinue'
$Distro = '__DISTRO__'; $Dir = '__DIR__'; $KeepTask = '__KEEP__'
$log = Join-Path $Dir 'watchdog.log'
function Log([string]$m) {
  Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  if ((Get-Item $log).Length -gt 1MB) { Get-Content $log -Tail 500 | Set-Content "$log.tmp"; Move-Item -Force "$log.tmp" $log }
}
$keep = Get-ScheduledTask -TaskName $KeepTask
if (-not $keep -or $keep.State -eq 'Disabled') { exit 0 }   # stopped on purpose (the stop command)
$tickFile = Join-Path $Dir 'watchdog.tick'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$last = $now; if (Test-Path $tickFile) { $last = [long](Get-Content $tickFile -Raw) }
Set-Content -Path $tickFile -Value $now
$woke = ($now - $last) -gt 300     # this task runs every 2 minutes, so a bigger gap means Windows slept
$running = ((& wsl.exe -l --running -q) -replace "`0", '') -join "`n"
if (($running -notmatch $Distro) -or ($keep.State -ne 'Running')) {
  Log 'the Linux system or its keep-alive was not running; starting it'
  Start-ScheduledTask -TaskName $KeepTask
  for ($i = 0; $i -lt 60; $i++) {
    $st = (& wsl.exe -d $Distro -u root -- systemctl is-system-running 2>$null)
    if ($st -match 'running|degraded') { break }
    Start-Sleep -Seconds 2
  }
  & wsl.exe -d $Distro -u root -- /usr/local/bin/hw-scale
  $woke = $true
}
if ($woke) {
  Log "Windows was asleep or paused ($($now - $last) s); syncing the Linux clock and telling the runners"
  & wsl.exe -d $Distro -u root -- sh -c 'hwclock -s 2>/dev/null; mkdir -p /var/lib/hw-ci; touch /var/lib/hw-ci/watchdog.refresh; systemctl start hw-watchdog.service'
}
'@).Replace('__DISTRO__', $Distro).Replace('__DIR__', $Dir).Replace('__KEEP__', $Task)
  Set-Content -Path (Join-Path $Dir 'watchdog.ps1') -Value $script -Encoding ASCII
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $Dir 'watchdog.ps1')`""
  $every = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
  $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -Hidden
  Register-ScheduledTask -TaskName $WinTask -Action $action -Trigger @($every, $logon) -Principal $principal -Settings $set -Force | Out-Null
  Enable-ScheduledTask -TaskName $WinTask | Out-Null
  # Windows must not sleep while the runners are meant to work (on mains power; on battery it may). Closing a laptop lid does nothing while plugged in.
  & powercfg.exe /change standby-timeout-ac 0 | Out-Null
  & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
  & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
  Say 'Windows will not sleep or hibernate on mains power now (the screen may still switch off).'
}

# Brings an already set-up PC up to date with this script: the new ci-box.sh (with the watchdog), then both watchdogs.
function Do-Update {
  if (-not (Test-Admin)) { Die 'Open PowerShell with "Run as administrator" and run this again.' }
  $s = Load-Settings
  if (-not (Distro-Exists)) { Die 'The Linux system is missing. Run: setup' }
  Ensure-KeepAlive
  Wait-Boot
  Say 'Fetching the latest runner script into Linux...'
  Run-Linux "curl -fsSL -o /root/ci-box.sh $BoxUrl"
  # Keep a copy of THIS file next to hw.cmd, as setup does.
  $self = Join-Path $Dir 'hearthwood-runners.ps1'
  if (-not $PSCommandPath) { Die 'Run this script from a saved .ps1 file (not pasted), so it can keep a copy of itself.' }
  if ((Resolve-Path $PSCommandPath).Path -ne $self) { Copy-Item -Force $PSCommandPath $self }
  Install-LinuxWatchdog
  Install-WinWatchdog
  Do-Shrink
  Say "Updated. The watchdog's log:  $Dir\hw.cmd watchdog"
}

# --- Disk: give the space the runners no longer use back to Windows ---
# WSL keeps the Linux disk in one growing file (ext4.vhdx) that does not shrink by itself when Linux deletes files. A "sparse"
# file does (after a trim, which the Linux watchdog runs); otherwise only compacting it with the Linux system stopped does.
function GB-Of([string]$f) { if (Test-Path $f) { return [math]::Round((Get-Item $f).Length / 1GB, 1) } return 0 }

# Turns on sparse for the Linux disk, so freed space goes back to Windows by itself. The Linux system must be stopped.
# Older WSL versions do not have it, and newer ones may refuse it as unsafe: then nothing changes and "shrink" still works.
function Set-Sparse {
  $ErrorActionPreference = 'Continue'   # Windows PowerShell turns a native program's error text into a stop otherwise
  $out = (& wsl.exe --manage $Distro --set-sparse true 2>&1 | Out-String) -replace "`0", ''
  if ($LASTEXITCODE -eq 0) { Say 'The Linux disk now gives freed space back to Windows by itself.'; return $true }
  Write-Host "  (this WSL does not make the disk give space back by itself: $($out.Trim()). Run shrink now and then instead.)" -ForegroundColor Yellow
  return $false
}

function Do-Shrink {
  if (-not (Test-Admin)) { Die 'Open PowerShell with "Run as administrator" and run this again.' }
  $s = Load-Settings
  if (-not (Distro-Exists)) { Die 'The Linux system is missing. Run: setup' }
  if (-not (Test-Path $Vhdx)) { Die "Could not find the Linux disk at $Vhdx." }
  $before = GB-Of $Vhdx
  Say "The Linux disk uses $before GB on C:. Stopping the runners for a few minutes to shrink it (a job running now is cut off; GitHub shows it as failed and it can be run again)."
  Write-Host '  Any other open WSL windows on this PC close too.' -ForegroundColor Yellow
  # Stopping a runner removes its container, and with it everything its jobs left behind.
  Ensure-KeepAlive
  Wait-Boot
  Apply-Linux ([int]$s.max) 0 ([int]$s.cores) ([int]$s.memGB)
  Run-Linux '/usr/local/bin/hwbox trim'
  # Keep the watchdogs from starting it again while the disk is worked on.
  Disable-ScheduledTask -TaskName $WinTask -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Out-Null
  Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
  try {
    & wsl.exe --shutdown
    Start-Sleep -Seconds 5
    [void](Set-Sparse)
    Say 'Compacting the Linux disk (can take several minutes on a big disk)...'
    $dp = Join-Path $Dir 'compact.txt'
    Set-Content -Path $dp -Encoding ASCII -Value @("select vdisk file=`"$Vhdx`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk')
    $out = & diskpart.exe /s $dp | Out-String
    Remove-Item $dp -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  (compacting did not finish: $($out.Trim()))" -ForegroundColor Yellow
      # Never leave it attached to Windows, or the Linux system cannot start.
      Set-Content -Path $dp -Encoding ASCII -Value @("select vdisk file=`"$Vhdx`"", 'detach vdisk')
      & diskpart.exe /s $dp *> $null
      Remove-Item $dp -Force -ErrorAction SilentlyContinue
    }
  } finally {
    Enable-ScheduledTask -TaskName $WinTask -ErrorAction SilentlyContinue | Out-Null
    Ensure-KeepAlive
    Wait-Boot
    Apply-Linux ([int]$s.max) ([int]$s.want) ([int]$s.cores) ([int]$s.memGB)
  }
  $after = GB-Of $Vhdx
  Say "The Linux disk went from $before GB to $after GB on C:. The runners are running again."
  Start-Sleep -Seconds 5
  Do-Status
}

function Do-WatchdogLog {
  Write-Host '--- Windows side (C:\HearthwoodCI\watchdog.log) ---'
  $w = Join-Path $Dir 'watchdog.log'
  if (Test-Path $w) { Get-Content $w -Tail 20 } else { Write-Host '(nothing yet: it only writes when it has to act)' }
  Write-Host '--- Linux side ---'
  Run-Linux '/usr/local/bin/hwbox watchdog-log'
}

# Step 5 of setup: run the wanted number now and at every Windows start, and leave hw.cmd for later commands.
function Finish-Setup([int]$max, [int]$useCores, [int]$useMem) {
  # 5. Run the wanted number, and again at every Windows start
  Run-Linux 'systemctl daemon-reload && systemctl enable hw-scale.service'
  # Keep a copy of this script next to hw.cmd (downloaded again, since $PSCommandPath can be empty).
  Invoke-WebRequest -UseBasicParsing -Uri $SelfUrl -OutFile (Join-Path $Dir 'hearthwood-runners.ps1')
  Set-Content -Path (Join-Path $Dir 'hw.cmd') -Encoding ASCII -Value '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hearthwood-runners.ps1" %*'
  $want = $max
  Save-Settings @{ max = $max; want = $want; cores = $useCores; memGB = $useMem }
  Apply-Linux $max $want $useCores $useMem
  Install-LinuxWatchdog
  Install-WinWatchdog
  Start-Sleep -Seconds 15
  Do-Status
  Say "Done. Later commands (in an admin PowerShell):  $Dir\hw.cmd status  |  stop  |  start  |  scale -Count 4  |  teardown"
}

# Finishes a setup that stopped after registering (no new token, no WSL restart, running jobs keep going).
function Do-Finish {
  if (-not (Test-Admin)) { Die 'Open PowerShell with "Run as administrator" and run this again.' }
  if (-not (Distro-Exists)) { Die 'The Linux system is missing. Run: setup' }
  $threads = [int](Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
  $ramGB = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $useCores = [int][math]::Max(2, $threads - 4); if ($Cores -gt 0) { $useCores = $Cores }
  $useMem = [int][math]::Floor($ramGB * 0.75); if ($MemoryGB -gt 0) { $useMem = $MemoryGB }
  $max = [int]((& wsl.exe -d $Distro -u root -- sh -c '. /etc/hw-runner.env; echo $COUNT') | Select-Object -Last 1)
  if ($max -lt 1) { Die 'No runners are registered yet. Run: setup' }
  Finish-Setup $max $useCores $useMem
}

function Do-Status {
  $s = Load-Settings
  if (-not (Distro-Exists)) { Die 'The Linux system is missing. Run: setup' }
  Write-Host "Registered: $($s.max)   running (wanted): $($s.want)   threads: $($s.cores)   memory: $($s.memGB) GB"
  # Join the lines first: -notmatch on an array filters it instead of answering true/false.
  $run = ((& wsl.exe -l --running -q) -replace "`0", '') -join "`n"
  if ($run -notmatch $Distro) { Write-Host 'The Linux system is stopped (use: start).'; return }
  Run-Linux 'hwbox status'
}

function Do-Stop {
  $s = Load-Settings
  Say 'Stopping the runners...'
  if (Distro-Exists) { try { Apply-Linux ([int]$s.max) 0 ([int]$s.cores) ([int]$s.memGB) } catch { Write-Host "  ($_)" } }
  Disable-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName $WinTask -ErrorAction SilentlyContinue | Out-Null
  Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
  & wsl.exe --terminate $Distro 2>&1 | Out-Null
  Say 'Stopped, and the memory is given back. It stays stopped after a restart of Windows. Resume with: start'
}

function Do-Start {
  $s = Load-Settings
  Enable-ScheduledTask -TaskName $WinTask -ErrorAction SilentlyContinue | Out-Null
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
  Unregister-ScheduledTask -TaskName $WinTask -Confirm:$false -ErrorAction SilentlyContinue
  & powercfg.exe /change standby-timeout-ac 30 | Out-Null   # setup turned sleep on mains power off; back to 30 minutes
  & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null
  & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
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

$waitAtEnd = $false
try {
  switch ($Command) {
    'setup'    { Do-Setup }
    'finish'   { Do-Finish }
    'status'   { Do-Status }
    'stop'     { Do-Stop }
    'start'    { Do-Start }
    'scale'    { Do-Scale }
    'update'   { Do-Update }
    'watchdog' { Do-WatchdogLog }
    'shrink'   { Do-Shrink }
    'teardown' { Do-Teardown }
  }
  Write-Host ''
  Say "Finished. A copy of everything above is in $LogFile"
  if (@('setup', 'finish', 'update', 'shrink', 'teardown') -contains $Command) { $waitAtEnd = $true }
} catch {
  $waitAtEnd = $true
  Write-Host ''
  Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.Exception -isnot [System.InvalidOperationException]) {
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
  }
  Write-Host "The whole output is in $LogFile. Send that file to the person who gave you this script." -ForegroundColor Yellow
} finally {
  try { Stop-Transcript | Out-Null } catch { }
}
if ($waitAtEnd) { Wait-Enter }
