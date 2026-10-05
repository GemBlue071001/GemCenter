#!/bin/sh
set -eu

endpoint="${AWS_ENDPOINT_URL}"
table_name="gemcenter-attendees"
function_name="gemcenter-register"
api_name="gemcenter-registration-api"
account_id="000000000000"
region="${AWS_DEFAULT_REGION}"
role_name="gemcenter-register-role"
role_arn="arn:aws:iam::${account_id}:role/${role_name}"

aws_local() {
  aws --endpoint-url "${endpoint}" "$@"
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
    --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes '[{"IndexName":"GSI1","KeySchema":[{"AttributeName":"GSI1PK","KeyType":"HASH"},{"AttributeName":"GSI1SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]'
  aws_local dynamodb wait table-exists --table-name "${table_name}"
fi

if ! aws_local iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
  echo "Creating Lambda IAM role..."
  aws_local iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi

aws_local iam put-role-policy \
  --role-name "${role_name}" \
  --policy-name "gemcenter-register-dynamodb" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\"],\"Resource\":\"arn:aws:dynamodb:${region}:${account_id}:table/${table_name}\"}]}" \
  >/dev/null

rm -f /tmp/register.zip
zip -j /tmp/register.zip /workspace/backend/register/index.js >/dev/null

if aws_local lambda get-function --function-name "${function_name}" >/dev/null 2>&1; then
  echo "Updating Lambda ${function_name}..."
  aws_local lambda update-function-code \
    --function-name "${function_name}" \
    --zip-file fileb:///tmp/register.zip >/dev/null
  aws_local lambda wait function-updated --function-name "${function_name}" || true
else
  echo "Creating Lambda ${function_name}..."
  aws_local lambda create-function \
    --function-name "${function_name}" \
    --runtime nodejs20.x \
    --handler index.handler \
    --role "${role_arn}" \
    --timeout 10 \
    --memory-size 256 \
    --environment "Variables={ATTENDEES_TABLE=${table_name},DYNAMODB_ENDPOINT=${DYNAMODB_ENDPOINT}}" \
    --zip-file fileb:///tmp/register.zip >/dev/null
fi

api_id="$(aws_local apigatewayv2 get-apis --query "Items[?Name=='${api_name}'].ApiId | [0]" --output text)"
if [ "${api_id}" = "None" ] || [ "${api_id}" = "null" ] || [ -z "${api_id}" ]; then
  echo "Creating HTTP API..."
  api_id="$(aws_local apigatewayv2 create-api \
    --name "${api_name}" \
    --protocol-type HTTP \
    --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["POST","OPTIONS"],"AllowHeaders":["content-type"]}' \
    --query ApiId --output text)"

  integration_id="$(aws_local apigatewayv2 create-integration \
    --api-id "${api_id}" \
    --integration-type AWS_PROXY \
    --integration-uri "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/arn:aws:lambda:${region}:${account_id}:function:${function_name}/invocations" \
    --payload-format-version 2.0 \
    --query IntegrationId --output text)"

  aws_local apigatewayv2 create-route \
    --api-id "${api_id}" \
    --route-key "POST /registrations" \
    --target "integrations/${integration_id}" >/dev/null

  aws_local apigatewayv2 create-stage \
    --api-id "${api_id}" \
    --stage-name '$default' \
    --auto-deploy >/dev/null

  aws_local lambda add-permission \
    --function-name "${function_name}" \
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
FLOCI_CONSOLE_URL=http://localhost:4566/_floci/ui
EOF

echo "Local infrastructure is ready."
echo "FLoCI console: http://localhost:4566/_floci/ui"
echo "Registration API: http://${api_id}.execute-api.localhost:4566/registrations"
