// Supabase Edge Function: scan-card
// Reads a business-card photo with Claude and returns the fields as JSON.
// The Anthropic key lives in Supabase Secrets (ANTHROPIC_API_KEY), never in the website.
// JWT verification stays ON, so only signed-in MyRoute Pro users can call it.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const PROMPT = `This image is a photo of a business card taken by a field sales rep. Read it and reply with only one JSON object with these keys:\n{"businessName": string, "contactName": string, "role": string, "phone": string, "email": string, "address": string, "note": string, "check": string[], "cardBox": {"x": number, "y": number, "w": number, "h": number}, "rotate": number}\nRules:\n- businessName: the company or property name on the card, including the location or branch when shown (for example \"PuroClean of West Houston\", usually printed near the address and phone). Never use a slogan or tagline (for example \"The Paramedics of Property Damage\") and never use a service list or the person's title. If the logo shows only the brand, use the full company name from the contact block. contactName: the card holder, written as First Last (drop credentials such as CAM). role: their job title.\n- phone: the best direct number for the person (mobile or direct before an office line), formatted (281) 555-1234. email: lower-case unless the card shows otherwise.\n- address: one line, "street, City, TX ZIP", including any suite number. Use "" for anything that is not on the card. Never guess.\n- note: two or three plain, friendly sentences in the first person, written from only what the card shows: who gave the card, their role, what the business is, why they matter to a restoration company (property managers are often the first call after a flood or fire; insurance agents refer claims), and that you will follow up. Do not claim anything was said in a conversation and do not invent details.\n- check: a short list (usually empty) naming anything hard to read, handwritten, or missing, for example "email is handwritten" or "no contact name on the card".\n- cardBox: the tight rectangle around the business card itself (its edges, not the table, hand or background), as fractions of the whole photo from 0 to 1: x and y are the top-left corner, w and h are the width and height. If you cannot find the card edges, use {"x":0,"y":0,"w":1,"h":1}.\n- rotate: how many degrees clockwise (0, 90, 180 or 270) the photo must be turned so the card text reads upright.\nReply with only the JSON.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { image, mediaType } = await req.json();
    if (!image || typeof image !== "string" || image.length > 7_000_000) {
      return new Response(JSON.stringify({ error: "bad_image" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
    }
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "", "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-5-5",
        max_tokens: 1200,
        messages: [{ role: "user", content: [
          { type: "image", source: { type: "base64", media_type: mediaType || "image/jpeg", data: image } },
          { type: "text", text: PROMPT },
        ] }],
      }),
    });
    const body = await r.json();
    if (!r.ok) return new Response(JSON.stringify({ error: "claude_error", detail: body?.error?.message ?? "" }), { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
    const text = (body.content ?? []).map((c: { text?: string }) => c.text ?? "").join("");
    const a = text.indexOf("{"), b = text.lastIndexOf("}");
    if (a < 0 || b < a) return new Response(JSON.stringify({ error: "invalid_json" }), { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
    return new Response(JSON.stringify(JSON.parse(text.slice(a, b + 1))), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: "server_error", detail: String(e) }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
