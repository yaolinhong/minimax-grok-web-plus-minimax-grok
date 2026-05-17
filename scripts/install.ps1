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

function Prompt-Value {
  param(
    [string]$Label,
    [string]$DefaultValue,
    [switch]$Secret
  )

  if ($Secret) {
    $secure = Read-Host -Prompt $Label -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  } else {
    if ([string]::IsNullOrEmpty($DefaultValue)) {
      $value = Read-Host -Prompt $Label
    } else {
      $value = Read-Host -Prompt ($Label + ' [' + $DefaultValue + ']')
    }
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    return $DefaultValue
  }

  return $value.Trim()
}

function Get-NodeCommand {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) {
    $command = Get-Command node -ErrorAction SilentlyContinue
  }
  if (-not $command) {
    Fail 'Node.js 18+ is required. Please install Node.js and ensure node.exe is available in PATH.'
  }
  return $command.Source
}

function Get-NssmCommand {
  $command = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if (-not $command) {
    $command = Get-Command nssm -ErrorAction SilentlyContinue
  }
  if (-not $command) {
    Write-Info 'nssm not found. Downloading...'
    $nssmDir = Join-Path $env:TEMP 'nssm-temp'
    $nssmZip = Join-Path $nssmDir 'nssm.zip'
    $nssmExe = Join-Path $nssmDir 'nssm.exe'

    New-Item -ItemType Directory -Path $nssmDir -Force | Out-Null

    $url = 'https://github.com/ArbitraryRider/nssm-builds/raw/master/2019-07-19/nssm-3.0.0.0.zip'
    try {
      Invoke-WebRequest -Uri $url -OutFile $nssmZip -UseBasicParsing
    } catch {
      try {
        $url = 'https://nchc.dl.sourceforge.net/project/nssm/nssm/nssm-3.0.0.0/nssm-3.0.0.0.zip'
        Invoke-WebRequest -Uri $url -OutFile $nssmZip -UseBasicParsing
      } catch {
        Fail ('Failed to download nssm. Please install NSSM manually from https://nssm.cc/download and ensure nssm.exe is available in PATH.')
      }
    }

    Expand-Archive -Path $nssmZip -DestinationPath $nssmDir -Force
    $found = Get-ChildItem -Path $nssmDir -Filter 'nssm.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
      Fail 'nssm.exe not found in downloaded archive.'
    }
    Copy-Item -LiteralPath $found.FullName -Destination $env:TEMP -Force
    $env:PATH = $env:PATH + ';' + $env:TEMP
    return Join-Path $env:TEMP 'nssm.exe'
  }
  return $command.Source
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

  $parent = Split-Path -Parent $appDataCandidate
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  return $appDataCandidate
}

function Test-ServiceExists {
  param([string]$ServiceName)

  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  return $null -ne $service
}

function Remove-ServiceIfPresent {
  param(
    [string]$NssmPath,
    [string]$ServiceName
  )

  if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
    return
  }

  Write-Info ('Existing service "' + $ServiceName + '" detected. Recreating it.')

  & $NssmPath stop $ServiceName | Out-Null
  Start-Sleep -Seconds 1

  try {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
  } catch {
  }

  & $NssmPath remove $ServiceName confirm | Out-Null

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
      return
    }
    Start-Sleep -Milliseconds 500
  }

  Fail ('Timed out waiting for existing service "' + $ServiceName + '" to be removed.')
}

function Invoke-HealthCheck {
  param(
    [int]$Port,
    [string]$LogFile
  )

  $healthUrl = 'http://127.0.0.1:' + $Port + '/__health'
  $deadline = (Get-Date).AddSeconds(20)

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2
      if ($response.StatusCode -eq 200) {
        return
      }
    } catch {
    }
    Start-Sleep -Milliseconds 500
  }

  Fail ('Health check failed for ' + $healthUrl + '. Review service logs at ' + $LogFile)
}

if (-not (Test-IsWindowsPlatform)) {
  Fail 'This installer supports Windows only.'
}

if (-not (Test-IsAdministrator)) {
  Fail 'Administrator privileges are required. Please rerun this script from PowerShell started with "Run as administrator".'
}

$nodePath = Get-NodeCommand
$nodeVersionOutput = & $nodePath --version
if ($LASTEXITCODE -ne 0) {
  Fail 'Failed to execute node.exe to determine version.'
}
$nodeVersion = $nodeVersionOutput.Trim()
$nodeVersionCore = $nodeVersion.TrimStart('v')
$nodeMajor = 0
try {
  $nodeMajor = [int]($nodeVersionCore.Split('.')[0])
} catch {
  Fail ('Unable to parse Node.js version from "' + $nodeVersion + '".')
}
if ($nodeMajor -lt 18) {
  Fail ('Node.js 18+ is required. Current version: ' + $nodeVersion)
}

$nssmPath = Get-NssmCommand

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceServer = Join-Path $repoRoot 'server.mjs'
if (-not (Test-Path -LiteralPath $sourceServer)) {
  Fail ('server.mjs not found at ' + $sourceServer)
}

$defaultModel = 'MiniMax-M2.7-highspeed'
$defaultTargetUrl = 'https://api.minimaxi.com/anthropic'
$defaultPort = '17861'
$defaultModelPattern = 'minimax'
$defaultPreserveSystem = 'goal evaluator,goal condition,return exactly true or false,respond with only true or false'
$serviceName = 'ClaudeSystemUserShim'
$displayName = 'Claude Code MiniMax Shim'
$description = 'Routes Claude Code requests to MiniMax API with system-to-user prompt conversion'

Write-Info 'Claude Code MiniMax Shim installer for Windows'
Write-Info ''

$apiKey = Prompt-Value -Label 'MiniMax API Key' -DefaultValue '' -Secret
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  Fail 'API Key cannot be empty.'
}

$model = Prompt-Value -Label 'Model' -DefaultValue $defaultModel
if ([string]::IsNullOrWhiteSpace($model)) {
  Fail 'Model cannot be empty.'
}

$targetBaseUrl = Prompt-Value -Label 'MiniMax Anthropic base URL' -DefaultValue $defaultTargetUrl
try {
  $targetUri = [System.Uri]$targetBaseUrl
  if (-not $targetUri.AbsoluteUri) {
    throw 'invalid'
  }
} catch {
  Fail ('Target URL is invalid: ' + $targetBaseUrl)
}

$portInput = Prompt-Value -Label 'Local shim port' -DefaultValue $defaultPort
$port = 0
if (-not [int]::TryParse($portInput, [ref]$port)) {
  Fail ('Port must be an integer between 1 and 65535. Received: ' + $portInput)
}
if ($port -lt 1 -or $port -gt 65535) {
  Fail ('Port must be between 1 and 65535. Received: ' + $portInput)
}

$modelPattern = Prompt-Value -Label 'Model match pattern' -DefaultValue $defaultModelPattern
if ([string]::IsNullOrWhiteSpace($modelPattern)) {
  Fail 'Model match pattern cannot be empty.'
}

$preserveSystem = Prompt-Value -Label 'Preserve system patterns' -DefaultValue $defaultPreserveSystem
if ([string]::IsNullOrWhiteSpace($preserveSystem)) {
  Fail 'Preserve system patterns cannot be empty.'
}

$installDir = Join-Path $env:USERPROFILE '.claude\system-user-shim'
$logDir = Join-Path $env:USERPROFILE '.claude\logs'
$serverDestination = Join-Path $installDir 'server.mjs'
$logFile = Join-Path $logDir 'system-user-shim.log'
$stateFile = Join-Path $installDir 'state.json'
$settingsFile = Resolve-SettingsFile

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $settingsFile) -Force | Out-Null

Copy-Item -LiteralPath $sourceServer -Destination $serverDestination -Force

$settings = @{}
$backupFile = $null
if (Test-Path -LiteralPath $settingsFile) {
  $settingsObject = Read-JsonFile -Path $settingsFile
  if ($null -ne $settingsObject) {
    $settings = $settingsObject
  }
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupFile = $settingsFile + '.system-user-shim.' + $timestamp + '.bak'
  Copy-Item -LiteralPath $settingsFile -Destination $backupFile -Force
}

if (-not $settings) {
  $settings = @{}
}

$envMap = @{}
if ($settings.PSObject.Properties.Match('env').Count -gt 0 -and $settings.env -ne $null) {
  foreach ($property in $settings.env.PSObject.Properties) {
    $envMap[$property.Name] = [string]$property.Value
  }
}

$envMap['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + $port
$envMap['ANTHROPIC_AUTH_TOKEN'] = $apiKey
$envMap['SYSTEM_USER_SHIM_TARGET_BASE_URL'] = $targetBaseUrl
$envMap['SYSTEM_USER_SHIM_MODEL_PATTERN'] = $modelPattern
$envMap['SYSTEM_USER_SHIM_PRESERVE_SYSTEM'] = $preserveSystem
$envMap['ANTHROPIC_MODEL'] = $model
$envMap['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $model
$envMap['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $model
if (-not $envMap.ContainsKey('ANTHROPIC_SMALL_FAST_MODEL') -or [string]::IsNullOrWhiteSpace($envMap['ANTHROPIC_SMALL_FAST_MODEL'])) {
  $envMap['ANTHROPIC_SMALL_FAST_MODEL'] = $model
}
if (-not $envMap.ContainsKey('ANTHROPIC_DEFAULT_HAIKU_MODEL') -or [string]::IsNullOrWhiteSpace($envMap['ANTHROPIC_DEFAULT_HAIKU_MODEL'])) {
  $envMap['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $envMap['ANTHROPIC_SMALL_FAST_MODEL']
}
$managedEnvKeys = @(
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_AUTH_TOKEN',
  'SYSTEM_USER_SHIM_TARGET_BASE_URL',
  'SYSTEM_USER_SHIM_MODEL_PATTERN',
  'SYSTEM_USER_SHIM_PRESERVE_SYSTEM',
  'ANTHROPIC_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL'
)
if (-not $envMap.ContainsKey('API_TIMEOUT_MS') -or [string]::IsNullOrWhiteSpace($envMap['API_TIMEOUT_MS'])) {
  $envMap['API_TIMEOUT_MS'] = '3000000'
  $managedEnvKeys += 'API_TIMEOUT_MS'
}
if (-not $envMap.ContainsKey('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC') -or [string]::IsNullOrWhiteSpace($envMap['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'])) {
  $envMap['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
  $managedEnvKeys += 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
}

$envObject = New-Object psobject
foreach ($key in ($envMap.Keys | Sort-Object)) {
  Add-Member -InputObject $envObject -MemberType NoteProperty -Name $key -Value $envMap[$key]
}

if ($settings -is [System.Collections.IDictionary]) {
  $settings['env'] = $envObject
} else {
  if ($settings.PSObject.Properties.Match('env').Count -gt 0) {
    $settings.env = $envObject
  } else {
    Add-Member -InputObject $settings -MemberType NoteProperty -Name env -Value $envObject
  }
}

Write-JsonFile -Path $settingsFile -Object $settings

Remove-ServiceIfPresent -NssmPath $nssmPath -ServiceName $serviceName

& $nssmPath install $serviceName $nodePath $serverDestination | Out-Null
if ($LASTEXITCODE -ne 0) {
  Fail ('Failed to register Windows service "' + $serviceName + '".')
}

& $nssmPath set $serviceName DisplayName $displayName | Out-Null
& $nssmPath set $serviceName Description $description | Out-Null
& $nssmPath set $serviceName AppDirectory $installDir | Out-Null
& $nssmPath set $serviceName AppStdout $logFile | Out-Null
& $nssmPath set $serviceName AppStderr $logFile | Out-Null
& $nssmPath set $serviceName AppRotateFiles 1 | Out-Null
& $nssmPath set $serviceName AppRotateOnline 1 | Out-Null
& $nssmPath set $serviceName Start SERVICE_AUTO_START | Out-Null
& $nssmPath set $serviceName AppExit Default Restart | Out-Null

$environmentLines = @(
  'SYSTEM_USER_SHIM_PORT=' + $port,
  'SYSTEM_USER_SHIM_TARGET_BASE_URL=' + $targetBaseUrl,
  'SYSTEM_USER_SHIM_MODEL_PATTERN=' + $modelPattern,
  'SYSTEM_USER_SHIM_PRESERVE_SYSTEM=' + $preserveSystem
)
$parametersKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceName + '\Parameters'
if (-not (Test-Path -LiteralPath $parametersKey)) {
  New-Item -Path $parametersKey -Force | Out-Null
}
try {
  New-ItemProperty -Path $parametersKey -Name AppEnvironmentExtra -PropertyType MultiString -Value $environmentLines -Force | Out-Null
} catch {
  Fail ('Failed to configure service environment variables for "' + $serviceName + '".')
}

$state = [ordered]@{
  installedAt = (Get-Date).ToString('o')
  serviceName = $serviceName
  settingsFile = $settingsFile
  backupFile = $backupFile
  installDir = $installDir
  logFile = $logFile
  port = $port
  targetBaseUrl = $targetBaseUrl
  modelPattern = $modelPattern
  preserveSystem = $preserveSystem
  model = $model
  managedEnvKeys = $managedEnvKeys
}
Write-JsonFile -Path $stateFile -Object $state

Start-Service -Name $serviceName
Invoke-HealthCheck -Port $port -LogFile $logFile

Write-Info ''
Write-Info 'Installed.'
Write-Info ('Health: http://127.0.0.1:' + $port + '/__health')
Write-Info ('Claude Code settings: ' + $settingsFile)
Write-Info ('Service log: ' + $logFile)
