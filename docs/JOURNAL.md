# Journal

What happened, what was decided, and what's next, newest first. Read the latest
entry before starting work; add one before stopping (see `CLAUDE.md`).

Each entry: **Done**, **Decided**, **State of the world** (things that live outside
this repo), **Gotchas**, **Next**.

---

## 2026-10-12: v0.1.0 and v0.2.0 released; phases 1 and 2 built

### Done
- Scaffolded the monorepo and released **v0.1.0**
  (<https://github.com/johnhkchen/tab/releases/tag/v0.1.0>). Images
  `ghcr.io/johnhkchen/tab-web:0.1.0` and `tab-extract:0.1.0` are public, for amd64
  and arm64. A fresh `docker compose up` from those images passes `/healthz`.
- `web/`: Phoenix 1.8.15, Oban 2.24, RLS foundation migration (`tab_user` role,
  `auth.uid()`), `Tab.Repo.as_user/2`, `/healthz`, clay-kit home page. 12 tests.
- `extract/`: BAML Language 0.21.0 health server using `baml.http.Server`. 2 tests.
- `compose.yaml` locked down for shared servers (verified: Postgres unreachable
  from the host and from `extract`, no internet for Postgres, non-root, read-only,
  no capabilities). `compose.dev.yaml` publishes Postgres for local dev only.
- `site/`: Astro 7 + Starlight docs + EmDash 1.2.0 pages, deployed to Workers at
  <https://tab.b28.dev>. Prices live in `site/src/data/plans.ts`, guarded by a test.
- Vendored the `stop-slop` skill. Wrote `docs/ROADMAP.md` and
  `docs/specification.md` (phases 1–2).
- **Phase 1 built**: `mix phx.gen.auth --binary-id --live` for
  sign-in; migrations `*_create_ledger.exs` (tables, triggers, audit, views,
  `accept_invite`, `set_expense_shares`) and `*_ledger_policies.exs` (grants and
  one policy per verb per table); `Tab.Ledger.Split`; contexts `Tab.Groups` and
  `Tab.Ledger` (all through `Tab.DBError.as_user/2`). Tests: policy matrix,
  ledger rules, split properties (StreamData), contexts. 227 web tests.

- **v0.2.0 released** (phases 1 and 2):
  <https://github.com/johnhkchen/tab/releases/tag/v0.2.0>. Images
  `tab-web:0.2.0` and `tab-extract:0.2.0` pull anonymously; a fresh
  `docker compose up` from them passes `/healthz`, serves the new sign-in page,
  and logs the no-mail-provider warning. Website redeployed with the Email and
  `TAB_CURRENCY` docs.
- **Phase 2 built**: mail through Resend, SMTP, or the log;
  daisyUI removed and every page restyled on the clay kit with self-hosted
  fonts; one-field sign-in that also signs up; welcome, groups, group, add and
  edit expense (live share preview for every split type), expense with
  history, settle up, people, join, you, CSV export; email notifications as
  Oban jobs written as the recipient; page tests, two full journeys,
  colors-only-from-the-kit, and `mise run check:narrow` (every page at 360 px
  in headless Chrome, also a CI job). Demo data in `priv/repo/seeds.exs`.
  256 web tests.

### Decided
- **Stack:** Elixir/Phoenix + Postgres RLS; BAML Language as its own service;
  `mise` for tools and tasks (no justfile).
- **Website:** Astro + Starlight on Cloudflare Workers; EmDash for pages, docs stay
  Markdown in git, plan prices in git. Pretext is for the app's long lists
  (phase 2+), not the website; the website is CSS-only for layout.
- **Pricing (Cloud):** Hosted free $0 (no bill reading unless you bring a key),
  Plus $10/yr, Pro $24/yr, billed yearly, no usage billing, no metering. Reaching
  the reading allowance pauses reading, never charges. New accounts get a 3-month
  Plus trial with best-effort reading, extendable 6 months at a time on request
  (each request asks a question; testimonials never have to be positive and are
  labeled). Subscribers gift one 6-month Plus a year. Referrals: 1 month per
  sign-up (capped 12/yr), 3 per Plus purchase, 12 per Pro purchase.
- **Hosting:** Cloud runs on the maintainer's existing Hetzner server with the
  same `compose.yaml`, behind the isolation checklist in the long-form spec §7.2.
  Fly.io only as a manual restore target during a long outage. No automatic
  failover.
- **Inbound mail:** Cloud uses Cloudflare Email Routing with a store-first R2 +
  Queue relay; self-host uses an in-app `gen_smtp` listener. Mail is acknowledged
  only after it's committed to Postgres. Mailgun dropped. *Revised the same
  day:* self-host won't run its own mail server either; it'll poll an existing
  mailbox (IMAP) or use Resend's inbound webhooks. Decided in phase 4.
- **Phase 1 details that differ from the first draft of the spec** (the spec
  is updated): a payment the payee records is confirmed as written; editing a
  payment's amount, date, or parties resets its status; `set_expense_shares` is
  a second `SECURITY DEFINER` function; users get no UPDATE and profiles no
  INSERT as `tab_user`; settle-up is greedy (at most n−1 payments), not
  provably fewest; invites cap at 30 days.
- **Three phase-1 open questions settled** (all the recommended options):
  you settle up before you leave, but an admin can remove anyone; edits after
  payments are allowed, flagged (`edited_at`), and emailed to the split;
  archiving makes a group read-only for everyone, is reversible, and warns
  first if money's owed. Built into the ledger migrations (unreleased, so
  edited in place) with tests. Two holes found on the way: payments with a
  former member couldn't be recorded, and archived groups were still writable.
- **No Clerk.** Asked mid-phase-2; answered no: self-hosters would need a
  Clerk account, sign-ins would pass through a third party, and RLS keys on
  Tab's own `users.id`. `phx.gen.auth` stays; Google sign-in and passkeys are on
  the roadmap as a later phase, built in Phoenix.
- **Sign-up is sign-in.** The registration page is gone: a new email gets an
  account when it asks for a link, with the same reply as a known email.
- **Outbound mail:** Resend (Swoosh's Resend adapter), "for now, at least until
  there's a problem." Generic SMTP for self-hosters who want it; with neither,
  sign-in links go to the server log. Wired up in phase 2. Until then, prod
  can't send magic links.
- **Secrets:** Doppler project `tab` (configs `dev`, `stg`, `prd`). Self-hosters
  can still use `.env`.
- **Launch order for billing (phase 6):** plans + trial + extensions first;
  gifts and referrals after billing runs cleanly. Paddle needs terms, privacy,
  and refund pages on the site first.

### State of the world (outside the repo)
- **Cloudflare** (account `caaec605822549aee441310a1c77bb43`): D1 `tab-site`
  (`473087d4-44bf-4a31-9ff2-a934f05ecbdc`), R2 `tab-site-media`, KV
  `tab-site-session` (made by wrangler on first deploy), Worker `tab-site` on
  custom domain `tab.b28.dev` with a once-a-minute cron.
- **Cloudflare Access:** app "Tab website admin" on `tab.b28.dev/_emdash/*`,
  policy "Tab maintainer only" (john.hk.chen@gmail.com, one-time PIN, 24 h).
  Recreate or update with `mise run access:apply`. Team domain
  `b28.cloudflareaccess.com`. The account has other Access apps for b28.dev.
- **EmDash admin** set up by the maintainer, with the seed's home and pricing pages.
- **Local machine:** the v0.2.0 smoke test ran `docker logout ghcr.io` to
  prove anonymous pulls; log back in if you push images by hand.
- **Doppler** `tab/prd`: `CLOUDFLARE_API_TOKEN` (project token "tab project",
  rolled once after an accidental print), `CLOUDFLARE_ACCOUNT_ID`,
  `D1_DATABASE_ID`. `tab/dev` has the two ids only.
- **GitHub:** `johnhkchen/tab` is public. `main` is protected only by habit;
  merges go straight to `main` (no PRs) at the maintainer's request.
- `working_specification.md` (the long-form product spec, ~1,700 lines) is
  **untracked on purpose**. It holds the full pricing rationale and later-phase
  design. Don't commit it; distill from it into `docs/` as phases come up.

### Gotchas
- Port 4321 is taken by other projects on this machine; use ports above 48000 for
  local previews.
- Headless Chrome won't size a window below about 500 px; screenshot narrow
  layouts inside a `<iframe width=390>` served from the same origin.
- pnpm 12 blocks dependency build scripts; approvals live in
  `site/pnpm-workspace.yaml` (`allowBuilds`: esbuild, workerd).
- `doppler secrets set` without `--project`/`--config` goes to `tab/dev`
  (from `doppler.yaml`), and without `--silent` it prints the value. Always use
  `pbpaste | doppler secrets set NAME --project tab --config prd --silent`.
- The wrangler OAuth login can't write Access settings, and lists Access apps as
  empty. Use the project token through Doppler.
- `baml fmt` has no `--check`; `mise run check:extract` formats a copy and diffs.
- GitHub sometimes times out serving the Tailwind binary during the Docker build;
  re-run the failed job.
- EmDash's catch-all `[slug].astro` route breaks Starlight's `/docs/`. Each EmDash
  page needs its own small route file in `site/src/pages/`.
- Headless Chrome with `--dump-dom` never exits on a LiveView page (the live
  connection keeps it busy). `/dev/narrow` frames pages in sandboxed iframes
  (no scripts run), and `scripts/check-narrow` wraps Chrome in `timeout 45`.
- The clay kit's classes are unlayered CSS, so they beat anything in Tailwind's
  `@layer components`. Overrides of `.clay-button` go outside any layer.
- zsh doesn't split an unquoted `$var` into words: `env $vars cmd` passes one
  variable. Use `${=vars}`.
- `mix phx.gen.auth`'s generated tests assert exact wording; rewording the
  pages means updating them (done once for phase 2).
- `INSERT ... RETURNING` on `groups` fails RLS: the select policy is checked
  before the AFTER trigger adds the creator's membership. Ids come from Ecto, so
  don't add `read_after_writes` there.
- The test sandbox never commits, so deferred constraint triggers never fire on
  their own in tests. Force them with `SET CONSTRAINTS ... IMMEDIATE` (then back
  to `DEFERRED`); `Tab.Ledger` does this anyway.
- In the sandbox `now()` is the same for a whole test, and `timestamp(0)` rounds
  to the nearest second (up, too). Leave a second of slack in time comparisons.
- `RETURNING`-free BEFORE triggers fire before RLS `WITH CHECK`, so a trigger's
  error (like "payer must be a member") can show up instead of the RLS refusal.
- SQL function bodies are checked at creation; the ledger migration sets
  `check_function_bodies = off` because helpers refer to tables made later.

### Next
- **Start phase 3** (recurring bills and household tools): first distill its
  section into `docs/specification.md` from `working_specification.md` (the
  roadmap lists the pieces: recurring templates and one-tap logging, split
  overrides with day-based proration over `period_start`/`period_end`, float
  tracking, reminder drafts, per-recipient statement links). `expenses` already
  has `period_start`/`period_end`. Mark phase 3 "in progress" in the roadmap.
- Set up Resend for Cloud when hosting starts: verify the sending domain in
  Cloudflare DNS, put `RESEND_API_KEY` in Doppler `tab/prd`.
