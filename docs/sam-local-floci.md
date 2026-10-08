# Test SAM local với FLoCI

SAM CLI chạy API Lambda trong Docker; FLoCI cung cấp DynamoDB, SQS và SES giả lập. [`template.local.yaml`](../template.local.yaml) trỏ tới cùng source Lambda với [`template.yaml`](../template.yaml), nhưng chỉ mở route đăng ký để tránh phụ thuộc vào Cognito JWT authorizer khi test local. Cách này test code API đã được SAM đóng gói, và FLoCI tiếp tục chạy mailer qua queue. Không cần deploy resource lên AWS thật.

## Chạy

Mở hai terminal PowerShell tại thư mục gốc repo. Cần Docker Desktop và AWS SAM CLI.

Terminal 1:

```powershell
docker compose up --build -d
docker compose logs -f bootstrap
```

Chờ dòng `Local infrastructure is ready`, rồi dừng lệnh `logs -f` bằng Ctrl+C; container FLoCI vẫn chạy.

Terminal 2:

```powershell
./scripts/run-sam-local.ps1
```

Script đọc queue URL từ `.floci-data/local-stack.env`, đổi hostname sang `host.docker.internal` để container SAM truy cập được FLoCI, tạo `.floci-data/sam-local-env.json`, chạy `sam build --template-file template.local.yaml`, rồi chạy `sam local start-api` ở port 3000. Mọi AWS credential giả lập được đặt tạm trong process và khôi phục khi script kết thúc. Script build lại mỗi lần để tránh dùng nhầm package từ template production.

Terminal 3 để gửi đăng ký:

```powershell
$body = @{
  fullName = 'Nguyen Van A'
  email = 'nguyenvana@example.test'
  phone = '0900000000'
  company = 'Gem Center'
  program = 'Su kien thu nghiem'
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:3000/registrations' -ContentType 'application/json' -Body $body
```

Kỳ vọng HTTP 201 với `emailStatus: "queued"` và `ticketToken` (chỉ bật ở local). Xem DynamoDB record và email QR trong [FLoCI Console](http://localhost:4566/_floci/ui). Các lỗi hiện biết của nghiệp vụ vẫn được theo dõi ở [backend issue report](backend-issue-report.md).

## Phạm vi kiểm tra

- `sam local start-api` chạy **RegisterFunction** từ package SAM. FLoCI event-source mapping hiện vẫn chạy **mailer Lambda của FLoCI**, dùng cùng source nhưng package riêng. Vì vậy bài test này chưa xác minh package SAM của MailerFunction.
- SAM local không tạo Cognito user pool hay thực thi đầy đủ JWT authorizer của API Gateway. Kiểm tra authorizer và IAM của template trên AWS staging.
- `sam validate --template-file template.yaml --lint` kiểm tra template; `sam build` kiểm tra đóng gói. Hai lệnh này không kiểm tra resource được CloudFormation tạo thành công trên AWS.
- Nếu port 3000 bận, dùng `./scripts/run-sam-local.ps1 -Port 3001`; URL API đổi thành `http://127.0.0.1:3001/registrations`.

Tắt môi trường local bằng Ctrl+C ở terminal SAM rồi chạy `docker compose down`. Dữ liệu FLoCI được giữ trong `.floci-data` cho lần sau.
