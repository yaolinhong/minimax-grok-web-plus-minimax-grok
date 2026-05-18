param(
  [int]$Port = 17861,
  [string]$Model = 'MiniMax-M2.7-highspeed',
  [string]$ApiKey = $env:ANTHROPIC_AUTH_TOKEN
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

function Get-SettingsEnvValue {
  param([string]$Name)

  $settingsFiles = @(
    [System.IO.Path]::Combine($env:USERPROFILE, '.claude', 'settings.json'),
    [System.IO.Path]::Combine($env:APPDATA, 'Claude', 'settings.json')
  )

  foreach ($file in $settingsFiles) {
    $settings = Read-JsonFile -Path $file
    $envObject = Get-PropertyValue -Object $settings -Name 'env'
    $value = Get-PropertyValue -Object $envObject -Name $Name
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
      return [string]$value
    }
  }

  return $null
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  $ApiKey = Get-SettingsEnvValue -Name 'ANTHROPIC_AUTH_TOKEN'
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  Write-Error 'ANTHROPIC_AUTH_TOKEN was not found in process env or Claude settings.'
  exit 1
}

$baseUrl = 'http://127.0.0.1:' + $Port
$healthUrl = $baseUrl + '/__health'
try {
  $health = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
  if ($health.StatusCode -ne 200) {
    throw ('Unexpected health status ' + $health.StatusCode)
  }
} catch {
  Write-Error ('Shim health check failed at ' + $healthUrl + ': ' + $_.Exception.Message)
  exit 1
}

$lastAssistant = @'
Goal acknowledged: `sayhi`

Hi!

(Goal completed.)
'@

$arguments = @{
  session_id = 'smoke-goal-stop-hook'
  transcript_path = 'smoke.jsonl'
  cwd = (Get-Location).Path
  permission_mode = 'bypassPermissions'
  hook_event_name = 'Stop'
  stop_hook_active = $false
  last_assistant_message = $lastAssistant
} | ConvertTo-Json -Compress

$body = [ordered]@{
  model = $Model
  max_tokens = 1024
  output_config = @{ type = 'json' }
  stream = $false
  system = @(
    @{
      type = 'text'
      text = 'You are Claude Code hook evaluator.'
    }
  )
  tools = @(
    @{
      name = 'Bash'
      description = 'Dummy tool included to prove stop-hook requests are compacted before MiniMax sees unsupported fields.'
      input_schema = @{
        type = 'object'
        properties = @{
          command = @{ type = 'string' }
        }
      }
    }
  )
  metadata = @{
    user_id = 'smoke-goal-stop-hook'
  }
  messages = @(
    @{
      role = 'user'
      content = '<local-command-stdout>Goal set: sayhi</local-command-stdout>'
    },
    @{
      role = 'assistant'
      content = $lastAssistant
    },
    @{
      role = 'user'
      content = @"
Based on the conversation transcript above, has the following stopping condition been satisfied? Answer based on transcript evidence only.

Condition: sayhi

ARGUMENTS: $arguments
"@
    }
  )
}

$headers = @{
  'content-type' = 'application/json'
  'x-api-key' = $ApiKey
  'anthropic-version' = '2023-06-01'
}

$url = $baseUrl + '/v1/messages?beta=true'
$json = $body | ConvertTo-Json -Depth 20

try {
  $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $json -UseBasicParsing -TimeoutSec 60
  Write-Host ('HTTP ' + $response.StatusCode)
  Write-Host $response.Content
  if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    exit 1
  }
  if ($response.Content -notmatch '"ok"\s*:') {
    Write-Error 'Smoke response did not contain normalized goal evaluator JSON.'
    exit 1
  }
  Write-Host 'Goal stop-hook smoke test passed.'
} catch {
  $status = $null
  $bodyText = $null
  if ($_.Exception.Response) {
    $status = [int]$_.Exception.Response.StatusCode
    try {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $bodyText = $reader.ReadToEnd()
    } catch {
      $bodyText = $_.Exception.Message
    }
  }

  if ($status) {
    Write-Host ('HTTP ' + $status)
  }
  if ($bodyText) {
    Write-Host $bodyText
  } else {
    Write-Host $_.Exception.Message
  }
  exit 1
}
