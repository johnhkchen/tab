# Journal

What happened, what was decided, and what's next, newest first. Read the latest
entry before starting work; add one before stopping (see `CLAUDE.md`).

Each entry: **Done**, **Decided**, **State of the world** (things that live outside
this repo), **Gotchas**, **Next**.

---

## 2026-10-12: v0.1.0 released, website live, phases 1–2 specified

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

### Next
- Start **phase 1** from `docs/specification.md`: `mix phx.gen.auth` with binary
  ids, then the schema migrations with their RLS policies, then the policy-matrix
  tests, then `Tab.Ledger.Split` with property tests.
