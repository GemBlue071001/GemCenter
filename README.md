# GemCenter local AWS backend

This starter stack runs the first backend slice locally with [FLoCI](https://floci.io/aws/):

- DynamoDB table: `gemcenter-attendees`
- Lambda: `gemcenter-register`
- API Gateway v2 HTTP API: `POST /registrations`
- FLoCI Web Console for viewing resources and DynamoDB data

## Prerequisite

Docker Desktop must be running and your Windows user must be allowed to access its Docker engine. FLoCI needs the Docker socket because Lambda and the Web Console each run in a Docker sidecar.

## Start

```powershell
docker compose up --build
```

The `bootstrap` container waits for FLoCI then creates or updates the table, IAM role, Lambda and HTTP API. Its endpoint information is written to `.floci-data/local-stack.env`.

Open the resource UI at [http://localhost:4566/_floci/ui](http://localhost:4566/_floci/ui). On its first visit FLoCI starts its Web Console sidecar; this can take a moment while Docker downloads the console image.

## Test the registration API

After `bootstrap` prints `Local infrastructure is ready`, run:

```powershell
$envFile = Get-Content .\.floci-data\local-stack.env
$apiUrl = ($envFile | Where-Object { $_ -like 'API_URL=*' }) -replace '^API_URL=', ''

$body = @{
  fullName = 'Nguyen Van A'
  email = 'nguyenvana@example.test'
  phone = '0900000000'
  company = 'Gem Center'
  title = 'Guest'
  program = 'Trien lam cong nghe yen tiec'
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri $apiUrl -ContentType 'application/json' -Body $body
```

The response contains a temporary `ticketToken`; the next backend slice will convert it to a QR image and email it. It is intentionally opaque and does not expose personal data.

## Useful commands

```powershell
# Read provisioning output
docker compose logs bootstrap

# Re-run provisioning after changing backend/register/index.js
docker compose run --rm bootstrap

# Stop containers, preserving local FLoCI data
docker compose down

# Remove the persisted emulator state too
Remove-Item -Recurse -Force .\.floci-data
```
