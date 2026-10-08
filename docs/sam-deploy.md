# Deploy GemCenter backend bằng AWS SAM

Template ở [`template.yaml`](../template.yaml) dựng một stack riêng cho mỗi môi trường: DynamoDB, SQS + DLQ, API Lambda, mailer Lambda, HTTP API, Cognito user pool và group `checkin-staff`, CloudWatch logs/alarms. `compose.yaml` và `infra/bootstrap/bootstrap.sh` chỉ dùng cho FLoCI local.

Muốn chạy API Lambda do SAM đóng gói với FLoCI trước khi deploy, xem [hướng dẫn SAM local](sam-local-floci.md).

## 1. Chuẩn bị

- Cài [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) và [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html). Node.js 22 là runtime của hai Lambda.
- Dùng AWS profile có quyền deploy CloudFormation, Lambda, DynamoDB, SQS, API Gateway, Cognito, IAM, CloudWatch và SES.
- Chọn một region cho toàn bộ stack và SES; ví dụ `ap-southeast-1`.
- Có một origin của landing page, ví dụ `https://event.example.com`. CORS nhận **origin**, không có path hoặc dấu `/` cuối.
- Verify `FromEmail` hoặc domain chứa email đó trong SES tại cùng region. Khi SES còn sandbox, email nhận thử cũng phải được verify. Xin [SES production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html) trước khi gửi cho khách thật.

Kiểm tra account trước khi tạo resource có tính phí:

```powershell
aws sso login --profile gemcenter
aws sts get-caller-identity --profile gemcenter
aws --version
sam --version
```

Nếu team dùng AWS profile khác, thay `gemcenter` trong các lệnh dưới đây. Không lưu access key vào repo hoặc Lambda environment variables.

## 2. Kiểm tra và deploy staging

Chạy tại thư mục gốc repo:

```powershell
sam validate --template-file template.yaml --lint
sam build --template-file template.yaml
sam deploy --guided --stack-name gemcenter-staging --region ap-southeast-1 --profile gemcenter --capabilities CAPABILITY_IAM
```

Khi `sam deploy --guided` hỏi parameter, nhập `EventId`, `FromEmail`, `AllowedOrigin` thật cho staging. Kiểm tra lại account, region, parameter và bản change set trước khi đồng ý deploy. SAM có thể lưu cấu hình vào `samconfig.toml`; file này được ignore vì chứa lựa chọn của máy/môi trường. Những lần cập nhật sau có thể dùng `sam build` rồi `sam deploy --profile gemcenter` nếu cấu hình đã được lưu. Nếu `sam validate --lint` báo thiếu `cfn-lint`, cài theo hướng dẫn của SAM CLI rồi chạy lại.

`template.yaml` đặt tên Lambda theo stack, còn DynamoDB, queue và API nhận tên do CloudFormation sinh. Vì vậy có thể tạo `gemcenter-staging` và `gemcenter-prod` trong cùng account/region mà không trùng tên resource. DynamoDB và Cognito user pool có `Retain`: xóa stack không xóa dữ liệu attendee hoặc tài khoản nhân viên; các resource được giữ lại phải được quản lý thủ công sau đó.

## 3. Lấy endpoint và kiểm tra

```powershell
aws cloudformation describe-stacks `
  --stack-name gemcenter-staging `
  --query 'Stacks[0].Outputs' `
  --profile gemcenter `
  --region ap-southeast-1
```

Outputs có `RegistrationUrl`, `ApiBaseUrl`, tên bảng, URL queue/DLQ, `StaffUserPoolId` và `StaffAppClientId`. Gửi một đăng ký bằng email nhận đã verify nếu SES còn sandbox:

```powershell
$registrationUrl = aws cloudformation describe-stacks `
  --stack-name gemcenter-staging `
  --query "Stacks[0].Outputs[?OutputKey=='RegistrationUrl'].OutputValue | [0]" `
  --output text `
  --profile gemcenter `
  --region ap-southeast-1

$body = @{
  fullName = 'Nguyen Van A'
  email = 'verified-recipient@example.com'
  phone = '0900000000'
  company = 'Gem Center'
  program = 'Su kien thu nghiem'
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri $registrationUrl -ContentType 'application/json' -Body $body
```

Kỳ vọng HTTP 201 với `emailStatus: "queued"`. Sau đó kiểm tra record trong DynamoDB, email/QR nhận được, log `/aws/lambda/gemcenter-staging-ticket-mailer`, và DLQ rỗng. `POST /registrations` là public. `GET /attendees` và `POST /check-ins` phải trả 401 khi không có JWT. Tạo nhân viên trong Cognito user pool, thêm vào group `checkin-staff`, rồi dùng **access token** từ client đăng nhập để thử hai route đó. Template tạo user pool/client/group nhưng chưa tạo giao diện đăng nhập.

CloudWatch alarms trong template hiển thị lỗi Lambda và message trong DLQ. Chúng chưa có SNS action; cấu hình kênh nhận cảnh báo trước khi vận hành thật.

## 4. Trước khi mở production

Các issue P1 trong [backend issue report](backend-issue-report.md) vẫn cần sửa. Template hạ tầng không giải quyết race `emailStatus`, trường hợp SQS lỗi làm mất khả năng gửi lại vé, hoặc đăng ký trùng. Cũng cần xác nhận SES đã được cấp production access, tạo tài khoản check-in, kiểm tra CORS trên landing page thật, và thử toàn bộ luồng với một vé thật. Chỉ sau đó deploy stack production bằng tên riêng, ví dụ `gemcenter-prod`.

## Tài liệu AWS liên quan

- [SAM build và đóng gói Node.js Lambda](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-using-build.html)
- [SAM HTTP API JWT authorizer](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-controlling-access-to-apis-oauth2-authorizer.html)
- [SQS visibility timeout với Lambda](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html)
- [SES verified identities](https://docs.aws.amazon.com/ses/latest/dg/verify-addresses-and-domains.html)
