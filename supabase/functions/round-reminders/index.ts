// Drains the round_reminders queue and sends each one through Twilio.
//
// This is the half of the reminder feature that cannot live in the database,
// because it needs Twilio credentials — keeping it out here is what lets
// 0015_round_reminders.sql hold no secret at all. The database decides *who*
// is due (enqueue_due_round_reminders, on a plain SQL cron every minute);
// this decides *what the message says* and actually sends it.
//
// Invoke it every minute: Supabase Dashboard → Integrations → Cron → new job
// → invoke Supabase Edge Function → round-reminders. That path supplies the
// service-role Authorization header itself, so the key never has to be
// written into SQL either.
//
// Required secrets (Dashboard → Edge Functions → Secrets — set these
// yourself, they are never read or written by tooling):
//   TWILIO_ACCOUNT_SID
//   TWILIO_AUTH_TOKEN
//   TWILIO_SMS_FROM          e.g. +15005550006
//   TWILIO_WHATSAPP_FROM     e.g. +14155238886   (only if an event uses whatsapp)
//   CANCEL_URL_TEMPLATE      e.g. http://localhost:8765/#/c/{token}
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
//
// Trial-account note: a Twilio trial can only message numbers verified on
// that account, and prefixes every body with its own trial banner. Sends to
// anything else come back as a Twilio error, which lands in
// round_reminders.error rather than being lost.

interface DueReminder {
  reminder_id: string;
  to_phone: string;
  channel: "sms" | "whatsapp";
  guest_name: string | null;
  event_name: string;
  venue_name: string;
  round_number: number;
  scheduled_start_at: string;
  lead_minutes: number;
  party_size: number;
  cancel_token: string;
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Calls a security-definer RPC as service_role. */
async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${name} failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as T;
}

/**
 * "in about 4 minutes" rather than a clock time: the database stores UTC and
 * nothing in the schema says which timezone the hall is in, so an absolute
 * time would be a guess. A countdown is also simply the more useful thing to
 * read on a phone five minutes beforehand.
 */
function startsIn(scheduledStartAt: string, leadMinutes: number): string {
  const minutes = Math.round(
    (new Date(scheduledStartAt).getTime() - Date.now()) / 60_000,
  );
  if (minutes <= 0) return "very shortly";
  if (minutes === 1) return "in about a minute";
  // Falls back to the configured lead if the clock has drifted oddly.
  return `in about ${minutes > 60 ? leadMinutes : minutes} minutes`;
}

function composeBody(r: DueReminder, cancelUrl: string): string {
  const greeting = r.guest_name ? `Hi ${r.guest_name} — ` : "";
  const seats = r.party_size === 1 ? "your seat" : `your ${r.party_size} seats`;
  return (
    `${greeting}Round ${r.round_number} at ${r.event_name} (${r.venue_name}) starts ` +
    `${startsIn(r.scheduled_start_at, r.lead_minutes)}. Please be at ${seats}. ` +
    `Can't make it? Cancel here so someone else can take the seats: ${cancelUrl}`
  );
}

async function sendViaTwilio(r: DueReminder, body: string): Promise<string> {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
  if (!accountSid || !authToken) throw new Error("Twilio credentials are not configured");

  const fromRaw = r.channel === "whatsapp"
    ? Deno.env.get("TWILIO_WHATSAPP_FROM")
    : Deno.env.get("TWILIO_SMS_FROM");
  if (!fromRaw) throw new Error(`no sender configured for channel ${r.channel}`);

  // WhatsApp is the same Messages endpoint with a scheme on both addresses.
  const prefix = r.channel === "whatsapp" ? "whatsapp:" : "";

  const form = new URLSearchParams({
    To: `${prefix}${r.to_phone}`,
    From: `${prefix}${fromRaw}`,
    Body: body,
  });

  const res = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${accountSid}:${authToken}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form,
    },
  );

  const payload = await res.json();
  if (!res.ok) {
    throw new Error(payload?.message ?? `Twilio returned ${res.status}`);
  }
  return payload.sid as string;
}

Deno.serve(async (req) => {
  // This endpoint spends money and messages real people, so it is not enough
  // that the caller holds *a* valid project key — it has to be the service
  // role. Without this, anyone with the public anon key could drain the
  // queue on demand.
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${SERVICE_KEY}`) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  const template = Deno.env.get("CANCEL_URL_TEMPLATE");
  if (!template || !template.includes("{token}")) {
    return new Response(
      JSON.stringify({ error: "CANCEL_URL_TEMPLATE must be set and contain {token}" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  let due: DueReminder[];
  try {
    due = await rpc<DueReminder[]>("claim_due_round_reminders", { p_limit: 50 });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  let sent = 0;
  let failed = 0;

  // Sequential on purpose: a fan-out of parallel sends is the fastest way to
  // trip Twilio's per-second rate limit, and there is a whole minute before
  // the next run.
  for (const reminder of due) {
    const cancelUrl = template.replace("{token}", encodeURIComponent(reminder.cancel_token));
    const body = composeBody(reminder, cancelUrl);
    try {
      const sid = await sendViaTwilio(reminder, body);
      await rpc("mark_round_reminder_sent", {
        p_reminder_id: reminder.reminder_id,
        p_provider_sid: sid,
        p_body: body,
      });
      sent++;
    } catch (e) {
      // Back to 'pending' for another try, or 'failed' once it has had
      // three — mark_round_reminder_failed decides which.
      await rpc("mark_round_reminder_failed", {
        p_reminder_id: reminder.reminder_id,
        p_error: String(e).slice(0, 500),
      });
      failed++;
    }
  }

  return new Response(JSON.stringify({ claimed: due.length, sent, failed }), {
    headers: { "Content-Type": "application/json" },
  });
});
