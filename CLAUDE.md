# Tab

Shared expense tracking (Splitwise-shaped) where privacy is enforced by Postgres
row-level security. Monorepo:

- `web/` — Elixir/Phoenix app, OTP app `:tab`. Read `web/AGENTS.md` for Phoenix 1.8 rules.
- `extract/` — BAML Language service (not Python/TS BAML). Read
  `extract/.claude/skills/baml-core/SKILL.md` before writing BAML; v1 syntax differs from
  older BAML. Run it with `baml-cli` (pinned in mise.toml), not the `baml` wrapper.

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
- **Nothing in the ledger may require AI.** `/healthz` stays 200 when extract is down.
- **Versions live in four places** (`web/mix.exs`, `extract/baml_src/main.baml`,
  `compose.yaml`, `CHANGELOG.md`); `mise run version:check` keeps them in step.
- **UI uses the b28 clay kit** (`web/assets/vendor/b28-clay.css`, refresh with
  `mise run sync-kit`). Copy follows the brand voice in `~/.claude/CLAUDE.md`.
