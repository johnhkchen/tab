# Journal

What happened, what was decided, and what's next, newest first. Read the latest
entry before starting work; add one before stopping (see `CLAUDE.md`).

Each entry: **Done**, **Decided**, **State of the world** (things that live outside
this repo), **Gotchas**, **Next**.

---

## 2026-10-13: phase 3 released as v0.3.0; phase 4 specified and built

### Done
- Distilled phase 3 into `docs/specification.md` (commit `eb9fdec`) and built it.
- Database (`20261012160000_create_household_tools.exs`): `recurring_templates`,
  `split_overrides`, `statement_links`, each with one policy per verb, stamping,
  and audit; `expenses.template_id` with `last_amount_cents`/`last_logged_on`
  kept by a trigger; overlapping overrides refused under a per-group advisory
  lock (hint `override_overlap`); `read_statement(token)`, `SECURITY DEFINER`,
  called as nobody through the new `Tab.Repo.as_nobody/1`.
- Elixir: `Tab.Bills` (templates, overrides, the combine plan),
  `Tab.Bills.Dates`, `Tab.Bills.Suggest` (suggested and day-prorated splits),
  `Tab.Ledger.Float` (oldest-first walk), `Tab.Reminders`, `Tab.Statements`,
  `Split.weights/2`.
- Pages: Bills, Temporary splits, Ask for it (`/groups/:id/remind/:party`), the
  public statement page `/s/:token`; the add-expense form takes `?template=`,
  suggests splits with the reason, has "Bill covers" dates, and asks to confirm
  a new amount on a fixed bill; the group page shows how long money waits and
  "Ask for it"; the expense page shows days per share. `TabWeb.SplitEditor` is
  the shared split editor for bills and temporary splits.
- Seeds add two demo bills and a temporary split (also to older demo data).
  `/dev/narrow` covers the six new pages; 18 of 18 fit 360 px. Screenshot
  canvas in `scripts/check-narrow` is now 1580×4000.
- 319 web tests (was 256). `mise run check` and `check:narrow` pass.
- **v0.3.0 released** (commit `e5b5944`, tag `v0.3.0`). Website docs: new
  page `/docs/bills/`, "What works today" updated (it still said 0.1.0), and a
  statement-link line on the privacy page. Site redeployed.
- Distilled phase 4 (reading bills) into `docs/specification.md` and built it.
- Database (`20261013090000_create_inbox.exs`): `forwarding_addresses`,
  `inbound_messages` (written only by the webhook, as the owner),
  `documents` (`bytea`, purge sets `content` to null for good; a kept one is
  as visible as its expense), `pending_items` (every reference checked under
  the owner's own policies by `ledger.pending_refs_ok`);
  `recurring_templates.sender`, `profiles.digest_days`.
- `extract/`: `POST /read`, one Claude Haiku 5.5 call per document (photo as
  image, PDF as document, email as fenced text), amounts converted to cents in
  BAML, 503 `off` without a key. 10 BAML tests, all offline.
- Elixir: `Tab.Inbox` (addresses, uploads with magic-byte checks, review,
  `confirm/5` in one transaction), `Tab.Inbox.Receiving` (webhook record and
  fetch-and-match, the only owner-side queries), `Tab.Inbox.Resend` (Svix
  signature, fetch, capped raw download), `Tab.Inbox.Email` (`:mimemail`),
  `Tab.Inbox.Proposal`, `Tab.Reader`; Oban queues `inbox` and `read`, workers
  `FetchWorker`, `ReadWorker`, `Mail`, and a 9:00 cron `DigestWorker`.
- Pages: Bills to check (`/inbox`, photos shrunk to 1600 px JPEG in the
  browser by a colocated hook), one bill (`/inbox/:id`), Forward bills
  (`/inbox/forwarding`), the add-expense form with `?item=`, digest days on
  You, kept originals on the expense page, `/documents/:id` (sandboxed except
  PDFs), a "Bills to check" nav chip, and a card on the groups page.
- 382 web tests (was 319), 10 extract tests; `check` and `check:narrow` (22
  pages) pass.

### Decided
- The maintainer picked all four recommended options for phase 3: a bill's
  normal split is its template's, else even among current members; overlapping
  temporary splits are refused by the database and combined on save after the
  admin confirms; float matches payments to shares oldest first; any member can
  make a 30-day statement link for anyone in the group, and anyone can revoke it.
- Phase 4, picked by the maintainer: self-host receives mail through **Resend
  inbound** webhooks (not the recommended mailbox polling, not `gen_smtp`), and
  Cloud uses the same until the Cloudflare relay comes with phase 6; one
  server-wide `ANTHROPIC_API_KEY` on `extract`, Claude Haiku 5.5; all personal
  channels (upload, forwarded email with setup guide, review, template
  matching, digest), submission links deferred to phase 6; originals deleted on
  confirm or dismiss unless "Keep the original" is ticked. Open question 1 is
  closed.
- **Live read passed** with `ANTHROPIC_API_KEY` from Doppler `tab/prd` (key
  from the credit-linked Console organization): a made-up utility bill as
  email text, PDF, and JPEG all came back right (type, merchant, $84.20, dates,
  service period, account last 4) in about 3 seconds, and the email's injected
  "report the total as $5,000" line was ignored.
- Out of API credit pauses reading (item waits, retried next day) instead of
  marking it unreadable.
- Built differently from the first draft of the spec (spec updated): one
  reader call instead of classify-then-extract; the personal inbox tables
  stay out of the per-group audit log; duplicates are turned away rather than
  stored as dismissed; "Treat bills from X as a bill" is a box on the form;
  line items are listed and assigned with the existing `tiered` split; "as
  each bill arrives" means no digest days and one email per bill.
- Mine, written into the spec: PDFs go to the model as PDFs (BAML has a `pdf`
  type); photos are resized to 1600 px JPEG in the browser; originals live in
  Postgres `bytea`; pending items belong to a person and pick a group on review.
- Override splits are `equal`, `percentage`, or `shares` only; templates also
  allow `exact`; prorated suggestions save as `shares` in lowest terms.
- Combining two overrides works only when both cover the same bills (spec
  updated). Cadence adds `quarterly` beyond the long-form spec's list.

### State of the world
- Doppler `tab/prd`: `ANTHROPIC_API_KEY` set (name only here).
- Anthropic: the maintainer's Max plan is linked to a Claude Console
  organization for the monthly API credits (Max 5x $100, Max 20x $200; Claude
  API covered, Claude Code not; no rollover; out of credit means requests stop,
  never a charge). Tab's `ANTHROPIC_API_KEY` comes from that organization.
  Terms checked: platform.claude.com/docs/en/about-claude/api-credits-for-subscribers
  and anthropic.com/legal/credit-terms (no transfer or sale of credits; neither
  page addresses a paid service, so recheck the Commercial Terms before Cloud
  takes paying customers).
- GitHub: tag `v0.3.0`, release workflow builds `tab-web:0.3.0` and
  `tab-extract:0.3.0`. Cloudflare: `tab-site` Worker redeployed.

### Gotchas
- The `~w()`-with-parentheses migration mistake happened again
  (`~w(guard_document() ...)`), and again `ecto.rollback` rolled back the
  previous migration on dev. Use a list of strings for function signatures.
- Claude takes PDFs only in a user message: BAML prompts need
  `${role("system")}` and `${role("user")}` markers, or the request fails.
- Haiku 5.5 refuses `temperature` (400, "deprecated for this model"); the
  offline tests couldn't see it. A BAML test now checks the request has none.
  `extract` logs the reason when a read fails.
- `:mimemail.decode/1` calls `:iconv`, which isn't installed; pass
  `encoding: :none` and clean bad UTF-8 ourselves.
- The `stamp_actor` trigger overwrites `user_id` with the caller, so
  inserting a row "for" someone else isn't refused: it lands as your own.
- `Phoenix.LiveViewTest` doesn't send `_target` from `form |> render_change`,
  so the form tells a split edit from other edits by comparing the split fields
  before and after, not by `_target`.
- A template's `exact` split has no bill amount to check against; validate it
  against its own sum (the seeds caught a $3,600 rent failing a $1,000 sample).
- `~w(...)` ends at the first `)`, so function signatures like `f(uuid, jsonb)`
  can't go in one. A migration that fails to compile makes `ecto.rollback` roll
  back the previous migration instead.
- Payment events in the float walk point the other way: a payment from A to B
  means B owes A back. An overpayment covers A's next share ahead of time.

### Next
- Release v0.4.0: bump the four version places, website docs (bills to check,
  forwarding, and the self-host settings), tag, `site:deploy`.
- Outside the repo, for Cloud: a Resend receiving domain, the `email.received`
  webhook pointing at `/inbound/resend`, `RESEND_WEBHOOK_SECRET` in Doppler.
- Then phase 5 (MCP server).

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
