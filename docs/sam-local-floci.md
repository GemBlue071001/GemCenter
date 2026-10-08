# Test SAM local với FLoCI

SAM CLI chạy API Lambda trong Docker; FLoCI cung cấp DynamoDB, SQS và SES giả lập. [`template.local.yaml`](../template.local.yaml) trỏ tới cùng source Lambda với [`template.yaml`](../template.yaml), nhưng chỉ mở route đăng ký để tránh phụ thuộc vào Cognito JWT authorizer khi test local. SAM dùng trực tiếp source của API, còn FLoCI tiếp tục chạy mailer qua queue. Không cần deploy resource lên AWS thật.

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

Script đọc queue URL từ `.floci-data/local-stack.env`, đổi hostname sang `host.docker.internal` để container SAM truy cập được FLoCI, tạo `.floci-data/sam-local-env.json`, cài Node dependencies vào `backend/register/node_modules` khi manifest thay đổi, rồi chạy `sam local start-api` trực tiếp từ `template.local.yaml` ở port 3000. Mọi AWS credential giả lập được đặt tạm trong process và khôi phục khi script kết thúc.

Khi sửa `backend/register/index.js`, cứ lưu file rồi gửi request lại tới port 3000; **không chạy lại `sam build` hoặc `docker compose run --rm bootstrap`**. SAM local sẽ đọc source trực tiếp. Chỉ khởi động lại script nếu bạn sửa `template.local.yaml`, `package.json` hoặc file cấu hình FLoCI. Nếu vừa chạy `sam build` cho production, script này vẫn ép SAM dùng `template.local.yaml` gốc.

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

- `sam local start-api` chạy **RegisterFunction** từ source và Node dependencies tại chỗ. FLoCI event-source mapping hiện vẫn chạy **mailer Lambda của FLoCI**, dùng cùng source nhưng package riêng. Vì vậy sửa `backend/mailer/index.js` vẫn cần cập nhật Lambda trong FLoCI (xem phần dưới).
- SAM local không tạo Cognito user pool hay thực thi đầy đủ JWT authorizer của API Gateway. Kiểm tra authorizer và IAM của template trên AWS staging.
- `sam validate --template-file template.yaml --lint` kiểm tra template; `sam build` kiểm tra đóng gói. Hai lệnh này không kiểm tra resource được CloudFormation tạo thành công trên AWS.
- Nếu port 3000 bận, dùng `./scripts/run-sam-local.ps1 -Port 3001`; URL API đổi thành `http://127.0.0.1:3001/registrations`.

Tắt môi trường local bằng Ctrl+C ở terminal SAM rồi chạy `docker compose down`. Dữ liệu FLoCI được giữ trong `.floci-data` cho lần sau.

## Khi sửa mailer

Mailer đang được FLoCI gọi từ package đã upload, nên thay đổi `backend/mailer/index.js` không tự cập nhật như API Lambda của SAM. Chạy `docker compose run --rm bootstrap` sau khi sửa mailer. Bootstrap chỉ đóng gói lại Lambda có source hoặc cấu hình thay đổi và dùng npm cache lưu trong `.floci-data`; lần chạy sau sẽ nhanh hơn. Không cần khởi động lại SAM API.
