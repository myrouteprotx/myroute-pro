// Supabase Edge Function: places
// Looks up a business on Google Places (New) so an address can be checked before it goes on a route.
// Needs the secret GOOGLE_PLACES_KEY. Deploy with "Verify JWT" OFF (the function checks the signed-in user itself).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const BAD = ["police", "post_office", "local_government_office", "city_hall", "courthouse", "fire_station", "embassy"];

type Comp = { longText?: string; shortText?: string; types?: string[] };
function part(c: Comp[], t: string, short = false) { const x = (c || []).find((k) => (k.types || []).includes(t)); return x ? (short ? x.shortText : x.longText) || "" : ""; }

async function searchPlaces(key: string, q: string, body: any) {
    const payload: Record<string, unknown> = { textQuery: q, maxResultCount: 5, languageCode: "en", regionCode: "US" };
    const lat = Number(body.lat), lng = Number(body.lng);
    if (isFinite(lat) && isFinite(lng) && body.lat != null) payload.locationBias = { circle: { center: { latitude: lat, longitude: lng }, radius: 50000 } };
    const r = await fetch("https://places.googleapis.com/v1/places:searchText", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": "places.id,places.displayName,places.formattedAddress,places.addressComponents,places.location,places.types,places.primaryType,places.businessStatus,places.nationalPhoneNumber,places.websiteUri,places.userRatingCount,places.pureServiceAreaBusiness,places.regularOpeningHours",
      },
      body: JSON.stringify(payload),
    });
    const d = await r.json();
    if (!r.ok) return { err: { status: r.status, detail: d?.error?.message || "" } };
    const places = (d.places || []).map((p: any) => {
      const c = p.addressComponents || [];
      const types: string[] = p.types || [];
      const street = [part(c, "street_number"), part(c, "route")].filter(Boolean).join(" ");
      return {
        id: p.id,
        name: p.displayName?.text || "",
        address: p.formattedAddress || "",
        street,
        suite: part(c, "subpremise"),
        city: part(c, "locality") || part(c, "postal_town") || part(c, "sublocality"),
        state: part(c, "administrative_area_level_1", true),
        zip: part(c, "postal_code"),
        lat: p.location?.latitude ?? null,
        lng: p.location?.longitude ?? null,
        type: p.primaryType || "",
        plumber: types.includes("plumber"),
        bad: types.find((t) => BAD.includes(t)) || "",
        status: p.businessStatus || "",
        phone: p.nationalPhoneNumber || "",
        website: p.websiteUri || "",
        ratings: p.userRatingCount ?? 0,
        serviceArea: !!p.pureServiceAreaBusiness,   // Google says it has no storefront customers can visit
        hours: !!(p.regularOpeningHours && (p.regularOpeningHours.periods || []).length),
      };
    });
    return { places };
}

// Google Address Validation API. If it is not enabled on the key, the caller falls back to Places.
async function validateAddress(key: string, address: string) {
  const r = await fetch("https://addressvalidation.googleapis.com/v1:validateAddress?key=" + encodeURIComponent(key), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: { regionCode: "US", addressLines: [address] }, enableUspsCass: true }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = String(d?.error?.message || "");
    const blocked = r.status === 403 || /not been used|disabled|blocked|API_KEY_SERVICE_BLOCKED|not enabled|PERMISSION_DENIED/i.test(msg + JSON.stringify(d?.error?.details || ""));
    return { blocked, status: r.status, detail: msg };
  }
  const res = d.result || {};
  const v = res.verdict || {};
  const a = res.address || {};
  const pa = a.postalAddress || {};
  const usps = res.uspsData || {};
  const comps: any[] = a.addressComponents || [];
  const unconfirmed = !!v.hasUnconfirmedComponents || comps.some((c) => c.confirmationLevel === "UNCONFIRMED_AND_SUSPICIOUS");
  const missing: string[] = a.missingComponentTypes || [];
  const lines: string[] = pa.addressLines || [];
  const formatted = a.formattedAddress || "";
  return {
    ok: true,
    mode: "validation",
    complete: !!v.addressComplete,
    unconfirmed,
    granularity: v.validationGranularity || "",
    dpv: usps.dpvConfirmation || "",
    cmra: usps.dpvCmra === "Y",
    vacant: usps.dpvVacant === "Y",
    residential: res.metadata?.residential === true,
    poBox: res.metadata?.poBox === true,
    missing,
    formatted,
    street: lines.join(", "),
    city: pa.locality || "",
    state: pa.administrativeArea || "",
    zip: pa.postalCode || "",
    lat: res.geocode?.location?.latitude ?? null,
    lng: res.geocode?.location?.longitude ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer /i, "");
    const { data: u } = await sb.auth.getUser(jwt);
    if (!u?.user) return json({ error: "not_signed_in" }, 401);
    // Only the owner, administrators and managers may run checks (they are billed to the owner's Google account)
    const { data: mem } = await sb.from("members").select("role").eq("member", u.user.id).maybeSingle();
    if (mem && !["admin", "manager"].includes(mem.role as string)) return json({ error: "not_allowed" }, 403);
    const key = Deno.env.get("GOOGLE_PLACES_KEY");
    if (!key) return json({ error: "no_key" }, 500);
    const body = await req.json().catch(() => ({}));
    if (body.action === "validate") {
      const addr = String(body.address || "").trim().slice(0, 250);
      if (!addr) return json({ error: "empty_query" }, 400);
      const v: any = await validateAddress(key, addr);
      if (v.ok) return json(v);
      // Address Validation is not turned on for this key (or failed): check through Places instead and say so
      const s2: any = await searchPlaces(key, addr, body);
      if (s2.err) return json({ error: "google_error", status: s2.err.status, detail: s2.err.detail }, 502);
      return json({ ok: true, mode: "fallback", reason: v.blocked ? "address_validation_not_enabled" : "address_validation_failed", reason_detail: v.detail || "", places: s2.places });
    }
    const q = String(body.query || "").trim().slice(0, 200);
    if (!q) return json({ error: "empty_query" }, 400);
    const s1: any = await searchPlaces(key, q, body);
    if (s1.err) return json({ error: "google_error", status: s1.err.status, detail: s1.err.detail }, 502);
    return json({ ok: true, places: s1.places });
  } catch (e) { return json({ error: "server_error", detail: String(e) }, 500); }
});
