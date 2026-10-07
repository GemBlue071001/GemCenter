# Gửi QR email bất đồng bộ: SQS + Mailer Lambda

Đây là kiến trúc hiện tại của code, thay cho việc gửi SES trực tiếp trong API Lambda.

```text
POST /registrations
  -> gemcenter-register Lambda
  -> DynamoDB (emailStatus = pending)
  -> SQS gemcenter-ticket-email
  -> gemcenter-ticket-mailer Lambda
  -> tạo QR PNG + Amazon SES
  -> DynamoDB (emailStatus = sent | failed)

Lỗi 3 lần -> gemcenter-ticket-email-dlq
```

## Resource được tạo ở local

`docker compose run --rm bootstrap` tạo:

- `gemcenter-ticket-email`: SQS queue, visibility timeout 60 giây.
- `gemcenter-ticket-email-dlq`: dead-letter queue.
- `gemcenter-register`: API Lambda, chỉ có DynamoDB và `sqs:SendMessage`.
- `gemcenter-ticket-mailer`: worker Lambda, có DynamoDB update và `ses:SendEmail`.
- Lambda event-source mapping với batch size bằng 1, để retry một ticket không làm gửi lại cả batch.

Kiểm tra local trên FLoCI Console:

1. Submit registration.
2. Mở **SQS** để xem queue trong lúc message chưa được xử lý.
3. Mở **SES Mailbox** để xem email QR được gửi.
4. Mở DynamoDB để xem `emailStatus` chuyển từ `pending`/`queued` sang `sent`.
5. Nếu cấu hình SES lỗi, message sẽ được retry tối đa ba lần rồi xuất hiện trong DLQ.

## Production AWS

Tạo các resource tương ứng trong cùng region:

1. SQS standard queue `gemcenter-ticket-email-dlq`.
2. SQS standard queue `gemcenter-ticket-email`, redrive policy tới DLQ, `maxReceiveCount = 3`, visibility timeout ít nhất 60 giây.
3. API Lambda role:
   - `dynamodb:PutItem`, `dynamodb:Query`, `dynamodb:UpdateItem` trên attendee table/indexes.
   - `sqs:SendMessage` chỉ trên ticket-email queue ARN.
4. Mailer Lambda role:
   - `dynamodb:UpdateItem` trên attendee table.
   - `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` chỉ trên ticket-email queue.
   - `ses:SendEmail`.
   - `AWSLambdaBasicExecutionRole` cho CloudWatch logs.
5. Tạo event source mapping: source là ticket-email queue, target là `gemcenter-ticket-mailer`, batch size `1`.
6. Verify SES domain, bật DKIM và request production access trước sự kiện.

`FROM_EMAIL` chỉ cấu hình trên **Mailer Lambda**. `TICKET_EMAIL_QUEUE_URL` chỉ cấu hình trên **API Lambda**.

## Lưu ý về retry

SQS + Lambda là at-least-once delivery. Worker cập nhật `emailStatus` để quan sát, nhưng về mặt lý thuyết vẫn có thể xảy ra email trùng trong lỗi hiếm xảy ra ngay sau khi SES nhận email nhưng trước khi Lambda kịp ghi trạng thái `sent`. Đây là đánh đổi bình thường của queue-based processing; check-in token vẫn không đổi và chỉ được check-in một lần.
