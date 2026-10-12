# Changelog

What changed in each version of Tab, newest first.

## [0.1.0] - 2026-10-12

The foundation. Nothing to log expenses with yet; everything the ledger will stand on.

### Added
- `docker compose up` runs all of Tab on one machine: the web app, the extraction
  service, and Postgres. Migrations run on boot; a secret is made on first boot.
- Row-level security groundwork: a `tab_user` database role that can't bypass
  policies or delete rows, and `auth.uid()` for policies to check against. Tests
  prove one person can't read or forge another person's rows.
- The extraction service, written in BAML, with no database access at all.
- `/healthz` reports the database and the extraction service.
- `mise install` sets up the whole toolchain; `mise run check` is the CI gate.
- `compose.yaml` is safe on a server that runs other things: Postgres has no open
  port and no internet access, `extract` can't reach it, and every container runs
  as a non-root user with a read-only filesystem and no extra privileges.
- The public website at tab.b28.dev: a landing page, a pricing page with every
  plan's price and rules, and docs for running Tab yourself and how privacy is
  kept. You edit the pages in EmDash at `/_emdash/admin`, which only the
  maintainer can open. Plan prices stay in `site/src/data/plans.ts`, and the docs
  stay in Markdown.
