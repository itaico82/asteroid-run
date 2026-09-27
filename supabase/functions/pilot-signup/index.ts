// pilot-signup: creates a pilot from a username + 4-digit PIN (no email).
// The service-role key never leaves this function; the browser only ever holds the public key.
import { createClient } from "npm:@supabase/supabase-js@2";

const ADJ = ["Swift","Brave","Cosmic","Lucky","Silver","Golden","Turbo","Mighty","Clever","Bright","Speedy","Fearless","Jolly","Zippy","Super","Happy","Sonic","Stellar","Blazing","Daring","Radiant","Rapid","Galactic","Noble"];
const NOUN = ["Comet","Falcon","Nebula","Rocket","Meteor","Panda","Tiger","Dolphin","Phoenix","Star","Moon","Otter","Fox","Owl","Dragon","Pulsar","Orbit","Voyager","Explorer","Eagle","Lynx","Penguin","Koala","Shark"];
const EMBLEMS = ["#3ee6ff","#b26bff","#ffb347","#4ff0a8","#ff6bd6","#ff8a4c","#5c8dff","#ff5c6c"];
const EMAIL_DOMAIN = "pilots.asteroid-run.example";
const MAX_SIGNUPS_PER_IP_PER_HOUR = 40;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const validCallsign = (c: unknown) => {
  if (typeof c !== "string") return false;
  const [a, n, num, ...rest] = c.split(" ");
  return rest.length === 0 && ADJ.includes(a) && NOUN.includes(n) && /^[1-9][0-9]?$/.test(num ?? "");
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "bad_json" }); }

  const username = String(body.username ?? "").trim().toLowerCase();
  const pin = String(body.pin ?? "");
  const callsign = body.callsign;
  const emblem = EMBLEMS.includes(String(body.emblem)) ? String(body.emblem) : EMBLEMS[0];

  if (!/^[a-z0-9_]{3,16}$/.test(username)) return reply(400, { error: "bad_username", message: "Usernames are 3 to 16 letters, numbers or underscores." });
  if (!/^[0-9]{4}$/.test(pin)) return reply(400, { error: "bad_pin", message: "The PIN must be exactly 4 digits." });
  if (!validCallsign(callsign)) return reply(400, { error: "bad_callsign", message: "Pick a callsign from the lists." });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Throttle account creation per network address.
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const since = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await admin.from("signup_log").select("id", { count: "exact", head: true }).eq("ip", ip).gte("created_at", since);
  if ((count ?? 0) >= MAX_SIGNUPS_PER_IP_PER_HOUR) return reply(429, { error: "too_many", message: "Lots of new pilots from here today. Try again in an hour." });

  const { data: taken } = await admin.from("pilots").select("id").eq("username", username).maybeSingle();
  if (taken) return reply(409, { error: "username_taken", message: "That username is taken. Try adding a number." });

  // The PIN is stretched into a password the same way the game does it at sign-in.
  const password = `AR-${pin}-${username}`;
  const { data: created, error } = await admin.auth.admin.createUser({
    email: `${username}@${EMAIL_DOMAIN}`,
    password,
    email_confirm: true,
    user_metadata: { username },
  });
  if (error || !created?.user) {
    const msg = (error?.message ?? "").toLowerCase();
    if (msg.includes("already")) return reply(409, { error: "username_taken", message: "That username is taken. Try adding a number." });
    return reply(500, { error: "create_failed", message: "Couldn't create the pilot. Please try again." });
  }

  const { error: pErr } = await admin.from("pilots").insert({ id: created.user.id, username, callsign, emblem });
  if (pErr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return reply(500, { error: "profile_failed", message: "Couldn't create the pilot. Please try again." });
  }
  await admin.from("signup_log").insert({ ip });
  return reply(200, { ok: true, username });
});
