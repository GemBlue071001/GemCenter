# Backend issue report

Ngày rà soát: 2026-10-08  
Phạm vi: `backend/register`, `backend/mailer`, `infra/bootstrap` và tài liệu deploy hiện có.  
Trạng thái kiểm chứng: rà soát source; chưa chạy test trên AWS thật. Luồng cơ bản đã được kiểm tra cục bộ bằng FLoCI theo README.

## Bảng theo dõi

| ID | Ưu tiên | Trạng thái | Vấn đề | Vị trí chính |
| --- | --- | --- | --- | --- |
| GC-01 | P1 | [ ] Chưa xử lý | Trạng thái email có thể bị ghi ngược | `backend/register/index.js:164-170` |
| GC-02 | P1 | [ ] Chưa xử lý | Mất khả năng gửi lại vé khi enqueue thất bại | `backend/register/index.js:128-180` |
| GC-03 | P1 | [ ] Chưa xử lý | Request lặp có thể tạo nhiều đăng ký và email | `backend/register/index.js:128-157` |
| GC-04 | P2 | [ ] Chưa xử lý | JSON `null` gây lỗi server; input chưa giới hạn độ dài | `backend/register/index.js:111-125, 206-211, 266-274` |
| GC-05 | P2 | [ ] Chưa xử lý | API danh sách attendee chỉ trả trang đầu | `backend/register/index.js:183-204` |
| GC-06 | P2 | [ ] Chưa xử lý | Quét QR ngay sau đăng ký có thể tạm trả 404 | `backend/register/index.js:214-228` |
| GC-07 | P1 | [ ] Chưa xử lý | Chưa có cấu hình deploy production đầy đủ | `infra/bootstrap/bootstrap.sh`, `docs/aws-*.md` |

`P1`: nên xử lý trước khi mở đăng ký trên AWS thật. `P2`: cần xử lý trước khi vận hành với lượng khách thực tế. Đánh dấu `[x]` và thêm link commit/PR ở từng mục khi hoàn thành.

## GC-01 — Trạng thái email có thể bị ghi ngược

**Hiện trạng:** API gửi message vào SQS rồi mới cập nhật `emailStatus = queued` ([register/index.js](../backend/register/index.js#L164-L170)). Mailer có thể nhận message, gửi mail và ghi `sent` ([mailer/index.js](../backend/mailer/index.js#L93-L100)) trước khi API ghi `queued`. Kết quả là mail đã gửi nhưng record cuối cùng vẫn báo `queued`. Tương tự, trạng thái `failed` từ mailer có thể bị ghi đè.

**Hướng xử lý:** Thiết kế chuyển trạng thái có điều kiện; API không được ghi đè trạng thái cuối (`sent`/`failed`). Xem lại thứ tự ghi DB và gửi SQS để tránh race.

**Tiêu chí hoàn thành:** Dù mailer xử lý trước hay sau khi API trả response, trạng thái cuối trong DynamoDB phản ánh đúng kết quả gửi mail. Có test điều khiển được thứ tự hai Lambda.

## GC-02 — Mất khả năng gửi lại vé khi enqueue thất bại

**Hiện trạng:** Attendee được lưu trước khi gửi message ([register/index.js](../backend/register/index.js#L128-L157)). Khi `SendMessage` lỗi, API đánh dấu `failed` nhưng vẫn trả HTTP 201 ([register/index.js](../backend/register/index.js#L159-L180)). Production không trả `ticketToken`; DynamoDB chỉ giữ hash của token, nên không thể tái tạo đúng QR để gửi lại.

**Hướng xử lý:** Bổ sung cơ chế phát vé bền vững, chẳng hạn outbox hoặc lưu token theo cách được bảo vệ để worker có thể retry. Quy định rõ response và quy trình khôi phục khi queue tạm lỗi.

**Tiêu chí hoàn thành:** Giả lập SQS thất bại sau khi ghi attendee; hệ thống vẫn có cách tự động hoặc vận hành được để gửi đúng vé, không yêu cầu khách đăng ký lại.

## GC-03 — Request lặp tạo nhiều đăng ký

**Hiện trạng:** Mỗi request tạo `attendeeId` và `ticketToken` mới. `ConditionExpression` chỉ ngăn trùng khóa chính ngẫu nhiên, không ngăn cùng request được xử lý hai lần ([register/index.js](../backend/register/index.js#L128-L157)). Double click, retry của frontend hoặc mạng chập chờn có thể tạo nhiều attendee và nhiều email.

**Hướng xử lý:** Chọn quy tắc nghiệp vụ cho đăng ký trùng và hỗ trợ idempotency key hoặc khóa duy nhất theo event + email nếu chỉ cho phép một vé mỗi email. Không dùng riêng GSI1 để bảo đảm tính duy nhất vì query rồi ghi không phải thao tác nguyên tử.

**Tiêu chí hoàn thành:** Gửi lại cùng request/idempotency key không tạo thêm attendee hoặc vé; test hai request đồng thời.

## GC-04 — Input lỗi có thể thành HTTP 5xx

**Hiện trạng:** `JSON.parse("null")` thành công, sau đó code đọc `payload.fullName` hoặc `payload.ticketToken` và ném `TypeError` ([register/index.js](../backend/register/index.js#L111-L117), [register/index.js](../backend/register/index.js#L206-L211), [register/index.js](../backend/register/index.js#L266-L274)). Các trường chuỗi chưa có giới hạn độ dài; payload quá lớn có thể vượt giới hạn DynamoDB/SQS.

**Hướng xử lý:** Chỉ chấp nhận JSON object không phải `null`/array; kiểm tra kiểu, độ dài và định dạng từng trường trước khi gọi AWS SDK.

**Tiêu chí hoàn thành:** `null`, array, trường sai kiểu và chuỗi quá dài đều trả lỗi 4xx có thông báo rõ; Lambda không phát sinh lỗi ngoài dự kiến.

## GC-05 — Không phân trang danh sách attendee

**Hiện trạng:** `GET /attendees` query với `Limit` tối đa 100, nhưng bỏ qua `LastEvaluatedKey` ([register/index.js](../backend/register/index.js#L183-L204)). Client không có cursor để lấy các trang tiếp theo. DynamoDB cũng có giới hạn 1 MB cho mỗi trang query. [AWS: Query pagination](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html)

**Hướng xử lý:** Nhận cursor từ request, truyền thành `ExclusiveStartKey` và trả cursor kế tiếp lấy từ `LastEvaluatedKey`. Mã hóa cursor trước khi đưa cho client nếu cần.

**Tiêu chí hoàn thành:** Với hơn 100 attendee, client duyệt được toàn bộ danh sách không thiếu hoặc lặp record.

## GC-06 — GSI2 có thể chưa cập nhật khi quét ngay

**Hiện trạng:** Check-in tra token qua GSI2 ([register/index.js](../backend/register/index.js#L214-L228)). Global secondary index cập nhật bất đồng bộ; ngay sau khi `PutItem` thành công, query index có thể chưa thấy vé và trả 404 tạm thời. [AWS: GSI synchronization](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html)

**Hướng xử lý:** Cân nhắc retry ngắn cho trường hợp vé vừa tạo, hoặc thiết kế lookup không phụ thuộc vào GSI vừa cập nhật. Phân biệt vé không tồn tại và dữ liệu đang đồng bộ trong trải nghiệm check-in.

**Tiêu chí hoàn thành:** Test đăng ký rồi quét ngay, bao gồm tình huống GSI trả rỗng ở lần đọc đầu; nhân viên không bị báo sai rằng vé vô hiệu.

## GC-07 — Thiếu cấu hình deploy production theo kiến trúc hiện tại

**Cập nhật 2026-10-08:** Đã thêm [`template.yaml`](../template.yaml) và [hướng dẫn SAM](sam-deploy.md). Issue vẫn mở cho đến khi template được validate bằng SAM CLI, deploy staging và kiểm tra đầy đủ luồng trên AWS.

**Hiện trạng:** [bootstrap.sh](../infra/bootstrap/bootstrap.sh) dành cho FLoCI: dùng endpoint giả lập, account `000000000000`, token được trả để test, CORS `*` và không tạo JWT authorizer cho route nhân viên. Hai tài liệu [AWS production setup](aws-production-setup.md) và [AWS Console setup](aws-console-setup.md) mô tả một phần kiến trúc cũ, chưa dựng đầy đủ SQS + mailer và có lệnh đóng gói dependency không khớp `package.json` hiện tại. Vì vậy không thể dùng nguyên bootstrap hoặc tài liệu này để deploy an toàn lên AWS thật.

**Hướng xử lý:** Tạo template hạ tầng production (ưu tiên AWS SAM) gồm DynamoDB, SQS/DLQ, hai Lambda, IAM tối thiểu, HTTP API, Cognito JWT authorizer, CORS theo domain thật, log retention và alarm. Cấu hình `EVENT_ID`, `FROM_EMAIL`, queue URL; không mang các endpoint FLoCI hoặc `EXPOSE_TICKET_TOKEN=true` lên production. Cập nhật tài liệu deploy theo template.

**Tiêu chí hoàn thành:** Deploy được vào môi trường AWS thử nghiệm, kiểm tra đăng ký → email → check-in, xác nhận route nhân viên bị chặn khi thiếu JWT, và chạy lại deploy không tạo resource trùng.

## Thứ tự đề xuất

1. Sửa GC-01, GC-02, GC-03 và GC-04; thêm test cho các trường hợp lỗi và xử lý đồng thời.
2. Hoàn thiện GC-07 để có môi trường AWS thử nghiệm nhất quán.
3. Kiểm tra GC-05, GC-06 với dữ liệu và độ trễ gần thực tế trước khi mở sự kiện.

**Lưu ý vận hành:** SQS/Lambda có thể xử lý lại một message. Nếu SES đã nhận mail nhưng bước ghi `emailStatus = sent` thất bại, mailer có thể gửi trùng ở lần retry ([mailer/index.js](../backend/mailer/index.js#L97-L110)). Cần theo dõi riêng nếu yêu cầu tuyệt đối không gửi vé trùng.
