#!/bin/sh
set -eu

endpoint="${AWS_ENDPOINT_URL}"
region="${AWS_DEFAULT_REGION}"
account_id="000000000000"
event_id="iti-2026"
table_name="gemcenter-attendees"
api_function_name="gemcenter-register"
mailer_function_name="gemcenter-ticket-mailer"
api_role_name="gemcenter-register-role"
mailer_role_name="gemcenter-ticket-mailer-role"
api_name="gemcenter-registration-api"
queue_name="gemcenter-ticket-email"
dlq_name="gemcenter-ticket-email-dlq"

aws_local() {
  aws --endpoint-url "${endpoint}" "$@"
}

value_missing() {
  [ "$1" = "None" ] || [ "$1" = "null" ] || [ -z "$1" ]
}

until aws_local sts get-caller-identity >/dev/null 2>&1; do
  echo "Waiting for FLoCI at ${endpoint}..."
  sleep 1
done

if ! aws_local dynamodb describe-table --table-name "${table_name}" >/dev/null 2>&1; then
  echo "Creating DynamoDB table ${table_name}..."
  aws_local dynamodb create-table \
    --table-name "${table_name}" \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions \
      AttributeName=PK,AttributeType=S \
      AttributeName=SK,AttributeType=S \
      AttributeName=GSI1PK,AttributeType=S \
      AttributeName=GSI1SK,AttributeType=S \
      AttributeName=GSI2PK,AttributeType=S \
      AttributeName=GSI2SK,AttributeType=S \
    --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes '[{"IndexName":"GSI1","KeySchema":[{"AttributeName":"GSI1PK","KeyType":"HASH"},{"AttributeName":"GSI1SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},{"IndexName":"GSI2","KeySchema":[{"AttributeName":"GSI2PK","KeyType":"HASH"},{"AttributeName":"GSI2SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' >/dev/null
  aws_local dynamodb wait table-exists --table-name "${table_name}"
fi

gsi2_status="$(aws_local dynamodb describe-table --table-name "${table_name}" --query "Table.GlobalSecondaryIndexes[?IndexName=='GSI2'].IndexStatus | [0]" --output text)"
if value_missing "${gsi2_status}"; then
  echo "Adding ticket lookup index GSI2..."
  aws_local dynamodb update-table \
    --table-name "${table_name}" \
    --attribute-definitions AttributeName=GSI2PK,AttributeType=S AttributeName=GSI2SK,AttributeType=S \
    --global-secondary-index-updates '[{"Create":{"IndexName":"GSI2","KeySchema":[{"AttributeName":"GSI2PK","KeyType":"HASH"},{"AttributeName":"GSI2SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]' >/dev/null
fi

dlq_url="$(aws_local sqs get-queue-url --queue-name "${dlq_name}" --query QueueUrl --output text 2>/dev/null || true)"
if value_missing "${dlq_url}"; then
  dlq_url="$(aws_local sqs create-queue --queue-name "${dlq_name}" --query QueueUrl --output text)"
fi
dlq_arn="$(aws_local sqs get-queue-attributes --queue-url "${dlq_url}" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"

queue_url="$(aws_local sqs get-queue-url --queue-name "${queue_name}" --query QueueUrl --output text 2>/dev/null || true)"
if value_missing "${queue_url}"; then
  queue_attributes="$(printf '{"VisibilityTimeout":"60","ReceiveMessageWaitTimeSeconds":"20","RedrivePolicy":"{\\"deadLetterTargetArn\\":\\"%s\\",\\"maxReceiveCount\\":\\"3\\"}"}' "${dlq_arn}")"
  queue_url="$(aws_local sqs create-queue --queue-name "${queue_name}" --attributes "${queue_attributes}" --query QueueUrl --output text)"
fi
queue_arn="$(aws_local sqs get-queue-attributes --queue-url "${queue_url}" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
# FLoCI returns a compose-network URL (`floci`) to the bootstrap container. Lambda
# runtimes are sibling Docker containers, so Docker Desktop reaches the emulator via host.docker.internal.
lambda_queue_url="$(printf '%s' "${queue_url}" | sed 's#://floci:#://host.docker.internal:#')"

ensure_role() {
  role_name="$1"
  if ! aws_local iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    echo "Creating IAM role ${role_name}..."
    aws_local iam create-role \
      --role-name "${role_name}" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  fi
}

ensure_role "${api_role_name}"
ensure_role "${mailer_role_name}"

api_role_arn="arn:aws:iam::${account_id}:role/${api_role_name}"
mailer_role_arn="arn:aws:iam::${account_id}:role/${mailer_role_name}"
table_arn="arn:aws:dynamodb:${region}:${account_id}:table/${table_name}"

aws_local iam put-role-policy \
  --role-name "${api_role_name}" \
  --policy-name "gemcenter-api" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:Query\",\"dynamodb:UpdateItem\"],\"Resource\":[\"${table_arn}\",\"${table_arn}/index/*\"]},{\"Effect\":\"Allow\",\"Action\":[\"sqs:SendMessage\"],\"Resource\":\"${queue_arn}\"}]}" >/dev/null

aws_local iam put-role-policy \
  --role-name "${mailer_role_name}" \
  --policy-name "gemcenter-ticket-mailer" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:UpdateItem\"],\"Resource\":\"${table_arn}\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${queue_arn}\"},{\"Effect\":\"Allow\",\"Action\":[\"ses:SendEmail\"],\"Resource\":\"*\"}]}" >/dev/null

package_lambda() {
  source_dir="$1"
  output_file="$2"
  temp_dir="/tmp/$(basename "${source_dir}")"
  rm -rf "${temp_dir}" "${output_file}"
  mkdir -p "${temp_dir}"
  cp "${source_dir}/index.js" "${source_dir}/package.json" "${temp_dir}/"
  (
    cd "${temp_dir}"
    npm install --omit=dev --no-audit --no-fund >/dev/null
    zip -qr "${output_file}" index.js package.json node_modules
  )
}

package_lambda /workspace/backend/register /tmp/gemcenter-api.zip
package_lambda /workspace/backend/mailer /tmp/gemcenter-mailer.zip

deploy_lambda() {
  function_name="$1"
  code_zip="$2"
  role_arn="$3"
  environment="$4"
  if aws_local lambda get-function --function-name "${function_name}" >/dev/null 2>&1; then
    # FLoCI's UpdateFunctionCode can block while it swaps a Docker-backed runtime.
    # Recreate is reliable for this local-only emulator and preserves DynamoDB/SQS state.
    echo "Recreating local Lambda ${function_name}..."
    aws_local lambda delete-function --function-name "${function_name}" >/dev/null
  fi
  echo "Creating Lambda ${function_name}..."
  aws_local lambda create-function \
    --function-name "${function_name}" \
    --runtime nodejs20.x \
    --handler index.handler \
    --role "${role_arn}" \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables=${environment}" \
    --zip-file "fileb://${code_zip}" >/dev/null
}

api_environment="{ATTENDEES_TABLE=${table_name},EVENT_ID=${event_id},DYNAMODB_ENDPOINT=${DYNAMODB_ENDPOINT},SQS_ENDPOINT=${SQS_ENDPOINT},TICKET_EMAIL_QUEUE_URL=${lambda_queue_url},EXPOSE_TICKET_TOKEN=${EXPOSE_TICKET_TOKEN}}"
mailer_environment="{ATTENDEES_TABLE=${table_name},EVENT_ID=${event_id},DYNAMODB_ENDPOINT=${DYNAMODB_ENDPOINT},SES_ENDPOINT=${SES_ENDPOINT},FROM_EMAIL=${FROM_EMAIL},EMAIL_PREVIEW_DATA_URI=true}"
deploy_lambda "${api_function_name}" /tmp/gemcenter-api.zip "${api_role_arn}" "${api_environment}"
deploy_lambda "${mailer_function_name}" /tmp/gemcenter-mailer.zip "${mailer_role_arn}" "${mailer_environment}"

mapping_uuid="$(aws_local lambda list-event-source-mappings --function-name "${mailer_function_name}" --event-source-arn "${queue_arn}" --query 'EventSourceMappings[0].UUID' --output text)"
if value_missing "${mapping_uuid}"; then
  echo "Connecting SQS to the ticket mailer Lambda..."
  aws_local lambda create-event-source-mapping \
    --function-name "${mailer_function_name}" \
    --event-source-arn "${queue_arn}" \
    --batch-size 1 >/dev/null
fi

api_id="$(aws_local apigatewayv2 get-apis --query "Items[?Name=='${api_name}'].ApiId | [0]" --output text)"
if value_missing "${api_id}"; then
  echo "Creating HTTP API..."
  api_id="$(aws_local apigatewayv2 create-api \
    --name "${api_name}" \
    --protocol-type HTTP \
    --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["content-type","authorization"]}' \
    --query ApiId --output text)"
fi

integration_uri="arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/arn:aws:lambda:${region}:${account_id}:function:${api_function_name}/invocations"
integration_id="$(aws_local apigatewayv2 get-integrations --api-id "${api_id}" --query "Items[?IntegrationUri=='${integration_uri}'].IntegrationId | [0]" --output text)"
if value_missing "${integration_id}"; then
  integration_id="$(aws_local apigatewayv2 create-integration \
    --api-id "${api_id}" \
    --integration-type AWS_PROXY \
    --integration-uri "${integration_uri}" \
    --payload-format-version 2.0 \
    --query IntegrationId --output text)"
fi

for route_key in "POST /registrations" "GET /attendees" "POST /check-ins"; do
  route_id="$(aws_local apigatewayv2 get-routes --api-id "${api_id}" --query "Items[?RouteKey=='${route_key}'].RouteId | [0]" --output text)"
  if value_missing "${route_id}"; then
    aws_local apigatewayv2 create-route \
      --api-id "${api_id}" \
      --route-key "${route_key}" \
      --target "integrations/${integration_id}" >/dev/null
  fi
done

aws_local apigatewayv2 create-stage \
  --api-id "${api_id}" \
  --stage-name '$default' \
  --auto-deploy >/dev/null 2>&1 || true

if ! aws_local lambda get-policy --function-name "${api_function_name}" --query "Policy" --output text 2>/dev/null | grep -q 'apigateway-register'; then
  aws_local lambda add-permission \
    --function-name "${api_function_name}" \
    --statement-id "apigateway-register" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${region}:${account_id}:${api_id}/*" >/dev/null
fi

cat > /state/local-stack.env <<EOF
AWS_ENDPOINT_URL=http://localhost:4566
AWS_DEFAULT_REGION=${region}
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
API_ID=${api_id}
API_URL=http://${api_id}.execute-api.localhost:4566/registrations
TICKET_EMAIL_QUEUE_URL=${queue_url}
FLOCI_CONSOLE_URL=http://localhost:4566/_floci/ui
EOF

echo "Local infrastructure is ready."
echo "FLoCI console: http://localhost:4566/_floci/ui"
echo "Registration API: http://${api_id}.execute-api.localhost:4566/registrations"
