# Exam Ready

Exam practice for WAEC (WASSCE and GCE), NECO and JAMB UTME. It includes:

- Past questions with speed tracking.
- Proctored tests.
- Theory marking.
- Targets and a readiness report.
- Trivia and XP.
- An AI tutor that knows each student's weak spots.

Students and parents have separate accounts. A parent links to a child with a 6-letter family code and sees that child's scores, readiness, test-integrity log and AI usage.

## How it fits together

| Part | Where | What it does |
|---|---|---|
| `public/index.html` | Vercel (static) | The whole app: student screens, parent dashboard, sign-in. |
| `api/ai.js` | Vercel function | Checks the user's session and daily limit, then calls the Anthropic API. The API key never reaches the browser. |
| `api/config.js` | Vercel function | Gives the browser the Supabase URL and the public anon key. |
| `supabase/schema.sql` | Supabase | Tables, row-level security, sign-up trigger and the family-code functions. |

Who can see what is enforced by the database (row-level security), not by the app:

- A student can read and write only their own progress.
- A parent can read only children who redeemed one of their codes.
- Nobody can change their own role after sign-up.

## Set it up (about 20 minutes)

You need free accounts at [supabase.com](https://supabase.com), [vercel.com](https://vercel.com) and [github.com](https://github.com), plus an Anthropic API key from [console.anthropic.com](https://console.anthropic.com). The key is pay-as-you-go, so add a little credit.

### 1. Supabase (database and logins)

1. Create a new project. Choose a region near your users; for Nigeria, `eu-west` (London/Ireland) is usually the closest.
2. Open **SQL Editor → New query**, paste the whole of `supabase/schema.sql`, and click **Run**. It is safe to run again later.
3. Go to **Project Settings → API** and copy three values:
   - **Project URL**
   - **anon public** key
   - **service_role** key (keep this one secret)

### 2. Put the code on GitHub

Create a new private repository and upload the contents of this folder: `api/`, `public/`, `supabase/`, `package.json`, `vercel.json` and this README. Do **not** upload a `.env` file.

### 3. Vercel (hosting)

1. **Add New → Project**, then import the GitHub repository. Leave the framework as **Other** and the build settings empty.
2. Under **Environment Variables**, add these:

   | Name | Value |
   |---|---|
   | `SUPABASE_URL` | Project URL from step 1 |
   | `SUPABASE_ANON_KEY` | anon public key |
   | `SUPABASE_SERVICE_ROLE_KEY` | service_role key |
   | `ANTHROPIC_API_KEY` | your Anthropic key |
   | `AI_DAILY_LIMIT` | optional, default `80` requests per student per day |

3. Click **Deploy**. You'll get an address like `exam-ready.vercel.app`.

### 4. Tell Supabase your web address

In Supabase, go to **Authentication → URL Configuration**:

- Set **Site URL** to your Vercel address, for example `https://exam-ready.vercel.app`.
- Add the same address under **Redirect URLs**.

The links in confirmation and password-reset emails depend on this.

> **Optional:** **Authentication → Emails → SMTP Settings** lets you send from your own address. Supabase's built-in email service is limited to a few emails an hour, which is fine for a family but not for a school.

### 5. First use

1. **Parent:** open the site, choose **Create an account → Parent or guardian**, confirm your email, then sign in.
2. **Add a child:** type the child's name and tap **Create family code**. You'll get a 6-letter code. It works once and is valid for 14 days.
3. **Student:** on their own phone or laptop, choose **Create an account → Student**, enter the family code, and confirm their email. A student who is already signed up can enter the code under **Today → Account**.
4. The child's progress appears on your dashboard. It refreshes every minute; you can also tap **Refresh**.

### Moving progress from the earlier version

1. In the earlier app (the one shared on claude.ai), open **Today → Student profile** and tap **Copy my progress**.
2. In the new site, sign in as the student and go to **Today → Account**.
3. Paste into the box and tap **Import pasted progress**.

This brings across:

- Scores
- Speed data
- Mistakes
- XP
- Badges
- Targets
- Paper dates

## Costs

- **Supabase and Vercel:** the free tiers are enough for a family or a small class.
- **Anthropic API:** you pay per use.
  - A tutor reply is roughly ₦10–₦40 at current rates.
  - Marking a theory answer costs slightly more.
  - Trivia uses the cheaper quick model.
  - `AI_DAILY_LIMIT` caps each student's requests per 24 hours. The parent dashboard shows each child's AI requests for the past week.
  - Set a monthly spend limit in the Anthropic console as a backstop.

To change models, set `AI_MODEL` (tutor and marking) and `AI_MODEL_QUICK` (trivia and quick checks).

## Practice integrity

During a practice test:

- The tutor is locked.
- Copy and paste are blocked.
- Leaving the app for more than 2 seconds is counted. The third time submits the paper automatically.
- Flagged tests earn no bonus XP and are marked on the parent dashboard.

This discourages looking up answers on the same device, but it can't stop a second phone. For important mocks, supervise in person.

## Running it on your own computer

```bash
npm i -g vercel
cp .env.example .env    # fill in the values
vercel dev              # http://localhost:3000
```

## Adding questions

All questions live in `public/index.html`:

- **Objective questions** are in the `QB` array and the per-paper blocks.
- **Theory questions** are in `EQ`.

Answers the app worked out itself (where no official key exists) are marked "unverified" and labelled as such in the app.
