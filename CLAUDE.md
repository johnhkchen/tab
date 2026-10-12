# Tab

Shared expense tracking (Splitwise-shaped) where privacy is enforced by Postgres
row-level security. Monorepo:

- `web/` — Elixir/Phoenix app, OTP app `:tab`. Read `web/AGENTS.md` for Phoenix 1.8 rules.
- `extract/` — BAML Language service (not Python/TS BAML). Read
  `extract/.claude/skills/baml-core/SKILL.md` before writing BAML; v1 syntax differs from
  older BAML. Run it with `baml-cli` (pinned in mise.toml), not the `baml` wrapper.
- `site/` — the public website, one Cloudflare Worker. Landing and `/pricing` are EmDash pages
  (D1 + R2, edited at `/_emdash/admin`, seeded from `site/seed/seed.json`). Docs under `/docs`
  are Starlight Markdown in git, prerendered. Plan prices live only in `site/src/data/plans.ts`.
  Read `site/AGENTS.md`. Not shipped with the app: self-hosted copies never show Cloud pricing.

## Project memory: read first, update before stopping

Context gets compacted; these files don't. Treat them as the source of truth.

1. **At the start of a session**, read `docs/JOURNAL.md` (at least the latest entry) and
   `docs/ROADMAP.md`. Build the current phase from `docs/specification.md`.
2. **Add a `docs/JOURNAL.md` entry** (newest first, dated, same headings as the others:
   Done, Decided, State of the world, Gotchas, Next) whenever you:
   finish a unit of work, make or hear a decision, create or change anything outside
   the repo (Cloudflare, Doppler, GitHub, servers), hit a gotcha worth not hitting
   twice, or are about to stop. Same day: extend that day's entry instead of adding one.
3. **Keep `docs/ROADMAP.md` statuses current** when a phase starts or finishes.
4. **`docs/specification.md` is the spec for the current phases.** If the code has to
   differ from it, change the spec in the same commit and note why in the journal.
   When a new phase comes up, distill its section from `working_specification.md`.
5. **`working_specification.md` stays untracked.** It's the long-form product spec,
   including pricing rationale; never commit it.
6. Never write secret values into the journal or anywhere in git. Names and ids only.

## Commands

`mise run check` is the CI gate. Run it before calling work done. `mise tasks` lists all.

## Rules that aren't obvious from the code

- **All person-facing data access goes through `Tab.Repo.as_user/2`.** It switches to
  the `tab_user` role so RLS applies. Never query person data as the connection owner.
- **Every new table:** `ENABLE ROW LEVEL SECURITY` plus an explicit policy for each of
  select, insert, update, delete, written as SQL in the migration. One verb's policy
  never implies another's. `tab_user` has no DELETE: the ledger keeps history.
- **Extraction only proposes.** `extract/` gets no database credentials and no write
  path. Anything it returns lands as a pending item a person confirms.
- **Inbound mail is acknowledged only after it's committed to Postgres** (HTTP 2xx to the
  Cloudflare relay, `250` from the SMTP listener). Otherwise answer "try again later".
- **Nothing in the ledger may require AI.** `/healthz` stays 200 when extract is down.
- **Versions live in four places** (`web/mix.exs`, `extract/baml_src/main.baml`,
  `compose.yaml`, `CHANGELOG.md`); `mise run version:check` keeps them in step.
- **The pricing page must match the long-form spec exactly** (§9 there; summary in the journal): Hosted free $0, Plus $10/yr,
  Pro $24/yr, billed yearly; a once-a-year 6-month gift; a 3-month Plus trial for new
  accounts, extendable 6 months at a time on request, with best-effort reading (smaller
  limit, lower priority than paying); referrals earn 1/3/12 months (sign-up/Plus/Pro).
  No trial, gift, or referral ever charges. Reaching the reading allowance
  pauses reading; never a charge.
- **UI uses the b28 clay kit** (vendored in `web/` and `site/`; refresh both with
  `mise run sync-kit`). Copy follows the brand voice in `~/.claude/CLAUDE.md`, and every page or doc
  people will read goes through the `stop-slop` skill
  (`.claude/skills/stop-slop/`) before it ships.
