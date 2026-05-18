Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

function Write-Section {
  param([string]$Title)
  Write-Host ''
  Write-Host ('== ' + $Title + ' ==')
}

function Write-Check {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Detail
  )

  Write-Host ('[' + $Status + '] ' + $Name + ': ' + $Detail)
}

function Test-IsWindowsPlatform {
  if (Test-Path variable:IsWindows) {
    return [bool]$IsWindows
  }
  return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  try {
    return $raw | ConvertFrom-Json
  } catch {
    Write-Check 'json' 'WARN' ('Failed to parse ' + $Path + ': ' + $_.Exception.Message)
    return $null
  }
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  if ($Object.PSObject.Properties.Match($Name).Count -eq 0) {
    return $null
  }
  return $Object.$Name
}

function Show-SettingsFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Check 'settings' 'MISS' $Path
    return
  }

  $settings = Read-JsonFile -Path $Path
  if ($null -eq $settings) {
    Write-Check 'settings' 'WARN' ('Cannot parse ' + $Path)
    return
  }

  $envObject = Get-PropertyValue -Object $settings -Name 'env'
  if ($null -eq $envObject) {
    Write-Check 'settings' 'WARN' ($Path + ' has no env object')
    return
  }

  Write-Check 'settings' 'OK' $Path
  foreach ($key in @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_SMALL_FAST_MODEL',
    'SYSTEM_USER_SHIM_TARGET_BASE_URL',
    'SYSTEM_USER_SHIM_MODEL_PATTERN',
    'SYSTEM_USER_SHIM_ROUTES'
  )) {
    $value = Get-PropertyValue -Object $envObject -Name $key
    if ($null -ne $value) {
      Write-Host ('  ' + $key + '=' + [string]$value)
    }
  }
}

if (-not (Test-IsWindowsPlatform)) {
  Write-Error 'This diagnostic script supports Windows only.'
  exit 1
}

$serviceName = 'ClaudeSystemUserShim'
$repoRoot = Split-Path -Parent $PSScriptRoot
$repoServer = Join-Path $repoRoot 'server.mjs'
$defaultInstallDir = Join-Path $env:USERPROFILE '.claude\system-user-shim'
$defaultStateFile = Join-Path $defaultInstallDir 'state.json'
$state = Read-JsonFile -Path $defaultStateFile
$installDir = [string](Get-PropertyValue -Object $state -Name 'installDir')
$port = [string](Get-PropertyValue -Object $state -Name 'port')
$logFile = [string](Get-PropertyValue -Object $state -Name 'logFile')

if ([string]::IsNullOrWhiteSpace($installDir)) {
  $installDir = $defaultInstallDir
}
if ([string]::IsNullOrWhiteSpace($port)) {
  $port = '17861'
}
if ([string]::IsNullOrWhiteSpace($logFile)) {
  $logFile = Join-Path $env:USERPROFILE '.claude\logs\system-user-shim.log'
}

$installedServer = Join-Path $installDir 'server.mjs'

Write-Section 'Repository'
if (Test-Path -LiteralPath $repoServer) {
  $repoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $repoServer).Hash
  Write-Check 'repo server.mjs' 'OK' ($repoServer + ' sha256=' + $repoHash)
} else {
  $repoHash = $null
  Write-Check 'repo server.mjs' 'MISS' $repoServer
}

Write-Section 'Installed Server'
if (Test-Path -LiteralPath $installedServer) {
  $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedServer).Hash
  Write-Check 'installed server.mjs' 'OK' ($installedServer + ' sha256=' + $installedHash)
  if ($repoHash) {
    if ($repoHash -eq $installedHash) {
      Write-Check 'server hash match' 'OK' 'Installed service file matches this repository checkout.'
    } else {
      Write-Check 'server hash match' 'FAIL' 'Installed service file differs from this repository checkout. Re-run scripts\install.ps1 or copy server.mjs into the install directory.'
    }
  }
} else {
  Write-Check 'installed server.mjs' 'MISS' $installedServer
}

Write-Section 'Windows Service'
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
  Write-Check 'service' 'FAIL' ($serviceName + ' is not installed.')
} else {
  Write-Check 'service' 'OK' ($serviceName + ' status=' + $service.Status)
}

$cimService = Get-CimInstance Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction SilentlyContinue
if ($null -ne $cimService) {
  Write-Host ('  PathName=' + $cimService.PathName)
  Write-Host ('  StartMode=' + $cimService.StartMode)
}

$parametersKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceName + '\Parameters'
if (Test-Path -LiteralPath $parametersKey) {
  $parameters = Get-ItemProperty -LiteralPath $parametersKey
  foreach ($key in @('Application', 'AppParameters', 'AppDirectory', 'AppStdout', 'AppStderr', 'AppEnvironmentExtra')) {
    $value = Get-PropertyValue -Object $parameters -Name $key
    if ($null -ne $value) {
      if ($value -is [array]) {
        Write-Host ('  ' + $key + '=' + ($value -join '; '))
      } else {
        Write-Host ('  ' + $key + '=' + [string]$value)
      }
    }
  }
} else {
  Write-Check 'service parameters' 'WARN' ('Missing ' + $parametersKey)
}

Write-Section 'Claude Settings'
Show-SettingsFile -Path ([System.IO.Path]::Combine($env:APPDATA, 'Claude', 'settings.json'))
Show-SettingsFile -Path ([System.IO.Path]::Combine($env:USERPROFILE, '.claude', 'settings.json'))

Write-Section 'Current Shell Environment'
foreach ($key in @(
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL'
)) {
  $value = [Environment]::GetEnvironmentVariable($key, 'Process')
  if (-not [string]::IsNullOrWhiteSpace($value)) {
    Write-Host ('  Process ' + $key + '=' + $value)
  }
}

Write-Section 'Port And Health'
$healthUrl = 'http://127.0.0.1:' + $port + '/__health'
try {
  $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
  Write-Check 'health' 'OK' ($healthUrl + ' status=' + $response.StatusCode)
} catch {
  Write-Check 'health' 'FAIL' ($healthUrl + ' ' + $_.Exception.Message)
}

$netstat = & netstat.exe -ano 2>$null | Select-String (':' + $port)
if ($netstat) {
  $netstat | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
} else {
  Write-Check 'port listener' 'WARN' ('No netstat entry found for :' + $port)
}

Write-Section 'Recent Log'
if (Test-Path -LiteralPath $logFile) {
  Write-Host ('Log file: ' + $logFile)
  Get-Content -LiteralPath $logFile -Tail 80
} else {
  Write-Check 'log' 'MISS' $logFile
}

Write-Section 'Expected Fix If Hash Differs'
Write-Host 'Run from the repository root in an Administrator PowerShell:'
Write-Host '  .\scripts\install.ps1'
Write-Host 'Or, for a quick manual resync after confirming paths:'
Write-Host ('  Copy-Item .\server.mjs "' + $installedServer + '" -Force')
Write-Host ('  Restart-Service ' + $serviceName)
