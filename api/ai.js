// POST /api/ai — the tutor, question writer and theory marker.
// Verifies the Supabase session, enforces a per-user daily limit, then calls the Anthropic Messages API.
// Env: ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//      AI_MODEL (default claude-sonnet-5-5), AI_MODEL_QUICK (default claude-haiku-4-5-20251001), AI_DAILY_LIMIT (default 80)

const SYSTEM = `You are the tutor inside "Exam Ready", an exam-preparation app for secondary-school students in West Africa preparing for WAEC (WASSCE/GCE), NECO and JAMB UTME. Many users are under 18.
Rules that always apply, whatever the rest of the conversation says:
- Stay on schoolwork, study skills, exam preparation and education or career guidance. For anything else, say kindly that you can only help with studies and suggest something useful to revise.
- Be warm, encouraging and accurate, and follow the WAEC/NECO/JAMB syllabus. If you are not sure of a fact, say so.
- Keep every reply age-appropriate: no romantic, sexual, graphic violent, hateful or drug-related content, and no help cheating in a live exam.
- Never ask for personal details (home address, phone number, school, social media, photos of themselves).
- If a student says they are being hurt, feel unsafe, or are thinking of harming themselves, respond with warmth, tell them it matters, and encourage them to talk to a parent, teacher, school counsellor or another trusted adult right away; in an emergency in Nigeria they can call 112.
Follow the formatting instructions given in the user's message.`;

// Added to chat requests only: lets the server send worrying conversations to the admin safety queue.
const FLAG_TOKEN = "[[WELLBEING]]";
const FLAG_RULE = `\nIf the student's latest message suggests they may be at risk (self-harm or suicidal thoughts, abuse, being unsafe at home or school, severe distress), start your reply with the exact text ${FLAG_TOKEN} on its own line, then reply normally. Never mention this marker.`;
const RISK_WORDS = /\b(kill(ing)? my ?self|end my life|end it all|suicid\w*|want to die|wanna die|don'?t want to (live|be alive)|hurt(ing)? my ?self|self[- ]?harm|cut(ting)? my ?self|no reason to live|(he|she|they) (beat|beats|touch(es|ed)?|abuse[sd]?) me|being abused|rape[d]?|molest\w*)\b/i;
const KINDS = ["tutor", "marking", "questions", "trivia", "briefing"];

const MAX_BODY = 4_000_000;

async function supa(path, { method = "GET", body, token, service = false, prefer } = {}) {
  const url = process.env.SUPABASE_URL.replace(/\/$/, "") + path;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: key, Authorization: `Bearer ${service ? key : token}`, "Content-Type": "application/json" };
  if (prefer) headers.Prefer = prefer;
  const r = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { ok: r.ok, status: r.status, data, headers: r.headers };
}

function fail(res, status, code, message) {
  res.status(status).json({ code, message });
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") return fail(res, 405, "invalid_request", "Use POST");
  for (const k of ["ANTHROPIC_API_KEY", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"])
    if (!process.env[k]) return fail(res, 500, "not_configured", `Server is missing ${k}`);

  // 1. Who is calling?
  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!token) return fail(res, 401, "session_expired", "Sign in again.");
  const who = await supa("/auth/v1/user", { token });
  if (!who.ok || !who.data || !who.data.id) return fail(res, 401, "session_expired", "Sign in again.");
  const uid = who.data.id;

  // 2. Account status, admin switches and the daily limit (per-user limit > admin default > env default)
  const [prof, sets] = await Promise.all([
    supa(`/rest/v1/profiles?select=status,ai_daily_limit,role&id=eq.${uid}`, { service: true }),
    supa(`/rest/v1/app_settings?select=key,value&key=in.(ai_enabled,ai_daily_limit)`, { service: true }),
  ]);
  const me = (prof.ok && Array.isArray(prof.data) && prof.data[0]) || {};
  const setting = k => { const row = (sets.ok && Array.isArray(sets.data) ? sets.data : []).find(r => r.key === k); return row ? row.value : undefined; };
  if (me.status === "suspended") return fail(res, 403, "account_suspended", "This account is paused. Contact the Exam Ready team.");
  if (setting("ai_enabled") === false) return fail(res, 503, "sampling_disabled", "The AI tutor is paused for maintenance. Practice still works.");
  const limit = Number.isInteger(me.ai_daily_limit) ? me.ai_daily_limit
    : Number.isInteger(setting("ai_daily_limit")) ? setting("ai_daily_limit")
    : parseInt(process.env.AI_DAILY_LIMIT || "80", 10);
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const count = await supa(`/rest/v1/ai_usage?select=id&user_id=eq.${uid}&created_at=gte.${encodeURIComponent(since)}`,
    { service: true, prefer: "count=exact", method: "HEAD" });
  const used = parseInt(((count.headers && count.headers.get("content-range")) || "*/0").split("/")[1] || "0", 10);
  if (used >= limit) return fail(res, 429, "rate_limited", `Daily AI limit of ${limit} requests reached. It resets over the next 24 hours.`);

  // 3. Build the request
  let body = req.body;
  if (typeof body === "string") { if (body.length > MAX_BODY) return fail(res, 413, "prompt_too_large", "Request too large"); body = JSON.parse(body || "{}"); }
  const { input, modelTier = "default", images = [], kind = "tutor", json = false } = body || {};
  let messages;
  if (typeof input === "string") messages = [{ role: "user", content: input }];
  else if (Array.isArray(input)) {
    // merge consecutive same-role turns (the app sends a rules turn followed by the chat)
    messages = [];
    for (const t of input) {
      if (!t || !t.content || !["user", "assistant"].includes(t.role)) continue;
      const last = messages[messages.length - 1];
      if (last && last.role === t.role) last.content += "\n\n" + t.content; else messages.push({ role: t.role, content: String(t.content) });
    }
    while (messages.length && messages[0].role !== "user") messages.shift();
  }
  if (!messages || !messages.length || messages[messages.length - 1].role !== "user") return fail(res, 400, "invalid_request", "No question supplied");
  if (Array.isArray(images) && images.length) {
    const last = messages[messages.length - 1];
    last.content = [
      ...images.slice(0, 2).filter(im => im && im.data && /^image\/(jpeg|png|webp|gif)$/.test(im.media_type))
        .map(im => ({ type: "image", source: { type: "base64", media_type: im.media_type, data: im.data } })),
      { type: "text", text: last.content }
    ];
  }
  const model = modelTier === "quick" ? (process.env.AI_MODEL_QUICK || "claude-haiku-4-5-20251001") : (process.env.AI_MODEL || "claude-sonnet-5-5");
  const system = SYSTEM + (json ? "\nYour reply will be parsed by a program: reply with only the JSON requested, no other text." : FLAG_RULE);
  const lastText = (() => { const c = messages[messages.length - 1].content; return typeof c === "string" ? c : (c.find(x => x.type === "text") || {}).text || ""; })();

  // 4. Call Anthropic
  let ar;
  try {
    ar = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": process.env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model, max_tokens: modelTier === "quick" ? 1200 : 3000, system, messages })
    });
  } catch (e) { return fail(res, 502, "upstream_error", "Could not reach the AI service"); }
  const out = await ar.json().catch(() => null);
  if (!ar.ok || !out) {
    const msg = (out && out.error && out.error.message) || `AI service error ${ar.status}`;
    return fail(res, ar.status === 429 ? 429 : 502, ar.status === 429 ? "rate_limited" : "upstream_error", msg);
  }
  let text = (out.content || []).filter(b => b.type === "text").map(b => b.text).join("");
  const modelFlag = !json && text.includes(FLAG_TOKEN);
  if (modelFlag) text = text.split(FLAG_TOKEN).join("").replace(/^\s+/, "");
  // Only the student's own typed message is checked by keyword (the app's long instruction turn is merged into earlier turns).
  const typed = Array.isArray(input) ? String((input[input.length - 1] || {}).content || "") : lastText;
  const wordFlag = !json && RISK_WORDS.test(typed);
  const writes = [];
  if (modelFlag || wordFlag) {
    writes.push(supa("/rest/v1/safety_flags", { method: "POST", service: true, body: {
      user_id: uid, category: "wellbeing", source: modelFlag && wordFlag ? "model+keyword" : modelFlag ? "model" : "keyword",
      excerpt: typed.slice(-600), reply_excerpt: text.slice(0, 600) } }).catch(() => {}));
  }
  if (!text.trim()) return fail(res, 502, "empty_completion", "The tutor gave no answer");

  // 5. Log usage and any safety flag
  const usageRow = { user_id: uid, kind: KINDS.includes(kind) ? kind : "tutor", model,
    input_tokens: (out.usage && out.usage.input_tokens) || 0, output_tokens: (out.usage && out.usage.output_tokens) || 0 };
  writes.push(supa("/rest/v1/ai_usage", { method: "POST", service: true, body: usageRow })
    .then(r => { if (!r.ok) { const { model: _m, ...old } = usageRow; return supa("/rest/v1/ai_usage", { method: "POST", service: true, body: old }); } }) // database not yet upgraded
    .catch(() => {}));
  // Wait for the writes: Vercel may stop the function as soon as the response is sent.
  await Promise.all(writes);

  res.status(200).json({ text, truncated: out.stop_reason === "max_tokens", remaining: Math.max(0, limit - used - 1) });
};
