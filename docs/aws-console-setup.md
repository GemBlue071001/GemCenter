# Tạo GemCenter registration API bằng AWS Console

> Lưu ý: hướng dẫn khởi tạo DynamoDB, Cognito và API Gateway trong file này vẫn dùng được. Phần gửi email đã được tách thành SQS + Mailer Lambda; xem [email-delivery-architecture.md](email-delivery-architecture.md) để tạo quyền và resource email đúng với code hiện tại. Không gắn quyền SES trực tiếp cho API Lambda.

Tài liệu này dùng **AWS Management Console**, không dùng AWS CLI để tạo resource. Mục tiêu của phase hiện tại:

```text
API Gateway HTTP API -> Lambda gemcenter-register -> DynamoDB gemcenter-attendees
```

Chưa có admin, Cognito, QR, SES email hoặc Zalo. Hãy dùng một AWS Region thống nhất. Khuyến nghị: **Asia Pacific (Singapore) - `ap-southeast-1`**.

## Trước khi bắt đầu

1. Đăng nhập đúng AWS account của dự án.
2. Chọn region `ap-southeast-1` ở menu góc phải trên AWS Console.
3. Cần có quyền tạo DynamoDB, Lambda, IAM Role, API Gateway và CloudWatch Logs.
4. Không đưa AWS access key vào source code, Lambda environment variables hoặc Git.

## 1. Tạo DynamoDB table

Mở **DynamoDB** -> **Tables** -> **Create table**.

Điền các giá trị:

| Trường | Giá trị |
| --- | --- |
| Table name | `gemcenter-attendees` |
| Partition key | `PK` - String |
| Sort key | `SK` - String |
| Table settings | Customize settings |
| Capacity mode | On-demand |

Bấm **Create table**.

### Tạo index tìm theo email

Sau khi table active, mở table -> tab **Indexes** -> **Create index**.

| Trường | Giá trị |
| --- | --- |
| Partition key | `GSI1PK` - String |
| Sort key | `GSI1SK` - String |
| Index name | `GSI1` |
| Projection | All |
| Capacity mode | On-demand |

Bấm **Create index** và chờ trạng thái index là `Active`.

### Tạo index tìm ticket khi quét QR

Lặp lại **Indexes** -> **Create index** với các giá trị:

| Trường | Giá trị |
| --- | --- |
| Partition key | `GSI2PK` - String |
| Sort key | `GSI2SK` - String |
| Index name | `GSI2` |
| Projection | All |
| Capacity mode | On-demand |

`GSI2` được dùng để tìm attendee từ hash của `ticketToken`; QR không chứa dữ liệu cá nhân.

## 2. Tạo IAM Role cho Lambda

Mở **IAM** -> **Roles** -> **Create role**.

1. Chọn **AWS service**.
2. Chọn use case **Lambda**.
3. Bấm **Next**.
4. Tìm, chọn policy `AWSLambdaBasicExecutionRole`.
5. Bấm **Next**.
6. Đặt Role name: `gemcenter-register-role`.
7. Bấm **Create role**.

### Chỉ cấp quyền ghi vào table này

Mở role `gemcenter-register-role` -> tab **Permissions** -> **Add permissions** -> **Create inline policy** -> tab **JSON**.

Thay `YOUR_ACCOUNT_ID` bằng AWS Account ID thực tế, rồi dán:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:UpdateItem"],
      "Resource": [
        "arn:aws:dynamodb:ap-southeast-1:YOUR_ACCOUNT_ID:table/gemcenter-attendees",
        "arn:aws:dynamodb:ap-southeast-1:YOUR_ACCOUNT_ID:table/gemcenter-attendees/index/*"
      ]
    }
  ]
}
```

Bấm **Next**, đặt tên `gemcenter-register-dynamodb`, rồi bấm **Create policy**.

> Không dùng policy `AmazonDynamoDBFullAccess`: Lambda đăng ký hiện chỉ cần `PutItem` vào một table duy nhất.

## 3. Đóng gói Lambda để upload

Giao diện AWS Console upload file ZIP; hãy đóng gói code trước bằng terminal tại thư mục project:

```powershell
cd backend\register
npm init -y
npm install @aws-sdk/client-dynamodb @aws-sdk/client-sesv2 qrcode

New-Item -ItemType Directory -Force ..\..\dist
Compress-Archive -Path index.js,node_modules -DestinationPath ..\..\dist\gemcenter-register.zip -Force
cd ..\..
```

File cần upload là `dist\gemcenter-register.zip`.

## 4. Tạo Lambda Function

Mở **Lambda** -> **Create function**.

| Trường | Giá trị |
| --- | --- |
| Method | Author from scratch |
| Function name | `gemcenter-register` |
| Runtime | Node.js 20.x |
| Architecture | x86_64 |
| Execution role | Use an existing role |
| Existing role | `gemcenter-register-role` |

Bấm **Create function**.

### Upload code

Trong Lambda vừa tạo:

1. Vào tab **Code**.
2. Chọn **Upload from** -> **.zip file**.
3. Chọn `dist\gemcenter-register.zip`.
4. Bấm **Save**.

### Thêm environment variable

Vào **Configuration** -> **Environment variables** -> **Edit** -> **Add environment variable**.

| Key | Value |
| --- | --- |
| `ATTENDEES_TABLE` | `gemcenter-attendees` |
| `FROM_EMAIL` | `no-reply@your-domain.com` |

Không tạo `DYNAMODB_ENDPOINT`; biến đó chỉ dùng cho FLoCI local.

## 5. Cấu hình Amazon SES để gửi QR email

Mở **Amazon SES** trong cùng region `ap-southeast-1` -> **Verified identities** -> **Create identity**.

1. Chọn **Domain** và nhập domain gửi mail, ví dụ `gemcenter.com`.
2. Bật **Easy DKIM**, tạo identity, rồi sao chép DNS CNAME records SES cung cấp sang DNS provider của domain.
3. Chờ identity có trạng thái `Verified`, rồi đặt `FROM_EMAIL` thành một email thuộc domain này, ví dụ `no-reply@gemcenter.com`.

Trong IAM role `gemcenter-register-role`, thêm inline policy sau và đặt tên `gemcenter-register-ses`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ses:SendEmail"],
      "Resource": "*"
    }
  ]
}
```

SES account mới thường ở sandbox: chỉ gửi được đến recipient đã verify. Trước event, vào SES **Account dashboard** và gửi yêu cầu **Request production access** để gửi được tới email khách mời. [SES identity verification](https://docs.aws.amazon.com/ses/latest/dg/verify-addresses-and-domains.html) và [sandbox production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).

### Cấu hình runtime

Vào **Configuration** -> **General configuration** -> **Edit**:

| Trường | Giá trị |
| --- | --- |
| Memory | 256 MB |
| Timeout | 10 seconds |

Bấm **Save**.

## 6. Test Lambda trực tiếp

Trong Lambda chọn tab **Test** -> **Create new event**. Đặt tên tùy ý, ví dụ `register-success`, rồi dán payload:

```json
{
  "version": "2.0",
  "routeKey": "POST /registrations",
  "rawPath": "/registrations",
  "headers": {
    "content-type": "application/json"
  },
  "requestContext": {
    "http": {
      "method": "POST",
      "path": "/registrations"
    }
  },
  "isBase64Encoded": false,
  "body": "{\"fullName\":\"Nguyen Van A\",\"email\":\"nguyenvana@example.test\",\"phone\":\"0900000000\",\"company\":\"Gem Center\",\"title\":\"Guest\",\"program\":\"Trien lam cong nghe yen tiec\"}"
}
```

Bấm **Test**. Kết quả đúng là Lambda trả `statusCode: 201` với `attendeeId`, `status`, `registeredAt` và `emailStatus: "sent"`. Production không trả ticket token trong API response; token chỉ nằm trong QR email. Kiểm tra inbox recipient để xem email và QR.

Để kiểm tra database, mở **DynamoDB** -> `gemcenter-attendees` -> **Explore table items**. Sẽ có một record với `PK` là `EVENT#iti-2026`.

## 7. Tạo API Gateway HTTP API

Mở **API Gateway** -> **Create API** -> tại **HTTP API** bấm **Build**.

### Chọn integration và route

1. Ở phần Integrations, chọn **Lambda**.
2. Chọn Lambda function `gemcenter-register`.
3. API name: `gemcenter-registration-api`.
4. Tạo các route:
   - Method: `POST`
   - Resource path: `/registrations`
   - Method: `GET`
   - Resource path: `/attendees`
   - Method: `POST`
   - Resource path: `/check-ins`
5. Bấm **Next**, sau đó **Create**.

API Gateway Console sẽ tự thêm quyền để API Gateway gọi Lambda. Nếu không invoke được, quay lại Lambda -> **Configuration** -> **Permissions** và kiểm tra resource-based policy có principal `apigateway.amazonaws.com`.

### Cấu hình CORS

Trong API Gateway vừa tạo, chọn **CORS** -> **Configure**:

| Trường | Giá trị production |
| --- | --- |
| Access-Control-Allow-Origin | `https://event.gemcenter.com` |
| Access-Control-Allow-Headers | `content-type, authorization` |
| Access-Control-Allow-Methods | `GET, POST` |
| Access-Control-Max-Age | `86400` |

Trong lúc frontend chạy local, có thể thêm `http://localhost:3000` hoặc URL dev thực tế. Không nên để `*` khi đã có domain production.

### Lấy endpoint

Vào **Stages** -> `$default`. Copy **Invoke URL**, rồi thêm `/registrations` ở cuối:

```text
https://<api-id>.execute-api.ap-southeast-1.amazonaws.com/registrations
```

## 8. Bảo vệ route check-in và attendee bằng Cognito

Hai route `GET /attendees` và `POST /check-ins` không được public. Tạo Cognito User Pool cho nhân viên check-in, tạo group `checkin-staff`, rồi chỉ thêm tài khoản nhân viên vào group này.

Trong API Gateway HTTP API -> **Authorizers** -> **Create**:

| Trường | Giá trị |
| --- | --- |
| Authorizer type | JWT |
| Identity source | `$request.header.Authorization` |
| Issuer URL | `https://cognito-idp.ap-southeast-1.amazonaws.com/<USER_POOL_ID>` |
| Audience | Cognito App Client ID |

Sau đó mở từng route `GET /attendees` và `POST /check-ins` -> **Edit** -> chọn JWT authorizer vừa tạo. Giữ `POST /registrations` là `NONE`/public.

Check-in web gửi access token của nhân viên:

```http
Authorization: Bearer <cognito-access-token>
```

API Gateway xác minh JWT trước; Lambda tiếp tục kiểm tra claim `cognito:groups` có `checkin-staff` hay không. Khi không có token, API trả `401`; token hợp lệ nhưng không thuộc group trả `403`.

## 9. Test API Gateway

Trong Postman hoặc Insomnia:

| Phần | Giá trị |
| --- | --- |
| Method | `POST` |
| URL | Invoke URL + `/registrations` |
| Header | `Content-Type: application/json` |

Body raw JSON:

```json
{
  "fullName": "Nguyen Van A",
  "email": "nguyenvana@example.test",
  "phone": "0900000000",
  "company": "Gem Center",
  "title": "Guest",
  "program": "Trien lam cong nghe yen tiec"
}
```

Kỳ vọng HTTP `201`. Record mới sẽ xuất hiện tại DynamoDB.

## 10. CloudWatch Logs

Mở **CloudWatch** -> **Log groups** -> `/aws/lambda/gemcenter-register`.

Nếu Lambda bị lỗi, chọn log stream mới nhất để xem nguyên nhân. Trước khi public, đặt retention về 30 ngày:

1. Chọn log group `/aws/lambda/gemcenter-register`.
2. Chọn **Actions** -> **Edit retention setting**.
3. Chọn **1 month**.

Không ghi raw request body, email, phone hoặc `ticketToken` vào log production.

## 11. Checklist trước khi public landing page

- [ ] CORS chỉ cho phép domain landing page thật.
- [ ] Thêm CAPTCHA/rate limit để chống bot gửi form.
- [ ] Landing page có privacy notice và consent xử lý thông tin cá nhân.
- [ ] `ticketToken` chỉ dùng cho QR; QR không chứa tên, email hoặc số điện thoại.
- [ ] Thêm SQS + SES để gửi QR/email bất đồng bộ, không gửi mail ngay trong Lambda đăng ký.
- [ ] Thiết lập CloudWatch alarm cho Lambda errors và throttles.
- [ ] Không delete DynamoDB sau event trước khi export dữ liệu attendee.

## Tài liệu AWS

- [API Gateway HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api.html)
- [AWS Lambda console](https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html)
- [DynamoDB Developer Guide](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html)
