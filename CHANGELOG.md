# Changelog

What changed in each version of Tab, newest first.

## [0.3.0] - 2026-10-13

Bills that come back, people who go away, and asking for money without the awkward text.

### Added
- Bills: set up rent, internet, or any bill that comes back once, then log each
  one in a tap. Tab fills in the last amount, the day autopay takes it, and the
  dates it covers. A bill that stays the same asks you to confirm a new amount.
- Temporary splits: when someone's away or a guest stays, admins set a
  different split for a category and dates. It stops on its own. Two that
  overlap get saved side by side once an admin confirms how.
- The add-expense form suggests the split: the bill's usual one, or a
  temporary one, blended by day when the bill covers part of the time away.
- How long money waits: days between paying for everyone and getting paid
  back, for each person and each share. Days only, no interest.
- Ask for it: a Venmo note, a text, and an email for money someone owes you,
  ready to copy. Tab doesn't send them.
- Statement links: one person's month on a page they open without signing in.
  It shows only their own bills and payments, lasts 30 days, and anyone in the
  group can turn it off.

## [0.2.0] - 2026-10-12

The ledger and the web app: you can run your house's shared expenses on it.

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
