param(
  [ValidateRange(1, 65535)]
  [int]$Port = 3000,
  [string]$EventId = 'iti-2026',
  [string]$FromEmail = 'no-reply@gemcenter.local',
  [string]$StateFile
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $StateFile) {
  $StateFile = Join-Path $projectRoot '.floci-data/local-stack.env'
}
if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
  throw "FLoCI state file not found: $StateFile. Run 'docker compose up --build -d' first."
}
if (-not (Get-Command sam -ErrorAction SilentlyContinue)) {
  throw 'AWS SAM CLI was not found. Install SAM CLI, then reopen PowerShell.'
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  throw 'npm was not found. Install Node.js, then reopen PowerShell.'
}

function Ensure-LocalDependencies {
  param([string]$Name)

  $sourceDir = Join-Path $projectRoot "backend/$Name"
  $packageFile = Join-Path $sourceDir 'package.json'
  $lockFile = Join-Path $sourceDir 'package-lock.json'
  $modulesDir = Join-Path $sourceDir 'node_modules'
  $markerFile = Join-Path $modulesDir '.gemcenter-local-deps-hash'
  $manifestHash = (Get-FileHash -LiteralPath $packageFile -Algorithm SHA256).Hash
  if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
    $manifestHash += ':' + (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash
  }

  $installedHash = if (Test-Path -LiteralPath $markerFile -PathType Leaf) {
    (Get-Content -LiteralPath $markerFile -Raw).Trim()
  }
  else { '' }
  if ((Test-Path -LiteralPath $modulesDir -PathType Container) -and $installedHash -eq $manifestHash) {
    return
  }

  Write-Host "Installing local dependencies for $Name..."
  if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
    & npm ci --prefix $sourceDir --omit=dev --no-audit --no-fund
  }
  else {
    & npm install --prefix $sourceDir --omit=dev --no-package-lock --no-audit --no-fund
  }
  if ($LASTEXITCODE -ne 0) { throw "npm install failed for $Name with exit code $LASTEXITCODE" }
  [System.IO.File]::WriteAllText($markerFile, $manifestHash, [System.Text.UTF8Encoding]::new($false))
}

$localState = @{}
foreach ($line in Get-Content -LiteralPath $StateFile) {
  if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
    $localState[$Matches[1]] = $Matches[2]
  }
}
if (-not $localState['TICKET_EMAIL_QUEUE_URL']) {
  throw "TICKET_EMAIL_QUEUE_URL is missing from $StateFile. Wait until FLoCI bootstrap is ready."
}

# FLoCI writes a Compose-network queue URL. SAM's Lambda containers reach the
# Windows Docker host through host.docker.internal instead.
$queueUri = [UriBuilder]::new($localState['TICKET_EMAIL_QUEUE_URL'])
if ($queueUri.Scheme -ne 'http' -or $queueUri.Host -notin @('floci', 'localhost', '127.0.0.1', 'host.docker.internal')) {
  throw "Unexpected local queue URL: $($localState['TICKET_EMAIL_QUEUE_URL'])"
}
$queueUri.Host = 'host.docker.internal'
$endpoint = 'http://host.docker.internal:4566'
$envFile = Join-Path (Split-Path -Parent $StateFile) 'sam-local-env.json'
$localEnv = @{
  RegisterFunction = @{
    ATTENDEES_TABLE = 'gemcenter-attendees'
    EVENT_ID = $EventId
    DYNAMODB_ENDPOINT = $endpoint
    SQS_ENDPOINT = $endpoint
    TICKET_EMAIL_QUEUE_URL = $queueUri.Uri.AbsoluteUri.TrimEnd('/')
    EXPOSE_TICKET_TOKEN = 'true'
  }
  MailerFunction = @{
    ATTENDEES_TABLE = 'gemcenter-attendees'
    EVENT_ID = $EventId
    DYNAMODB_ENDPOINT = $endpoint
    SES_ENDPOINT = $endpoint
    FROM_EMAIL = $FromEmail
    EMAIL_PREVIEW_DATA_URI = 'true'
  }
}
$json = $localEnv | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($envFile, $json, [System.Text.UTF8Encoding]::new($false))

$credentialNames = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_DEFAULT_REGION', 'AWS_REGION', 'AWS_ENDPOINT_URL')
$previousEnv = @{}
foreach ($name in $credentialNames) {
  $previousEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location $projectRoot
try {
  Ensure-LocalDependencies -Name 'register'

  # These credentials are accepted only by the local FLoCI emulator.
  $env:AWS_ACCESS_KEY_ID = 'test'
  $env:AWS_SECRET_ACCESS_KEY = 'test'
  Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
  Remove-Item Env:AWS_ENDPOINT_URL -ErrorAction SilentlyContinue
  $env:AWS_DEFAULT_REGION = 'us-east-1'
  $env:AWS_REGION = 'us-east-1'

  Write-Host "SAM API: http://127.0.0.1:$Port/registrations"
  Write-Host "FLoCI console: http://localhost:4566/_floci/ui"
  Write-Host "Local environment: $envFile"
  Write-Host 'JavaScript edits under backend/register are picked up without sam build.'
  & sam local start-api --template (Join-Path $projectRoot 'template.local.yaml') --env-vars $envFile --region us-east-1 --port $Port
  if ($LASTEXITCODE -ne 0) { throw "sam local start-api failed with exit code $LASTEXITCODE" }
}
finally {
  foreach ($name in $credentialNames) {
    if ($null -eq $previousEnv[$name]) {
      Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
    else {
      [Environment]::SetEnvironmentVariable($name, $previousEnv[$name], 'Process')
    }
  }
  Pop-Location
}
