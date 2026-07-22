#!/usr/bin/env pwsh
<#
.SYNOPSIS
  synthetic-o2-agent installer — Windows Service, native binary (no Docker).

  Windows counterpart to install.sh (which is bash-only and can't run here).
  Same agent, same flag shape, same identity model — see install.sh's header
  comment for the full design notes; this only documents what differs.

  Public mirror — this is the fetchable copy. Source of truth for the agent
  binary is the (private) synthetic-o2-agent repo; this file is mirrored here
  because it has to be fetchable without auth, same reason install.sh and
  other OpenObserve component installers live in this repo (see k8s/install.sh).
  Release binaries (see scripts/build-release-binaries.sh in the source repo)
  are published here too, same reason.

  Config is written once as a flat KEY=VALUE file under %ProgramData%
  (%ProgramData%\OpenObserve\synthetics-agent\<service>.env) — the service
  reads it via AGENT_CONFIG_FILE at every start, so editing the file and
  running `Restart-Service <name>` applies a change with no reinstall.

.EXAMPLE
  irm https://raw.githubusercontent.com/openobserve/o2-datasource/main/synthetics/install.ps1 | iex
  # or, to pass parameters, download first:
  .\install.ps1 -O2Url https://o2.example.com -Org my-org -Token o2syn_xxx -Location "Corp HQ"
#>
param(
  [Parameter(Mandatory = $true)] [string] $O2Url,
  [Parameter(Mandatory = $true)] [string] $Org,
  [Parameter(Mandatory = $true)] [string] $Token,
  [string] $Location = "",
  [string] $LocationId = "",
  [string] $Region = "",
  [string] $AgentName = "",
  [string] $Version = "",
  [string] $LeaseMax = ""
)

$ErrorActionPreference = "Stop"

$BinaryReleasesRepo = "openobserve/o2-datasource"
$BinaryName = "synthetic-o2-agent"

function Fail($msg) {
  Write-Error "install.ps1: error: $msg"
  exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail "install.ps1 registers a Windows Service and writes to Program Files — run PowerShell as Administrator"
}

if (-not $Token.StartsWith("o2syn_")) {
  Fail "-Token must be an o2syn_ Job API token (not an ingest token)"
}
if ([string]::IsNullOrEmpty($Location) -and [string]::IsNullOrEmpty($LocationId)) {
  Fail "-Location `"<name>`" or -LocationId <id> is required"
}
if (-not [string]::IsNullOrEmpty($Location) -and -not [string]::IsNullOrEmpty($LocationId)) {
  Fail "-Location and -LocationId are mutually exclusive"
}
$O2Url = $O2Url.TrimEnd("/")

function Slugify([string]$s) {
  ($s.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}

# Stable agent identity (see install.sh / design D9): the server keys agents
# by (org, location, name), so the name must not change across restarts —
# never rely on a machine's random hostname alone without slugifying it.
if ([string]::IsNullOrEmpty($AgentName)) {
  $hostShort = $env:COMPUTERNAME
  if (-not [string]::IsNullOrEmpty($Location)) {
    $AgentName = "$(Slugify $Location)-$(Slugify $hostShort)"
  } else {
    $AgentName = "agent-$(Slugify $hostShort)"
  }
}

# Same naming convention as install.sh's CONTAINER_NAME / unit name — an
# admin who knows the docker/systemd naming recognizes this immediately.
$ServiceName = "synthetic-o2-agent-$(Slugify $AgentName)"
$InstallDir = "$env:ProgramFiles\OpenObserve\synthetics-agent"
$BinPath = "$InstallDir\$BinaryName.exe"

# Config lives under %ProgramData%, not %USERPROFILE%\.config — there's no
# real ~/.config equivalent for a Windows Service: it runs as LocalSystem by
# default, whose profile is the hidden systemprofile, not any admin's own
# profile. %ProgramData% is the actual Windows analog of "machine-owned app
# config, not tied to a login session" (see install.sh's $STATE_DIR comment
# for the Linux/Docker side of this same design).
$ConfigDir = "$env:ProgramData\OpenObserve\synthetics-agent"
$ConfigPath = "$ConfigDir\$ServiceName.env"

function Resolve-AgentTag {
  if (-not [string]::IsNullOrEmpty($Version)) {
    return "synthetics-agent-$Version"
  }
  # Not GitHub's generic /releases/latest — o2-datasource may host other
  # products' releases too, so "latest" there isn't necessarily ours.
  $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$BinaryReleasesRepo/releases"
  $tag = $releases | Where-Object { $_.tag_name -like "synthetics-agent-v*" } | Select-Object -First 1 -ExpandProperty tag_name
  if ([string]::IsNullOrEmpty($tag)) {
    Fail "could not resolve a synthetics-agent release tag (pass -Version to pin one explicitly)"
  }
  return $tag
}

$tag = Resolve-AgentTag
$asset = "$BinaryName-windows-amd64.exe"
$baseUrl = "https://github.com/$BinaryReleasesRepo/releases/download/$tag"

Write-Host "==> Downloading $asset ($tag)"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$tmp = Join-Path $env:TEMP "$BinaryName-$([guid]::NewGuid()).exe"
Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile $tmp

try {
  $sha256Url = "$baseUrl/$asset.sha256"
  $expected = (Invoke-WebRequest -Uri $sha256Url -ErrorAction SilentlyContinue).Content
  if ($expected) {
    Write-Host "==> Verifying checksum"
    $expectedHash = ($expected -split '\s+')[0].Trim().ToLower()
    $actualHash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
    if ($expectedHash -ne $actualHash) {
      Fail "checksum verification failed for $asset"
    }
  } else {
    Write-Host "==> No checksum asset published for $tag; skipping verification"
  }
} catch {
  Write-Host "==> No checksum asset published for $tag; skipping verification"
}

# Idempotent re-run, same as install.sh's docker rm -f / systemd unit rewrite.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host "==> Replacing existing service $ServiceName"
  Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
  & sc.exe delete $ServiceName | Out-Null
  Start-Sleep -Seconds 1
}

Move-Item -Force -Path $tmp -Destination $BinPath

Write-Host "==> Registering service $ServiceName"
New-Service -Name $ServiceName `
  -BinaryPathName "`"$BinPath`"" `
  -DisplayName "OpenObserve synthetics private agent ($AgentName)" `
  -Description "OpenObserve synthetics private agent — outbound-only, polls the o2 Job API." `
  -StartupType Automatic | Out-Null

# Single source of truth, same design as install.sh's write_config_file —
# not a separate passive snapshot: view this file any time to see exactly
# how the agent is configured, and Restart-Service picks up an edit to it
# (the agent re-reads the file on every start via AGENT_CONFIG_FILE).
$envLines = @(
  "AGENT_POLL_ENDPOINT=$O2Url",
  "AGENT_ORG=$Org",
  "AGENT_API_TOKEN=$Token",
  "PROBE_AGENT_ID=$AgentName",
  "AGENT_SERVICE_NAME=$ServiceName",
  "SSRF_POLICY_DEFAULT=relaxed"
)
if (-not [string]::IsNullOrEmpty($LocationId)) {
  $envLines += "AGENT_LOCATION_ID=$LocationId"
} else {
  $envLines += "AGENT_LOCATION=$Location"
}
if (-not [string]::IsNullOrEmpty($Region))   { $envLines += "PROBE_REGION=$Region" }
if (-not [string]::IsNullOrEmpty($LeaseMax)) { $envLines += "PROBE_LEASE_MAX=$LeaseMax" }

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Set-Content -Path $ConfigPath -Value $envLines -Encoding ASCII
# Lock it down like install.sh's chmod 600 — SYSTEM (the service) and
# Administrators only; it carries the same o2syn_ token in plaintext.
icacls $ConfigPath /inheritance:r /grant:r "SYSTEM:F" "BUILTIN\Administrators:F" | Out-Null

# Windows Services get their env from this registry key (REG_MULTI_SZ), read
# by the Service Control Manager at process start — the standard mechanism,
# since New-Service has no -Environment parameter. Only one var now: the
# config file carries the rest, same file every restart re-reads.
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment `
  -Value @("AGENT_CONFIG_FILE=$ConfigPath") -Type MultiString

# Crash-restart policy — equivalent of Restart=always/RestartSec=5. No
# New-Service equivalent; sc.exe failure is the standard mechanism and works
# on every supported Windows Server version.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

Start-Service -Name $ServiceName

Write-Host "==> Agent '$AgentName' running as Windows Service '$ServiceName'. Config: $ConfigPath (edit + Restart-Service $ServiceName to apply changes). The location turns Online in the UI after first register."
