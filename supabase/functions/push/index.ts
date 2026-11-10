// Supabase Edge Function: push
// Sends the "Today's route" phone notification at 9:00 AM Central.
// Deploy with "Verify JWT" OFF. The function checks the user itself for subscribe/test, and a private key for the schedule.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron",
};
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function cfg(k: string) { const { data } = await sb.from("push_config").select("value").eq("key", k).maybeSingle(); return data?.value as string | undefined; }
async function setCfg(k: string, v: string) { await sb.from("push_config").upsert({ key: k, value: v }); }
async function vapid() {
  let pub = await cfg("vapid_pub"), priv = await cfg("vapid_priv");
  if (!pub || !priv) { const k = webpush.generateVAPIDKeys(); pub = k.publicKey; priv = k.privateKey; await setCfg("vapid_pub", pub); await setCfg("vapid_priv", priv); }
  webpush.setVapidDetails("mailto:myrouteprotx@gmail.com", pub, priv);
  return { pub, priv };
}
function chicagoNow() {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date()).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour), minute: Number(p.minute) };
}
async function summaryFor(owner: string, date: string) {
  const { data } = await sb.from("docs").select("data").eq("owner", owner).eq("path", "meta/routeToday").maybeSingle();
  let d = data?.data; if (typeof d === "string") { try { d = JSON.parse(d); } catch { d = null; } }
  if (!d || d.date !== date || !(Number(d.count) > 0)) return null;
  return { title: "Today's route", body: `${d.count} stop${Number(d.count) === 1 ? "" : "s"} planned. First: ${d.first || "see the app"}` };
}
async function sendTo(owner: string, payload: { title: string; body: string }) {
  const { data: subs } = await sb.from("push_subs").select("endpoint, sub").eq("owner", owner);
  let sent = 0;
  for (const s of subs ?? []) {
    try { await webpush.sendNotification(s.sub, JSON.stringify(payload)); sent++; }
    catch (e) { const code = (e as { statusCode?: number }).statusCode; if (code === 404 || code === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint); }
  }
  return sent;
}
async function userFrom(req: Request) {
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer /i, "");
  const { data } = await sb.auth.getUser(jwt);
  return data?.user ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    if (body.action === "key") { const v = await vapid(); return json({ key: v.pub }); }
    if (body.action === "subscribe") {
      const u = await userFrom(req); if (!u) return json({ error: "not_signed_in" }, 401);
      if (!body.sub?.endpoint) return json({ error: "bad_subscription" }, 400);
      await sb.from("push_subs").upsert({ owner: u.id, endpoint: body.sub.endpoint, sub: body.sub });
      return json({ ok: true });
    }
    if (body.action === "test") {
      const u = await userFrom(req); if (!u) return json({ error: "not_signed_in" }, 401);
      await vapid();
      const n = chicagoNow();
      const sum = await summaryFor(u.id, n.date);
      const sent = await sendTo(u.id, sum ?? { title: "Today's route", body: "Test notification. No stops are planned for today yet." });
      return json({ ok: true, sent });
    }
    if (body.action === "run") {
      if (req.headers.get("x-cron") !== (await cfg("cron"))) return json({ error: "forbidden" }, 403);
      await vapid();
      const n = chicagoNow();
      if (!(n.hour === 9 && n.minute < 15)) return json({ ok: true, skipped: "not the time" });
      if ((await cfg("last_sent")) === n.date) return json({ ok: true, skipped: "already sent" });
      await setCfg("last_sent", n.date);
      const { data: owners } = await sb.from("push_subs").select("owner");
      let sent = 0;
      for (const o of [...new Set((owners ?? []).map((r) => r.owner as string))]) {
        const sum = await summaryFor(o, n.date);
        if (sum) sent += await sendTo(o, sum);
      }
      return json({ ok: true, sent });
    }
    return json({ error: "unknown_action" }, 400);
  } catch (e) { return json({ error: "server_error", detail: String(e) }, 500); }
});
