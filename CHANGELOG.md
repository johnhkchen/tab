# Changelog

What changed in each version of Tab, newest first.

## [Unreleased]

### Added
- Sign in with an emailed link (a password is optional). Sending mail in
  production comes in the next phase; until then links only reach the dev mailbox.
- The ledger, kept honest by the database itself: groups, invites, members,
  counterparties (a landlord, a utility, the household next door), categories,
  expenses split equally, exactly, by percentage, by shares, or with fixed
  amounts off the top, and payments. Balances are worked out on the fly, never
  stored.
- A payment between two members counts once the person paid confirms it. A
  payment with a counterparty counts right away.
- Private expenses only their creator can see, not even the group's admin.
- You settle up before you leave a group. An admin can still remove someone
  who owes money, and payments with them still count.
- An expense changed after it was added is marked as edited.
- Admins can archive a group: it stays readable but nothing in it changes until
  they unarchive it.
- A history of every change, written by the database, that nobody can edit.
- No screens yet: this is the layer the web app will stand on.

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
