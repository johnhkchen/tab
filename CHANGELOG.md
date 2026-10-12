# Changelog

What changed in each version of Tab, newest first.

## [Unreleased]

### Added
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
- The web app: your groups, each group's balances (overall and by category),
  adding and editing expenses with everyone's share shown as you type, each
  expense's history, settling up with confirmation, invite links, people
  outside the group, your name and how to pay you, and a CSV of everything
  you're part of. It fits a phone screen.
- Signing in and signing up are one step: type your email, open the link.
- Emails when an expense you're in is added or its amount changes, and when a
  payment to you needs confirming.
- Email goes through Resend or any SMTP service you set up. With neither,
  emails (sign-in links included) go to the app's log.
- Pick your currency with `TAB_CURRENCY` (default `USD`).

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
