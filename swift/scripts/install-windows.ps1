# install-windows.ps1 — build/copy `dab` and register a per-user Scheduled Task (onlogon).
#
# Mirrors src/service/schtasks.ts:
#   - Task Scheduler /sc onlogon — no admin required
#   - No crash auto-restart (unlike launchd KeepAlive / systemd Restart=always)
#
# Usage (from repo root or anywhere):
#   powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1
#   powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1 -Uninstall
#
# Requires: Swift toolchain on PATH for build, or a prebuilt dab.exe at
#   swift\.build\release\dab.exe (or pass -BinaryPath).

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [string]$BinaryPath = ""
)

$ErrorActionPreference = "Stop"

$TaskName = "discord-agent-bridge"
$DabHome = Join-Path $env:USERPROFILE ".dab"
$BinDir = Join-Path $DabHome "bin"
$LogDir = Join-Path $DabHome "logs"
$EnvFile = Join-Path $DabHome "env"
$RunCmd = Join-Path $DabHome "run.cmd"
$DabExe = Join-Path $BinDir "dab.exe"
$OutLog = Join-Path $LogDir "agent.out.log"
$ErrLog = Join-Path $LogDir "agent.err.log"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$SwiftDir = Join-Path $RepoRoot "swift"
$EnvExample = Join-Path $SwiftDir "deploy\env.example"
$DefaultBuilt = Join-Path $SwiftDir ".build\release\dab.exe"

function Write-Log([string]$Message) { Write-Host $Message }

function New-RunCmd {
    param([string]$OutPath, [string]$Repo, [string]$Exe, [string]$EnvPath)
    # Minimal launcher: load KEY=VALUE lines from env (skip blanks/#), cd repo, run dab.
    # Stdout/stderr append via cmd redirection at the scheduled-task /tr level.
    $content = @"
@echo off
setlocal EnableExtensions
if exist "$EnvPath" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("$EnvPath") do (
    if not "%%A"=="" set "%%A=%%B"
  )
)
cd /d "$Repo"
"$Exe"
"@
    Set-Content -Path $OutPath -Value $content -Encoding ASCII
}

if ($Uninstall) {
    Write-Log "== uninstall Scheduled Task $TaskName =="
    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
    if (Test-Path $BinDir) { Remove-Item -Recurse -Force $BinDir }
    if (Test-Path $RunCmd) { Remove-Item -Force $RunCmd }
    Write-Log "uninstalled: task + bin + run.cmd removed."
    Write-Log "kept: $EnvFile (secrets) and $LogDir (history)."
    exit 0
}

if ($DryRun) {
    Write-Log "== dry-run: plan only, no build, no schtasks =="
    Write-Log "  task name:  $TaskName"
    Write-Log "  dab home:   $DabHome"
    Write-Log "  run.cmd:    $RunCmd"
    Write-Log "  binary:     $DabExe"
    Write-Log "  repo root:  $RepoRoot"
    Write-Log "  trigger:    onlogon (no crash auto-restart — same as TS schtasks)"
    Write-Log "dry-run OK"
    exit 0
}

Write-Log "== prepare $DabHome =="
New-Item -ItemType Directory -Force -Path $BinDir, $LogDir | Out-Null

if (-not (Test-Path $EnvFile)) {
    if (Test-Path $EnvExample) {
        Copy-Item $EnvExample $EnvFile
        Write-Log "  created $EnvFile — fill in DISCORD_BOT_TOKEN and DAB_* before login works"
    } else {
        Set-Content -Path $EnvFile -Value "DISCORD_BOT_TOKEN=`r`n" -Encoding ASCII
        Write-Log "  created empty $EnvFile — set DISCORD_BOT_TOKEN"
    }
} else {
    Write-Log "  kept existing $EnvFile"
}

$src = if ($BinaryPath) { $BinaryPath } else { $DefaultBuilt }
if (-not (Test-Path $src)) {
    Write-Log "== build (release) =="
    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
        Write-Log "FATAL: swift not on PATH and no binary at $src"
        Write-Log "  Install Swift for Windows, or pass -BinaryPath path\to\dab.exe"
        exit 1
    }
    & swift build -c release --package-path $SwiftDir
    if (-not (Test-Path $DefaultBuilt)) {
        # Some toolchains name the product without .exe in the path probe; accept either.
        $alt = Join-Path $SwiftDir ".build\release\dab"
        if (Test-Path $alt) { $src = $alt } else {
            Write-Log "FATAL: build produced no dab binary under .build/release"
            exit 1
        }
    } else {
        $src = $DefaultBuilt
    }
}

Copy-Item -Force $src $DabExe
New-RunCmd -OutPath $RunCmd -Repo $RepoRoot -Exe $DabExe -EnvPath $EnvFile

# /tr: run.cmd with stdout/stderr append (cmd.exe). Quoted for spaces in USERPROFILE.
$tr = "cmd /c `"`"$RunCmd`" >> `"$OutLog`" 2>> `"$ErrLog`"`""
Write-Log "== register Scheduled Task $TaskName (onlogon) =="
$create = & schtasks /Create /TN $TaskName /SC ONLOGON /TR $tr /F
if ($LASTEXITCODE -ne 0) {
    Write-Log "FATAL: schtasks /Create failed (exit $LASTEXITCODE)"
    if ($create) { Write-Log "  $create" }
    exit 1
}

Write-Log "installed: runs at user logon via Task Scheduler."
Write-Log "  task:    $TaskName"
Write-Log "  run:     $RunCmd -> $DabExe"
Write-Log "  logs:    $OutLog"
Write-Log "           $ErrLog"
Write-Log "  secrets: $EnvFile"
Write-Log "  note: onlogon does NOT auto-restart on crash (same as TS schtasks)."
Write-Log "  start now: schtasks /Run /TN $TaskName"
Write-Log "  remove:    powershell -File $($MyInvocation.MyCommand.Path) -Uninstall"
