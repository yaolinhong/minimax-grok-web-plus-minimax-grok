Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  Write-Host $Message
}

function Fail {
  param([string]$Message)
  Write-Error $Message
  exit 1
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

  return $raw | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $json = $Object | ConvertTo-Json -Depth 10
  $json + [Environment]::NewLine | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Resolve-SettingsFile {
  $appDataCandidate = [System.IO.Path]::Combine($env:APPDATA, 'Claude', 'settings.json')
  $userCandidate = [System.IO.Path]::Combine($env:USERPROFILE, '.claude', 'settings.json')

  if (Test-Path -LiteralPath $appDataCandidate) {
    return $appDataCandidate
  }
  if (Test-Path -LiteralPath $userCandidate) {
    return $userCandidate
  }
  return $appDataCandidate
}

function Test-ServiceExists {
  param([string]$ServiceName)

  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  return $null -ne $service
}

function Remove-ShimEnvFromSettings {
  param(
    [string]$SettingsFile,
    [string[]]$ManagedEnvKeys
  )

  if (-not (Test-Path -LiteralPath $SettingsFile)) {
    return $false
  }

  $settings = Read-JsonFile -Path $SettingsFile
  if ($null -eq $settings) {
    return $false
  }

  if ($settings.PSObject.Properties.Match('env').Count -eq 0 -or $settings.env -eq $null) {
    return $false
  }

  $keysToRemove = @()
  if ($ManagedEnvKeys -and $ManagedEnvKeys.Count -gt 0) {
    $keysToRemove = $ManagedEnvKeys
  } else {
    $keysToRemove = @(
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_AUTH_TOKEN',
      'SYSTEM_USER_SHIM_TARGET_BASE_URL',
      'SYSTEM_USER_SHIM_MODEL_PATTERN',
      'ANTHROPIC_MODEL',
      'ANTHROPIC_SMALL_FAST_MODEL',
      'ANTHROPIC_DEFAULT_SONNET_MODEL',
      'ANTHROPIC_DEFAULT_OPUS_MODEL',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL',
      'API_TIMEOUT_MS',
      'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
    )
  }

  $changed = $false
  foreach ($key in $keysToRemove) {
    if ($settings.env.PSObject.Properties.Match($key).Count -gt 0) {
      $settings.env.PSObject.Properties.Remove($key)
      $changed = $true
    }
  }

  if (-not $changed) {
    return $false
  }

  if ($settings.env.PSObject.Properties.Count -eq 0) {
    $settings.PSObject.Properties.Remove('env')
  }

  Write-JsonFile -Path $SettingsFile -Object $settings
  return $true
}

if (-not (Test-IsWindowsPlatform)) {
  Fail 'This uninstall script supports Windows only.'
}

if (-not (Test-IsAdministrator)) {
  Fail 'Administrator privileges are required. Please rerun this script from PowerShell started with "Run as administrator".'
}

$defaultServiceName = 'ClaudeSystemUserShim'
$defaultInstallDir = Join-Path $env:USERPROFILE '.claude\system-user-shim'
$defaultLogFile = Join-Path $env:USERPROFILE '.claude\logs\system-user-shim.log'
$defaultStateFile = Join-Path $defaultInstallDir 'state.json'

$state = Read-JsonFile -Path $defaultStateFile

$serviceName = $defaultServiceName
$installDir = $defaultInstallDir
$logFile = $defaultLogFile
$settingsFile = Resolve-SettingsFile
$backupFile = $null
$managedEnvKeys = @()

if ($null -ne $state) {
  if ($state.PSObject.Properties.Match('serviceName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.serviceName)) {
    $serviceName = [string]$state.serviceName
  }
  if ($state.PSObject.Properties.Match('installDir').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.installDir)) {
    $installDir = [string]$state.installDir
  }
  if ($state.PSObject.Properties.Match('logFile').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.logFile)) {
    $logFile = [string]$state.logFile
  }
  if ($state.PSObject.Properties.Match('settingsFile').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.settingsFile)) {
    $settingsFile = [string]$state.settingsFile
  }
  if ($state.PSObject.Properties.Match('backupFile').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.backupFile)) {
    $backupFile = [string]$state.backupFile
  }
  if ($state.PSObject.Properties.Match('managedEnvKeys').Count -gt 0 -and $state.managedEnvKeys -ne $null) {
    $managedEnvKeys = @($state.managedEnvKeys)
  }
}

$nssmCommand = Get-Command nssm.exe -ErrorAction SilentlyContinue
if (-not $nssmCommand) {
  $nssmCommand = Get-Command nssm -ErrorAction SilentlyContinue
}
$nssmPath = $null
if ($nssmCommand) {
  $nssmPath = $nssmCommand.Source
}

if ($nssmPath) {
  & $nssmPath stop $serviceName | Out-Null
} else {
  try {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
  } catch {
  }
}

if ($nssmPath) {
  & $nssmPath remove $serviceName confirm | Out-Null
}

if (Test-ServiceExists -ServiceName $serviceName) {
  & sc.exe delete $serviceName | Out-Null
}

$restoreBackup = $false
if ($backupFile -and (Test-Path -LiteralPath $backupFile)) {
  $answer = Read-Host -Prompt ('Restore Claude settings backup from "' + $backupFile + '"? This will overwrite changes made to settings.json after installation. [y/N]')
  if ($answer -match '^[Yy]') {
    $restoreBackup = $true
  }
}

if ($restoreBackup) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $settingsFile) -Force | Out-Null
  Copy-Item -LiteralPath $backupFile -Destination $settingsFile -Force
  Write-Info ('Restored Claude Code settings from ' + $backupFile)
} else {
  $cleaned = Remove-ShimEnvFromSettings -SettingsFile $settingsFile -ManagedEnvKeys $managedEnvKeys
  if ($cleaned) {
    Write-Info ('Removed shim-related environment variables from ' + $settingsFile)
  } elseif ($backupFile -and (Test-Path -LiteralPath $backupFile)) {
    Write-Info ('Skipped backup restore. Backup remains at ' + $backupFile)
  } else {
    Write-Info 'No settings backup found. No shim-specific settings were removed.'
  }
}

if (Test-Path -LiteralPath $installDir) {
  Remove-Item -LiteralPath $installDir -Recurse -Force
}

if (Test-Path -LiteralPath $logFile) {
  Remove-Item -LiteralPath $logFile -Force
  Write-Info ('Removed log file ' + $logFile)
} else {
  Write-Info ('Log file not found: ' + $logFile)
}

Write-Info 'Uninstalled Claude Code MiniMax Shim.'
