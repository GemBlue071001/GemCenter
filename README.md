# GemCenter local AWS backend

Production/staging deployment is defined in [`template.yaml`](template.yaml); follow [`docs/sam-deploy.md`](docs/sam-deploy.md). The Docker Compose bootstrap below is only for local FLoCI. Track outstanding production issues in [`docs/backend-issue-report.md`](docs/backend-issue-report.md).

This starter stack runs the first backend slice locally with [FLoCI](https://floci.io/aws/):

- DynamoDB table: `gemcenter-attendees`
- API Lambda: `gemcenter-register` (registration, attendee list and check-in)
- SQS queue + DLQ: `gemcenter-ticket-email` and `gemcenter-ticket-email-dlq`
- Mailer Lambda: `gemcenter-ticket-mailer` (creates QR and sends ticket email through SES)
- API Gateway v2 HTTP API: `POST /registrations`, `GET /attendees`, `POST /check-ins`
- FLoCI Web Console for viewing resources and DynamoDB data

## Prerequisite

Docker Desktop must be running and your Windows user must be allowed to access its Docker engine. FLoCI needs the Docker socket because Lambda and the Web Console each run in a Docker sidecar.

## Start

```powershell
docker compose up --build
```

The `bootstrap` container waits for FLoCI then creates or updates the table, IAM role, Lambda and HTTP API. Its endpoint information is written to `.floci-data/local-stack.env`.

Open the resource UI at [http://localhost:4566/_floci/ui](http://localhost:4566/_floci/ui). On its first visit FLoCI starts its Web Console sidecar; this can take a moment while Docker downloads the console image.

## Run the SAM API against FLoCI

After the FLoCI bootstrap is ready, run `./scripts/run-sam-local.ps1` in another PowerShell window. The script uses [`template.local.yaml`](template.local.yaml) with the source directories directly, reads `.floci-data/local-stack.env`, writes an ignored `.floci-data/sam-local-env.json`, and starts the SAM API at `http://127.0.0.1:3000`. It installs local Node dependencies only when the manifest changes and restores your shell's previous AWS environment when it exits. Edit `backend/register/index.js`, save, and send the request again; no `sam build` or bootstrap rerun is needed. FLoCI's queue mapping still invokes the FLoCI mailer. See [the SAM local guide](docs/sam-local-floci.md) for the exact steps and limitations.

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

The response has `emailStatus: "queued"` when the ticket-email job is accepted. The Mailer Lambda consumes the queue asynchronously; open **SES Mailbox** in the FLoCI Console to inspect the QR. Local uses an embedded data-URI preview because FLoCI does not resolve `cid:` attachments; production AWS SES uses a normal inline PNG attachment. If SES fails, SQS retries the job up to three times before sending it to the DLQ. `EXPOSE_TICKET_TOKEN=true` exists only in local Compose so the check-in flow can be tested; do not enable it in production.

## Test protected attendee routes locally

`GET /attendees` and `POST /check-ins` require the JWT claim `cognito:groups` to contain `checkin-staff`. In the FLoCI Console, invoke the Lambda directly with this event after registering an attendee. Replace `PASTE_TICKET_TOKEN` with the token returned by registration:

```json
{
  "version": "2.0",
  "routeKey": "POST /check-ins",
  "requestContext": {
    "http": { "method": "POST", "path": "/check-ins" },
    "authorizer": {
      "jwt": {
        "claims": {
          "sub": "local-checkin-staff",
          "email": "staff@example.test",
          "cognito:groups": "checkin-staff"
        }
      }
    }
  },
  "body": "{\"ticketToken\":\"PASTE_TICKET_TOKEN\"}"
}
```

The first check-in returns HTTP `200`; scanning the same ticket again returns `409`. For production, configure a Cognito JWT authorizer in API Gateway on both protected routes. The Lambda also rejects missing or insufficient claims with `401` or `403`.

## Useful commands

```powershell
# Read provisioning output
docker compose logs bootstrap

# Re-run provisioning after changing backend/mailer/index.js, or to update FLoCI's uploaded register Lambda
docker compose run --rm bootstrap

# Stop containers, preserving local FLoCI data
docker compose down

# Remove the persisted emulator state too
Remove-Item -Recurse -Force .\.floci-data
```
