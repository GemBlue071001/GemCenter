const crypto = require("crypto");
const { DynamoDBClient, PutItemCommand } = require("@aws-sdk/client-dynamodb");

const tableName = process.env.ATTENDEES_TABLE;
const client = new DynamoDBClient({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: process.env.DYNAMODB_ENDPOINT,
});

const headers = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
};

function reply(statusCode, body) {
  return { statusCode, headers, body: JSON.stringify(body) };
}

function stringValue(value) {
  return typeof value === "string" ? value.trim() : "";
}

exports.handler = async (event) => {
  let payload;

  try {
    payload = JSON.parse(event.body || "{}");
  } catch {
    return reply(400, { message: "Request body must be valid JSON." });
  }

  const fullName = stringValue(payload.fullName);
  const email = stringValue(payload.email).toLowerCase();
  const phone = stringValue(payload.phone);
  const company = stringValue(payload.company);
  const title = stringValue(payload.title);
  const program = stringValue(payload.program);

  if (!fullName || !email || !phone || !company || !program) {
    return reply(400, {
      message: "fullName, email, phone, company and program are required.",
    });
  }

  if (!/^\S+@\S+\.\S+$/.test(email)) {
    return reply(400, { message: "email is not valid." });
  }

  const attendeeId = crypto.randomUUID();
  const ticketToken = crypto.randomBytes(32).toString("base64url");
  const ticketTokenHash = crypto
    .createHash("sha256")
    .update(ticketToken)
    .digest("hex");
  const registeredAt = new Date().toISOString();

  await client.send(
    new PutItemCommand({
      TableName: tableName,
      ConditionExpression: "attribute_not_exists(PK)",
      Item: {
        PK: { S: `EVENT#iti-2026` },
        SK: { S: `ATTENDEE#${attendeeId}` },
        GSI1PK: { S: `EMAIL#${email}` },
        GSI1SK: { S: `EVENT#iti-2026#${registeredAt}` },
        attendeeId: { S: attendeeId },
        fullName: { S: fullName },
        email: { S: email },
        phone: { S: phone },
        company: { S: company },
        title: { S: title },
        program: { S: program },
        status: { S: "registered" },
        ticketTokenHash: { S: ticketTokenHash },
        registeredAt: { S: registeredAt },
      },
    }),
  );

  // In the next phase this token will be used to render and email a QR code.
  // The QR carries the opaque token only, never name, email, or phone number.
  return reply(201, {
    attendeeId,
    ticketToken,
    status: "registered",
    registeredAt,
  });
};
