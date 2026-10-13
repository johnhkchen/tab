# Changelog

What changed in each version of Tab, newest first.

## [Unreleased]

Send Tab a bill and it fills in the expense for you to check.

### Added
- Bills to check: add a photo of a receipt or a PDF, and Tab reads the
  amount, the date, the dates it covers, and when it's due. You check it
  beside the original and save it as an expense, or drop it. Nothing counts
  until you save it.
- Forward bills by email: each person gets a private address. Set up a
  filter in Gmail, Outlook.com, iCloud Mail, or Fastmail once, and new bills
  land in Bills to check. Tab never asks for access to your mailbox. Gmail's
  forwarding code shows up on the page.
- A bill from a company you've logged before fills in that bill's split,
  payer, and autopay date. A first bill from a company can become a bill.
- A digest email on the 10th and 25th (or days you pick) lists bills waiting
  to be checked. A bill due sooner gets its own email.
- A bill that carries an unpaid balance from last time fills in only this
  period's charges, so nothing counts twice. Add the carried amount, or a
  late fee, in one field. A bill that says the account is past due is
  flagged.
- A bill that hasn't come in a week after it usually does shows "Late" on
  the Bills page and in the digest, in case autopay stopped.
- Keep the original with the expense if you like; otherwise Tab deletes it
  once you save or drop the bill.
- Self-hosting: set `ANTHROPIC_API_KEY` on `extract` to turn reading on
  (Claude Haiku), and `RESEND_WEBHOOK_SECRET` with `TAB_INBOUND_DOMAIN` to
  receive forwarded mail through Resend. Without them, bills are typed in by
  hand beside the original. `TAB_READS_PER_DAY` caps reading per person.

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
