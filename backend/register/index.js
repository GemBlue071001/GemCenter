const crypto = require("crypto");
const {
  DynamoDBClient,
  PutItemCommand,
  QueryCommand,
  UpdateItemCommand,
} = require("@aws-sdk/client-dynamodb");
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

const tableName = process.env.ATTENDEES_TABLE;
const eventId = process.env.EVENT_ID || "iti-2026";
const eventPk = `EVENT#${eventId}`;
const client = new DynamoDBClient({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: process.env.DYNAMODB_ENDPOINT,
});
const queueClient = new SQSClient({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: process.env.SQS_ENDPOINT,
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

function numberValue(value, fallback, maximum) {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? Math.min(parsed, maximum) : fallback;
}

function fromAttributeValue(attribute) {
  if (attribute.S !== undefined) return attribute.S;
  if (attribute.N !== undefined) return Number(attribute.N);
  if (attribute.BOOL !== undefined) return attribute.BOOL;
  if (attribute.NULL) return null;
  if (attribute.SS !== undefined) return attribute.SS;
  if (attribute.L !== undefined) return attribute.L.map(fromAttributeValue);
  if (attribute.M !== undefined) return fromItem(attribute.M);
  return undefined;
}

function fromItem(item) {
  return Object.fromEntries(
    Object.entries(item || {}).map(([key, value]) => [key, fromAttributeValue(value)]),
  );
}

function claimGroups(claims) {
  const rawGroups = claims?.["cognito:groups"];
  if (Array.isArray(rawGroups)) return rawGroups;
  if (typeof rawGroups !== "string") return [];
  return rawGroups.replace(/[\[\]"]/g, "").split(/[\s,]+/).filter(Boolean);
}

function requireCheckinStaff(event) {
  const claims = event?.requestContext?.authorizer?.jwt?.claims;
  if (!claims?.sub) {
    return { error: reply(401, { message: "Authentication is required." }) };
  }
  if (!claimGroups(claims).includes("checkin-staff")) {
    return { error: reply(403, { message: "You do not have check-in permission." }) };
  }
  return { staff: { id: claims.sub, email: claims.email || null } };
}

function attendeeResponse(item) {
  const attendee = fromItem(item);
  return {
    attendeeId: attendee.attendeeId,
    fullName: attendee.fullName,
    email: attendee.email,
    phone: attendee.phone,
    company: attendee.company,
    title: attendee.title,
    program: attendee.program,
    status: attendee.status,
    registeredAt: attendee.registeredAt,
    checkedInAt: attendee.checkedInAt || null,
    checkedInBy: attendee.checkedInBy || null,
  };
}

async function updateEmailStatus(attendeeId, status, extraAttributes = {}) {
  const expressionAttributeValues = {
    ":status": { S: status },
    ...extraAttributes,
  };
  const assignments = ["emailStatus = :status"];

  if (extraAttributes[":failedAt"]) assignments.push("emailFailedAt = :failedAt");

  await client.send(
    new UpdateItemCommand({
      TableName: tableName,
      Key: { PK: { S: eventPk }, SK: { S: `ATTENDEE#${attendeeId}` } },
      UpdateExpression: `SET ${assignments.join(", ")}`,
      ExpressionAttributeValues: expressionAttributeValues,
    }),
  );
}

async function register(payload) {
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
  const ticketTokenHash = crypto.createHash("sha256").update(ticketToken).digest("hex");
  const registeredAt = new Date().toISOString();

  await client.send(
    new PutItemCommand({
      TableName: tableName,
      ConditionExpression: "attribute_not_exists(PK) AND attribute_not_exists(SK)",
      Item: {
        PK: { S: eventPk },
        SK: { S: `ATTENDEE#${attendeeId}` },
        GSI1PK: { S: `EMAIL#${email}` },
        GSI1SK: { S: `EVENT#${eventId}#${registeredAt}` },
        GSI2PK: { S: `TICKET#${ticketTokenHash}` },
        GSI2SK: { S: `EVENT#${eventId}` },
        attendeeId: { S: attendeeId },
        fullName: { S: fullName },
        email: { S: email },
        phone: { S: phone },
        company: { S: company },
        title: { S: title },
        program: { S: program },
        status: { S: "registered" },
        emailStatus: { S: "pending" },
        ticketTokenHash: { S: ticketTokenHash },
        registeredAt: { S: registeredAt },
      },
    }),
  );

  let emailStatus = "queued";
  try {
    if (!process.env.TICKET_EMAIL_QUEUE_URL) {
      throw new Error("TICKET_EMAIL_QUEUE_URL is not configured.");
    }
    await queueClient.send(
      new SendMessageCommand({
        QueueUrl: process.env.TICKET_EMAIL_QUEUE_URL,
        MessageBody: JSON.stringify({ attendeeId, fullName, email, program, ticketToken }),
      }),
    );
    await updateEmailStatus(attendeeId, "queued");
  } catch (error) {
    // Registration is valid, but an operations retry is required if queuing fails.
    emailStatus = "queue_failed";
    await updateEmailStatus(attendeeId, "failed", { ":failedAt": { S: new Date().toISOString() } });
    console.error("Ticket email queueing failed", { attendeeId, error: error.message });
  }

  const response = { attendeeId, status: "registered", registeredAt, emailStatus };
  if (process.env.EXPOSE_TICKET_TOKEN === "true") response.ticketToken = ticketToken;
  return reply(201, response);
}

async function listAttendees(event) {
  const auth = requireCheckinStaff(event);
  if (auth.error) return auth.error;

  const limit = numberValue(event?.queryStringParameters?.limit, 50, 100);
  const response = await client.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "PK = :eventPk",
      ExpressionAttributeValues: { ":eventPk": { S: eventPk } },
      ProjectionExpression:
        "attendeeId, fullName, email, phone, company, title, program, #status, registeredAt, checkedInAt, checkedInBy",
      ExpressionAttributeNames: { "#status": "status" },
      Limit: limit,
    }),
  );

  return reply(200, {
    attendees: (response.Items || []).map(attendeeResponse),
    count: response.Count || 0,
  });
}

async function checkIn(event, payload) {
  const auth = requireCheckinStaff(event);
  if (auth.error) return auth.error;

  const ticketToken = stringValue(payload.ticketToken);
  if (!ticketToken) return reply(400, { message: "ticketToken is required." });

  const ticketTokenHash = crypto.createHash("sha256").update(ticketToken).digest("hex");
  const ticketLookup = await client.send(
    new QueryCommand({
      TableName: tableName,
      IndexName: "GSI2",
      KeyConditionExpression: "GSI2PK = :ticket AND GSI2SK = :event",
      ExpressionAttributeValues: {
        ":ticket": { S: `TICKET#${ticketTokenHash}` },
        ":event": { S: `EVENT#${eventId}` },
      },
      Limit: 1,
    }),
  );

  const attendee = ticketLookup.Items?.[0];
  if (!attendee) return reply(404, { message: "Ticket was not found." });

  try {
    const updated = await client.send(
      new UpdateItemCommand({
        TableName: tableName,
        Key: { PK: attendee.PK, SK: attendee.SK },
        ConditionExpression: "attribute_not_exists(checkedInAt)",
        UpdateExpression:
          "SET #status = :checkedIn, checkedInAt = :checkedInAt, checkedInBy = :checkedInBy",
        ExpressionAttributeNames: { "#status": "status" },
        ExpressionAttributeValues: {
          ":checkedIn": { S: "checked_in" },
          ":checkedInAt": { S: new Date().toISOString() },
          ":checkedInBy": { S: auth.staff.id },
        },
        ReturnValues: "ALL_NEW",
      }),
    );
    return reply(200, {
      message: "Check-in successful.",
      attendee: attendeeResponse(updated.Attributes),
    });
  } catch (error) {
    if (error.name === "ConditionalCheckFailedException") {
      return reply(409, { message: "This ticket has already checked in." });
    }
    throw error;
  }
}

exports.handler = async (event) => {
  if (event?.requestContext?.http?.method === "OPTIONS") {
    return { statusCode: 204, headers, body: "" };
  }

  if (event?.routeKey === "GET /attendees") return listAttendees(event);

  let payload;
  try {
    payload = JSON.parse(event?.body || "{}");
  } catch {
    return reply(400, { message: "Request body must be valid JSON." });
  }

  if (event?.routeKey === "POST /registrations") return register(payload);
  if (event?.routeKey === "POST /check-ins") return checkIn(event, payload);
  return reply(404, { message: "Route not found." });
};
