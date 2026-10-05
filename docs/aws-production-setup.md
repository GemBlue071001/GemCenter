# Triển khai registration API lên AWS

Tài liệu này tạo bản production đầu tiên của backend đăng ký sự kiện:

```text
Landing page -> API Gateway HTTP API -> Lambda -> DynamoDB
                                      -> CloudWatch Logs
```

Chưa bao gồm Cognito/admin, QR, SES email hay Zalo. Những phần đó sẽ được thêm ở phase sau. Các lệnh dưới đây tạo resource thật trong AWS account, không phải FLoCI.

> Khuyến nghị dùng region `ap-southeast-1` (Singapore) cho người dùng tại Việt Nam. Thay đổi một lần tại bước 1 nếu team chọn region khác.

## 0. Chuẩn bị

- AWS account có quyền tạo DynamoDB, Lambda, API Gateway, IAM role/policy và CloudWatch Logs.
- AWS CLI v2 đã đăng nhập: `aws configure sso` hoặc `aws configure`.
- Node.js 20+ và npm để đóng gói Lambda.
- Có landing-page domain dự kiến, ví dụ `https://event.gemcenter.com`. Domain này dùng ở cấu hình CORS.

Kiểm tra identity trước khi tạo bất cứ resource nào:

```powershell
aws sts get-caller-identity
```

Nếu identity/account sai, dừng ở đây và đổi AWS profile. Không dùng access key của production trong source code hoặc file `.env` đã commit.

## 1. Khai báo biến PowerShell

Chạy tại thư mục gốc project:

```powershell
$env:AWS_REGION = 'ap-southeast-1'
$env:AWS_DEFAULT_REGION = $env:AWS_REGION

$project = 'gemcenter'
$tableName = "$project-attendees"
$functionName = "$project-register"
$roleName = "$project-register-role"
$apiName = "$project-registration-api"
$accountId = (aws sts get-caller-identity --query Account --output text)
```

## 2. Tạo DynamoDB table

Bảng dùng single-table keys `PK` + `SK`. GSI1 phục vụ truy tìm application theo email ở phase admin sau này.

```powershell
aws dynamodb create-table `
  --table-name $tableName `
  --billing-mode PAY_PER_REQUEST `
  --attribute-definitions `
    AttributeName=PK,AttributeType=S `
    AttributeName=SK,AttributeType=S `
    AttributeName=GSI1PK,AttributeType=S `
    AttributeName=GSI1SK,AttributeType=S `
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE `
  --global-secondary-indexes '[{"IndexName":"GSI1","KeySchema":[{"AttributeName":"GSI1PK","KeyType":"HASH"},{"AttributeName":"GSI1SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' `
  --region $env:AWS_REGION

aws dynamodb wait table-exists --table-name $tableName --region $env:AWS_REGION
```

`PAY_PER_REQUEST` phù hợp với traffic event không đều; chưa cần capacity planning. Lambda sẽ ghi một attendee theo `PutItem`. Xem [DynamoDB conditional expressions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.OperatorsAndFunctions.html) trước khi thêm logic chống đăng ký trùng/check-in trùng.

## 3. Tạo IAM role tối thiểu cho Lambda

Tạo file trust policy tạm thời tại `infra/aws/lambda-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Tạo role, gắn quyền ghi đúng một DynamoDB table và policy ghi CloudWatch Logs:

```powershell
aws iam create-role `
  --role-name $roleName `
  --assume-role-policy-document file://infra/aws/lambda-trust-policy.json

$tableArn = "arn:aws:dynamodb:$($env:AWS_REGION):$accountId`:table/$tableName"

@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem"],
      "Resource": "$tableArn"
    }
  ]
}
"@ | Set-Content -Encoding utf8 infra/aws/register-dynamodb-policy.json

aws iam put-role-policy `
  --role-name $roleName `
  --policy-name "$project-register-dynamodb" `
  --policy-document file://infra/aws/register-dynamodb-policy.json

aws iam attach-role-policy `
  --role-name $roleName `
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

Không gắn `AmazonDynamoDBFullAccess`; Lambda này chỉ cần `PutItem` vào table của chính nó.

## 4. Đóng gói Lambda

Production không dùng `DYNAMODB_ENDPOINT`: AWS SDK sẽ tự gọi DynamoDB thật theo region. Tạo package dependency trong thư mục handler:

```powershell
Push-Location backend/register
npm init -y
npm install @aws-sdk/client-dynamodb
Compress-Archive -Path index.js,node_modules -DestinationPath ..\..\dist\gemcenter-register.zip -Force
Pop-Location
```

`dist/` và `node_modules/` đã nằm trong `.gitignore`; source handler vẫn là file cần commit. Với project thật, nên chuyển phần package/deploy này sang CDK hoặc GitHub Actions trước khi có production deployment thường xuyên.

## 5. Tạo Lambda

```powershell
$roleArn = "arn:aws:iam::$accountId`:role/$roleName"

aws lambda create-function `
  --function-name $functionName `
  --runtime nodejs20.x `
  --handler index.handler `
  --role $roleArn `
  --timeout 10 `
  --memory-size 256 `
  --environment "Variables={ATTENDEES_TABLE=$tableName}" `
  --zip-file fileb://dist/gemcenter-register.zip `
  --region $env:AWS_REGION
```

Sau này để cập nhật code:

```powershell
aws lambda update-function-code `
  --function-name $functionName `
  --zip-file fileb://dist/gemcenter-register.zip `
  --region $env:AWS_REGION
```

Tạo log group chủ động và giữ log 30 ngày để kiểm tra đăng ký, nhưng tránh lưu dữ liệu cá nhân lâu không cần thiết:

```powershell
aws logs create-log-group --log-group-name "/aws/lambda/$functionName" --region $env:AWS_REGION
aws logs put-retention-policy `
  --log-group-name "/aws/lambda/$functionName" `
  --retention-in-days 30 `
  --region $env:AWS_REGION
```

Nếu log group đã được Lambda tự tạo, lệnh `create-log-group` có thể báo đã tồn tại; khi đó chạy tiếp lệnh retention policy.

## 6. Tạo API Gateway HTTP API

HTTP API đủ cho registration endpoint, ít cấu hình hơn REST API và tích hợp trực tiếp Lambda. Tham khảo [AWS HTTP API documentation](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api.html).

Thay `https://event.gemcenter.com` thành domain thật trước khi chạy:

```powershell
$landingOrigin = 'https://event.gemcenter.com'

$cors = @{
  AllowOrigins = @($landingOrigin)
  AllowMethods = @('POST', 'OPTIONS')
  AllowHeaders = @('content-type')
  MaxAge = 86400
} | ConvertTo-Json -Compress

$apiId = aws apigatewayv2 create-api `
  --name $apiName `
  --protocol-type HTTP `
  --cors-configuration $cors `
  --query ApiId `
  --output text `
  --region $env:AWS_REGION

$lambdaArn = "arn:aws:lambda:$($env:AWS_REGION):$accountId`:function:$functionName"
$integrationUri = "arn:aws:apigateway:$($env:AWS_REGION):lambda:path/2015-03-31/functions/$lambdaArn/invocations"

$integrationId = aws apigatewayv2 create-integration `
  --api-id $apiId `
  --integration-type AWS_PROXY `
  --integration-uri $integrationUri `
  --payload-format-version '2.0' `
  --query IntegrationId `
  --output text `
  --region $env:AWS_REGION

aws apigatewayv2 create-route `
  --api-id $apiId `
  --route-key 'POST /registrations' `
  --target "integrations/$integrationId" `
  --region $env:AWS_REGION

aws apigatewayv2 create-stage `
  --api-id $apiId `
  --stage-name '$default' `
  --auto-deploy `
  --region $env:AWS_REGION

aws lambda add-permission `
  --function-name $functionName `
  --statement-id 'allow-api-gateway-register' `
  --action lambda:InvokeFunction `
  --principal apigateway.amazonaws.com `
  --source-arn "arn:aws:execute-api:$($env:AWS_REGION):$accountId`:$apiId/*" `
  --region $env:AWS_REGION

$apiUrl = "https://$apiId.execute-api.$($env:AWS_REGION).amazonaws.com/registrations"
Write-Host "Registration endpoint: $apiUrl"
```

Không để CORS `*` trên production nếu đã biết landing page domain. API đăng ký vẫn là endpoint public; ở phase trước launch bổ sung rate limit/WAF CAPTCHA, validation kỹ hơn và consent checkbox cho dữ liệu cá nhân.

## 7. Test production endpoint

```powershell
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

Kỳ vọng HTTP 201 với `attendeeId`, `ticketToken`, `status: "registered"`. Kiểm tra record:

```powershell
aws dynamodb query `
  --table-name $tableName `
  --key-condition-expression 'PK = :pk' `
  --expression-attribute-values '{":pk":{"S":"EVENT#iti-2026"}}' `
  --region $env:AWS_REGION
```

Nếu lỗi, xem CloudWatch log group `/aws/lambda/gemcenter-register`; không log toàn bộ request body hoặc `ticketToken` ở production.

## 8. Bước phải làm trước khi public landing page

1. Thay event hard-code `iti-2026` bằng event configuration/table hoặc environment variable.
2. Chống spam: CAPTCHA, AWS WAF rate-based rule hoặc rate-limit ở API layer.
3. Thêm privacy notice và checkbox đồng ý xử lý thông tin liên hệ.
4. Thêm SQS + SES để QR/email được gửi bất đồng bộ; đừng gửi mail trực tiếp trong Lambda đăng ký.
5. Thiết lập CloudWatch alarms cho Lambda errors, throttles và DLQ messages.
6. Chỉ sau đó mới thêm endpoint admin/check-in cùng Cognito và conditional update cho `checkedInAt`.

## 9. Dọn resource sau event

Không chạy phần này nếu còn cần export dữ liệu. Hãy export/backup attendee data trước, sau đó mới xóa Lambda, API, log group và DynamoDB. DynamoDB table deletion không thể undo.

```powershell
aws apigatewayv2 delete-api --api-id $apiId --region $env:AWS_REGION
aws lambda delete-function --function-name $functionName --region $env:AWS_REGION
aws logs delete-log-group --log-group-name "/aws/lambda/$functionName" --region $env:AWS_REGION
aws dynamodb delete-table --table-name $tableName --region $env:AWS_REGION
```

Giữ IAM role nếu sắp tổ chức event khác; nếu không, xóa inline policy trước rồi xóa role.
