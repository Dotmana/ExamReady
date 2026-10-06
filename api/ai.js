// POST /api/ai — the tutor, question writer and theory marker.
// Verifies the Supabase session, enforces a per-user daily limit, then calls the Anthropic Messages API.
// Env: ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//      AI_MODEL (default claude-sonnet-5-5), AI_MODEL_QUICK (default claude-haiku-4-5-20251001), AI_DAILY_LIMIT (default 80)

const SYSTEM = `You are the tutor inside "Exam Ready", an exam-preparation app for secondary-school students in West Africa preparing for WAEC (WASSCE/GCE), NECO and JAMB UTME.
Stay on schoolwork, study skills and exam preparation. Be warm, encouraging and accurate, and follow the WAEC/NECO/JAMB syllabus.
If a student raises something personal or worrying, respond kindly and suggest they talk to a parent, teacher or another trusted adult.
Follow the formatting instructions given in the user's message.`;

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

  // 2. Daily limit
  const limit = parseInt(process.env.AI_DAILY_LIMIT || "80", 10);
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
  const system = SYSTEM + (json ? "\nYour reply will be parsed by a program: reply with only the JSON requested, no other text." : "");

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
  const text = (out.content || []).filter(b => b.type === "text").map(b => b.text).join("");
  if (!text.trim()) return fail(res, 502, "empty_completion", "The tutor gave no answer");

  // 5. Log usage (best effort)
  supa("/rest/v1/ai_usage", { method: "POST", service: true, body: {
    user_id: uid, kind: String(kind).slice(0, 20),
    input_tokens: (out.usage && out.usage.input_tokens) || 0, output_tokens: (out.usage && out.usage.output_tokens) || 0 } }).catch(() => {});

  res.status(200).json({ text, truncated: out.stop_reason === "max_tokens", remaining: Math.max(0, limit - used - 1) });
};
