# Journal

What happened, what was decided, and what's next, newest first. Read the latest
entry before starting work; add one before stopping (see `CLAUDE.md`).

Each entry: **Done**, **Decided**, **State of the world** (things that live outside
this repo), **Gotchas**, **Next**.

---

## 2026-10-16: v0.5.0 released; phase 5 built; phase 6 specified and mostly built

### Done
- Distilled phase 5 ("Use Tab from Claude") from the long-form spec §8 into
  `docs/specification.md`: decisions, configuration, endpoints, four OAuth
  tables with policies, seven tools, the You page section, and the tests that
  must pass before phase 6. ROADMAP points at it.
- Checked what Claude's clients and the libraries support today (sources:
  modelcontextprotocol.io authorization spec 2026-07-28, claude.com connector
  authentication docs, Boruta's changelog, anubis_mcp docs).
- Built phase 5. Migration `20261016090000_create_oauth.exs`: `oauth_clients`,
  `oauth_connections`, `oauth_codes`, `oauth_tokens` with one policy per verb,
  and `via` on expenses and payments, stamped by a trigger from `app.via`.
  `Tab.Repo.as_user/3` takes `via:`; `Scope.for_claude/1` carries it.
- `Tab.OAuth` (codes, PKCE, rotating refresh tokens, revocation, CIMD and
  DCR clients), `Tab.OAuth.CIMD` (public-address-only fetch, pinned IP, 10 KB,
  5 s), `Tab.OAuth.RateLimit` (ETS), a nightly sweep of unused DCR clients.
- `TabWeb.OAuthController` (metadata, token, register, revoke), the consent
  page `/oauth/authorize`, the `/mcp` plug (`TabWeb.MCP`) and its seven tools
  (`TabWeb.MCP.Tools`). The You page lists connections with Disconnect;
  expenses and payments show "from Claude".
- `/dev/narrow` covers the consent page and takes `?only=/profile,/oauth` to
  screenshot a few pages. 22 of 22 fit 360 px.
- Docs page `/docs/claude/` ("Use Tab from Claude"), a `TAB_MCP` row on the
  self-host page, a privacy line, and "What works today" says 0.5.0 (site not
  deployed yet; that waits for the release).
- Checked with real clients instead of by hand: Tab fetched Claude Code's
  real metadata document (`https://claude.ai/oauth/claude-code-client-metadata`,
  loopback callbacks with no port, `max-age=300`) over pinned TLS, and the
  official MCP TypeScript SDK (1.32.1) ran the whole flow against a dev server
  with CIMD and with DCR: discovery from the 401, PKCE, `iss`, tokens, then
  `tools/list` and tool calls on 2025-11-25. A script stood in for the
  Connect click. Only the browser click itself is untested.
- That check found a bug: the 401 challenge named only `tab:read`, and
  clients ask for the challenge's scopes, so every connection came out
  read-only. The challenge now names both; the tick box decides. Test added.
- **v0.5.0 released** (tag `v0.5.0`): phase 5. Website redeployed with
  `/docs/claude/`, the `TAB_MCP` row, the privacy line, and "What works
  today" at 0.5.0.
- 445 web tests (was 416), including the policy matrix for the four tables
  and an end-to-end flow over HTTP. A live dev server answers discovery and
  registration correctly.

- Phase 6, built without anything from John (all dark unless
  `TAB_EDITION=cloud`):
  - Delete my account (every edition): `ledger.forget_user` in migration
    `20261016130000_forget_user.exs`; the audit log's append-only trigger
    allows deleting only the forgotten person's private entries.
  - `Tab.Billing` (migration `20261016125000_create_billing.exs`): plans from
    dates, the 3-month trial once per address (hash kept after deletion),
    the daily sign-up limit, monthly reading allowances with the 80% email,
    lower read priority for trials, asking for more and granting it.
  - `Tab.Billing.Paddle`: the signed webhook at `/paddle/webhook`, the
    customer portal link, and cancel-plus-refund when an account is deleted.
  - Pages: `/plans` (Paddle.js checkout), `/admin`, the plan line on the You
    page, the reading note on Bills to check.
  - Website (not deployed): Terms and Refunds drafts with two blanks for John
    (contact email, governing law), a Hosted Tab section on Privacy, pricing
    copy without the own-key line and with Pro "Opens later".
  - 481 web tests (was 445); 360 px check passes, including `/plans` and `/admin` with
    `TAB_EDITION=cloud TAB_ADMIN_EMAILS=priya@example.com`.

### Decided
- Phase 6 specified (`docs/specification.md` §Phase 6). Hosted Tab ships in
  three phases: 6 opens it (Hosted free and Plus), 7 is Pro's landlord tools
  and selling Pro, 8 is gifts, referrals, and submission links. ROADMAP
  rewritten to match.
- Phase 6 sells Plus only; Pro shows "Opens later" until phase 7.
- Plus covers one person, in all their groups.
- No reading and no own-key option on Hosted free (the pricing page and the
  long-form spec's §2.1 and §9 lines changed to match).
- Allowances per person per month: Plus 100, Pro 300, trial 20. Trial jobs
  run at lower priority.
- Cloud mail stays on Resend inbound (John's pick over the Cloudflare relay);
  Resend's paid plan when the free 100 a day runs short.
- Refunds: 30 days, full. Sign-up: open, 50 new accounts a day. Trial
  extensions granted on a small `/admin` page that shows no ledger data.
- Deleting an account removes the person and their private data and keeps
  shared expenses under "Former member"; on every edition.
- Cloud's Anthropic key must be a standard paid API account, not Max-plan
  credits.
- Tab runs its own small OAuth 2.1 server instead of Boruta. Boruta 2.3.8 has
  no resource indicators (RFC 8707, required by MCP) and no client ID metadata
  documents; its 3.0 line has been beta since 2025.
- Registration: CIMD first, DCR as fallback. PKCE S256 only; tokens bound to
  `https://<host>/mcp`; 1-hour access tokens, 30-day rotating refresh tokens.
- Two scopes, `tab:read` and `tab:write`; the consent page's write box is
  ticked by default.
- Claude's writes save at once with `via = 'claude'` ("Added from Claude");
  no editing, deleting, or confirming through Claude in phase 5.
- Tools: list_groups, get_balances, list_recent_expenses, suggest_settle_up,
  list_bills_to_check, add_expense, record_payment.
- MCP library: none. While building, MCP 2026-07-28 turned out to drop
  sessions and the `initialize` handshake, and `anubis_mcp` stops at
  2025-11-25. `TabWeb.MCP` is a stateless plug serving both eras. Spec updated.

- Hosting: there's no Hetzner server yet. One will be made with Pulumi from a
  new repo, `b28-infra`, as a shared box for the maintainer's projects, each
  in its own slot (Unix user, rootless Docker, Caddy route, DNS, R2 backups,
  Doppler token). Pulumi state in R2. Tab is the first and only project for
  now. Deploys stay per project (`mise run deploy`). Kamal and Coolify were
  passed over: one Docker setup for every app loses per-project isolation.

### State of the world
- Nothing outside the repo changed.

### Gotchas
- `git add -A` staged `working_specification.md`; caught before committing.
  It's now in `.git/info/exclude` (local only), so `git status` no longer
  lists it. Stage paths by name anyway.
- `@callback` is a reserved module attribute: a test using it fails with a
  typespec error. Use another name.
- BSD `sed` has no `\b`; use `perl -pi -e` for word-boundary edits.
- Headless Chrome drops the session cookie between runs, so screenshots of
  signed-in pages go through one `/dev/narrow?shots=1&only=...` load.
- The dev database holds real bills from phase 4 testing. Screenshots of
  `/dev/narrow` can show them; delete them after looking.
- claude.ai and Desktop connect from Anthropic's servers (`160.79.104.0/21`),
  so they need Tab on public HTTPS. Claude Code connects from the person's own
  machine and uses a loopback callback on a random port: match loopback
  redirects with any port.
- claude.ai picks CIMD only when the metadata advertises
  `client_id_metadata_document_supported: true` and `none` in
  `token_endpoint_auth_methods_supported`; otherwise DCR.
- Claude refreshes tokens up to 5 minutes early and expects refresh-token
  rotation for public clients; token endpoints get 10 seconds.

### Next
1. Optional: click through Connect with real Claude Code once
   (`claude mcp add --transport http tab-dev http://localhost:4000/mcp`).
2. John: fill the two blanks in `site/src/content/docs/docs/terms.md` and
   `refunds.md` and read both; then deploy the site.
3. John: Paddle account (sandbox first), a standard Anthropic API key for
   Cloud, SSH access to the Hetzner server. Then: a sandbox checkout end to
   end, the deploy checklist, WAL to R2, the restore runbook.

---

## 2026-10-13: v0.3.0 and v0.4.0 released; phases 3 and 4 built

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
- **v0.4.0 released** (tag `v0.4.0`): phase 4, reading bills. Website docs:
  new page `/docs/reading/` ("Send Tab your bills"), a "Reading bills"
  section on the self-host page (Anthropic key, Resend receiving domain and
  webhook, settings table), two privacy lines (originals deleted; Resend and
  Anthropic see what's sent), and "What works today" for 0.4.0.
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
- **Benchmark on a real bill** (the maintainer's own 8-page PG&E statement,
  read in place from outside the repo, never committed; bill-derived scratch
  files deleted afterwards; no amounts or account details recorded here):
  3 runs, identical answers, 4.8 to 6.8 s each, about 20,500 input tokens
  (about $0.002 a read at reported Haiku 5.5 prices). Right: type, merchant,
  statement date, due date. Wrong for Tab: the total due included an unpaid
  balance carried over from the last bill, so saving it as-is would count
  that bill twice. Missed: the service period (electric and gas print
  periods a day apart, and the reader left both blank), and the bill's
  "account is past due" notice (no field for it). A scratch prototype with
  `previous_balance`, `current_charges`, and `past_due` fields caught the
  carried balance and the past-due notice on both runs; PG&E prints no
  single current-charges line, so code would work it out as total minus
  carried balance.
- From the real-bill benchmark, the maintainer decided: the form fills in
  this period's charges plus a "Carried over from earlier bills" field
  (default 0, one tap to add the carried balance, also for late fees); a
  past-due bill is flagged only, no email; late bills (nothing logged a week
  past the usual time) show on the Bills page and in the digest of whoever
  usually pays. Built before v0.4.0. The reader gained `current_cents`,
  `previous_cents`, `past_due`, and earliest-start/latest-end periods; rerun
  on the same real bill, 2 of 2 runs got all of them right.
- Forwarding addresses are per person per group, readable:
  `<group-name>-<10-letter tag>@bills.tab.b28.dev` (maintainer's pick after
  `bills@bills...` read badly). Changed the unreleased inbox migration in
  place and rebuilt dev and test databases. `mix tab.mail.pull --route`
  routes pulled mail by address, like the webhook. Doppler `tab/dev` has
  `RESEND_API_KEY` and `TAB_INBOUND_DOMAIN=bills.tab.b28.dev`.
- **One bill, several documents** (maintainer's calls): same company and
  amount within 45 days, or same due date, is one bill; a document for a bill
  already saved attaches to the expense; originals are never kept, only a
  reference with a search line ("keep a search term reference but don't
  store sensitive documents"), which replaced "Keep the original"; built
  before v0.4.0. `documents.item_id` replaces `pending_items.document_id`
  (unreleased migration changed in place; down now drops with CASCADE).
  The reader returns `kind` (bill, notice, autopay_scheduled, payment,
  reminder, other) and `paid_on`; the email parser takes sender, subject,
  and date from the forwarded block. On the maintainer's 3 real forwarded
  emails (PG&E notice, Recology payment, SFPUC notice) the kinds, senders,
  dates, and amounts came out right; the PG&E due date varies between runs
  (the email prints it bare beside the amount).
- Grouping checked on real documents in dev (maintainer's Recology and
  SFPUC bills, forwarded to the per-group dev address and uploaded as PDFs;
  nothing from them committed): Recology's "scheduled" and "approved"
  payment emails plus its PDF bill became one bill; SFPUC's notice email and
  its PDF stayed apart until "same amount and same due date" was added,
  since the email says "SFPUC (San Francisco Water, Power and Sewer)" and the
  PDF "San Francisco Water Power Sewer". Recology really does send two
  emails per payment (scheduled, then approved).
- **Aliases, forwarders, and fixing grouping** (maintainer's calls, all the
  recommended options, before v0.4.0): aliases live on each bill
  (`recurring_templates.aliases`, replacing the unreleased `sender`), learned
  on save and on manual joins, editable on the Bills page; `bill_forwarders`
  per group, suggested when one address sends bills naming two companies;
  "Same bill as another?" and "Not part of this bill" on a bill to check,
  with each document's own `reading` so both bills are rebuilt. The email
  parser now reads the innermost forwarded block (a landlord's forward,
  forwarded again). Dev and test databases rebuilt from scratch for the
  changed unreleased migration. Re-run on the maintainer's real documents in
  dev: SFPUC email and PDF, and Recology's two emails and PDF, each became
  one bill with every name collected; the repeat Recology forward was caught.
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
- Resend: domain `bills.tab.b28.dev` added (us-east-1) with receiving on;
  forwarding addresses will live there (maintainer's pick over `tab.b28.dev`
  and `in.b28.dev`). Resend's Cloudflare auto-config added
  `resend._domainkey`, `send` and `rsend` CNAMEs (to `forge.rmta.net`), and,
  once receiving was switched on, `MX bills.tab.b28.dev 10
  inbound-smtp.us-east-1.amazonaws.com`. b28.dev's Google Workspace MX
  records and `tab.b28.dev` are untouched. Free plan: received mail counts
  toward 100/day and 3,000/month.
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
- Resend's receiving toggle sits on the domain's own page and only adds its
  MX record once switched on; auto-config adds the sending records first.
  Read the zone through Cloudflare's API when public DNS lookups flake.
- `MIX_ENV=test mix ecto.reset` runs the seeds into the test database and
  breaks tests that count rows; use drop, create, migrate instead.
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
- Phase 5 (Use Tab from Claude: MCP server with OAuth): distill its section
  from `working_specification.md` and ask the maintainer the open calls.
- Outside the repo, for Cloud (when it launches): the `email.received`
  webhook on `bills.tab.b28.dev` pointing at `/inbound/resend`,
  `RESEND_WEBHOOK_SECRET`, `TAB_INBOUND_DOMAIN`, and a full-access
  `RESEND_API_KEY` in Doppler `tab/prd`; Resend's paid plan once real mail
  flows (the free plan counts received mail toward 100 a day).

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
