// GET /api/config — public settings for the browser (the anon key is safe to expose; RLS protects the data).
module.exports = function handler(req, res) {
  res.setHeader("Cache-Control", "public, max-age=300");
  res.status(200).json({
    supabaseUrl: process.env.SUPABASE_URL || "",
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY || "",
    aiEnabled: !!process.env.ANTHROPIC_API_KEY,
    appName: process.env.APP_NAME || "Exam Ready"
  });
};
