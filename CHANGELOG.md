# Changelog

What changed in each version of Tab, newest first.

## Unreleased

### Added
- The public website in `site/`: a landing page, a pricing page that states the
  full formula, and docs for running Tab yourself and how privacy is kept.

### Changed
- You edit the landing and pricing pages in EmDash now, at `/_emdash/admin`, not in code.
  Plan prices stay in `site/src/data/plans.ts`, and the docs stay in Markdown.

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
