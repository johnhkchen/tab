# Roadmap

The phases Tab gets built in, in order. Each phase ends demoable and fully tested
before the next one starts. The detailed, buildable spec for the current phases is
[specification.md](specification.md); what happened and why is in
[JOURNAL.md](JOURNAL.md).

Status: **done**, **in progress**, **next**, or **later**.

## Phase 0: Foundation (done, v0.1.0, 2026-10-12)

Everything the ledger stands on, with nothing to log expenses with yet.

- Monorepo: `web/` (Phoenix 1.8, Elixir 1.20, OTP 28), `extract/` (BAML Language
  0.21), `site/` (Astro 7 + Starlight + EmDash on Cloudflare Workers).
- Postgres row-level security groundwork: the `tab_user` role, `auth.uid()`, and
  `Tab.Repo.as_user/2`.
- `docker compose up` self-host stack, locked down for shared servers.
- `mise` toolchain and tasks, CI, tag-driven releases to GHCR.
- Public website at tab.b28.dev, admin behind Cloudflare Access.

## Phase 1: The ledger, enforced by the database (done, v0.2.0, 2026-10-12)

Groups, members, invites, expenses with every split type, payments, external
counterparties, private expenses, and the audit log, each with row-level security
policies per verb. Exit: the direct-database bypass tests pass for every table.
Spec: [specification.md §Phase 1](specification.md#phase-1-the-ledger-enforced-by-the-database).

## Phase 2: The web app people use (done, v0.2.0, 2026-10-12)

Sign-in, groups, adding expenses, balances (overall and per category), settling up
with confirmation, payment methods, CSV export, and email notifications.
Spec: [specification.md §Phase 2](specification.md#phase-2-the-web-app-people-use).

## Phase 3: Recurring bills and household tools (done, 2026-10-13, not yet released)

Recurring templates and one-tap logging, time-bound split overrides with day-based
proration, float tracking (days money sits before it's repaid), reminder drafts
for Venmo, text, and email, and per-recipient statement links.
Spec: [specification.md §Phase 3](specification.md#phase-3-recurring-bills-and-household-tools).

## Phase 4: Reading bills (later)

Forwarded email, receipt photos, and PDFs, read by the `extract/` service into
pending items a person confirms. Bring-your-own AI key on self-host. Recurrence
detection on top of phase 3's templates. The review-digest schedule. Inbound mail:
Cloudflare Email Routing with a store-first R2 + Queue relay on Cloud; on
self-host, polling a mailbox the person already has, or Resend's inbound
webhooks (decided when phase 4 is specified; no in-app mail server).

## Phase 5: Use Tab from Claude (later)

A remote MCP server with OAuth (Boruta), so people can log expenses and check
balances from Claude Code or Claude Desktop on their own subscription. Every tool
call runs as the signed-in person through the same row-level security.

## Sign in with Google, and passkeys (later)

More ways in, built inside Phoenix rather than through a hosted sign-in service
(Clerk and similar were considered and passed over: self-hosters would need an
account with them, and every privacy rule keys on Tab's own user ids). The
emailed link stays the default.

## Phase 6: Hosted Tab (later)

The Cloud edition on the maintainer's Hetzner server: billing accounts, Paddle,
plans (Hosted free, Plus $10/yr, Pro $24/yr), the 3-month trial and its extensions,
gifts, referrals, reading allowances, and Pro's owner features (aggregated
balances, reimbursements, multi-property bills). Hosted only after the self-host
edition is complete on its own.

## Always on

- The public website and its docs keep pace with what's shipped.
- Every page people read goes through the `stop-slop` skill and the brand voice.
- Ops for Cloud: Doppler for secrets, continuous Postgres backups to R2, a
  quarterly-tested restore runbook, no automatic failover.
