const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { SESv2Client, SendEmailCommand } = require("@aws-sdk/client-sesv2");
const QRCode = require("qrcode");

const tableName = process.env.ATTENDEES_TABLE;
const eventId = process.env.EVENT_ID || "iti-2026";
const eventPk = `EVENT#${eventId}`;
const db = new DynamoDBClient({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: process.env.DYNAMODB_ENDPOINT,
});
const ses = new SESv2Client({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: process.env.SES_ENDPOINT,
});

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[character]);
}

async function updateEmailStatus(attendeeId, status, timestampAttribute) {
  await db.send(
    new UpdateItemCommand({
      TableName: tableName,
      Key: { PK: { S: eventPk }, SK: { S: `ATTENDEE#${attendeeId}` } },
      UpdateExpression: "SET emailStatus = :status, #timestamp = :timestamp",
      ExpressionAttributeNames: { "#timestamp": timestampAttribute },
      ExpressionAttributeValues: {
        ":status": { S: status },
        ":timestamp": { S: new Date().toISOString() },
      },
    }),
  );
}

async function sendTicketEmail({ attendeeId, fullName, email, program, ticketToken }) {
  const fromEmail = process.env.FROM_EMAIL?.trim();
  if (!fromEmail) throw new Error("FROM_EMAIL is not configured.");

  const qrImage = await QRCode.toBuffer(ticketToken, {
    type: "png",
    width: 480,
    errorCorrectionLevel: "M",
    margin: 2,
  });
  // FLoCI's captured-email preview does not resolve CID attachments. This is
  // enabled only locally so the QR is visible while testing; AWS keeps CID.
  const previewQrSource = process.env.EMAIL_PREVIEW_DATA_URI === "true"
    ? `data:image/png;base64,${qrImage.toString("base64")}`
    : "cid:gemcenter-ticket-qr";
  const safeName = escapeHtml(fullName);
  const safeProgram = escapeHtml(program);

  await ses.send(
    new SendEmailCommand({
      FromEmailAddress: fromEmail,
      Destination: { ToAddresses: [email] },
      Content: {
        Simple: {
          Subject: { Data: "Ve tham du su kien GemCenter", Charset: "UTF-8" },
          Body: {
            Text: {
              Data: `Chao ${fullName},\n\nBan da dang ky thanh cong cho ${program}. Vui long dua ma QR dinh kem khi check-in.\nMa ve: ${attendeeId}`,
              Charset: "UTF-8",
            },
            Html: {
              Data: `<main style="font-family:Arial,sans-serif;max-width:560px;margin:auto"><h1>Dang ky thanh cong</h1><p>Chao <strong>${safeName}</strong>,</p><p>Cam on ban da dang ky <strong>${safeProgram}</strong>.</p><p>Vui long dua ma QR ben duoi tai quay check-in:</p><p><img src="${previewQrSource}" alt="Ma QR check-in" width="240" height="240" /></p><p>Ma ve: <strong>${attendeeId}</strong></p></main>`,
              Charset: "UTF-8",
            },
          },
          Attachments: [
            {
              RawContent: qrImage,
              FileName: "gemcenter-checkin-qr.png",
              ContentType: "image/png",
              ContentDisposition: "INLINE",
              ContentId: "gemcenter-ticket-qr",
              ContentTransferEncoding: "BASE64",
            },
          ],
        },
      },
    }),
  );
}

exports.handler = async (event) => {
  // The event source mapping uses batch size 1. Throwing makes SQS retry this ticket.
  for (const record of event.Records || []) {
    let ticket;
    try {
      ticket = JSON.parse(record.body);
      await sendTicketEmail(ticket);
      await updateEmailStatus(ticket.attendeeId, "sent", "emailSentAt");
    } catch (error) {
      if (ticket?.attendeeId) {
        await updateEmailStatus(ticket.attendeeId, "failed", "emailFailedAt");
      }
      console.error("Ticket email failed", {
        messageId: record.messageId,
        attendeeId: ticket?.attendeeId,
        error: error.message,
      });
      throw error;
    }
  }
};
