// POST /api/admin — admin actions that need the server-only service key.
// Currently: { action: "delete_user", user_id, confirm_email } — permanently deletes the account and all its data
// (progress, reports, links, tasks, AI usage, safety flags cascade from the profile).
// Everything else the admin console does goes through database functions that check is_admin() themselves.

async function supa(path, { method = "GET", body, token, service = false } = {}) {
  const url = process.env.SUPABASE_URL.replace(/\/$/, "") + path;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: key, Authorization: `Bearer ${service ? key : token}`, "Content-Type": "application/json" };
  const r = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { ok: r.ok, status: r.status, data };
}
const fail = (res, status, code, message) => res.status(status).json({ code, message });

module.exports = async function handler(req, res) {
  if (req.method !== "POST") return fail(res, 405, "invalid_request", "Use POST");
  for (const k of ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"])
    if (!process.env[k]) return fail(res, 500, "not_configured", `Server is missing ${k}`);

  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!token) return fail(res, 401, "session_expired", "Sign in again.");
  const who = await supa("/auth/v1/user", { token });
  if (!who.ok || !who.data || !who.data.id) return fail(res, 401, "session_expired", "Sign in again.");

  // Ask the database, as the caller, whether they are an admin.
  const adm = await supa("/rest/v1/rpc/is_admin", { method: "POST", token, body: {} });
  if (!adm.ok || adm.data !== true) return fail(res, 403, "forbidden", "Admins only.");

  let body = req.body;
  if (typeof body === "string") body = JSON.parse(body || "{}");
  const { action, user_id, confirm_email } = body || {};

  if (action === "delete_user") {
    if (!/^[0-9a-f-]{36}$/i.test(String(user_id || ""))) return fail(res, 400, "invalid_request", "Missing user_id");
    if (user_id === who.data.id) return fail(res, 400, "invalid_request", "You can't delete your own account here.");
    const target = await supa(`/auth/v1/admin/users/${user_id}`, { service: true });
    if (!target.ok || !target.data) return fail(res, 404, "not_found", "User not found.");
    const email = target.data.email || "";
    if (String(confirm_email || "").trim().toLowerCase() !== email.toLowerCase())
      return fail(res, 400, "invalid_request", "Type the user's email exactly to confirm.");
    const del = await supa(`/auth/v1/admin/users/${user_id}`, { method: "DELETE", service: true });
    if (!del.ok) return fail(res, 502, "upstream_error", (del.data && (del.data.msg || del.data.message)) || "Delete failed");
    await supa("/rest/v1/admin_audit", { method: "POST", service: true,
      body: { actor: who.data.id, action: "delete_user", target: null, details: { email, user_id } } }).catch(() => {});
    return res.status(200).json({ ok: true });
  }
  return fail(res, 400, "invalid_request", "Unknown action");
};
