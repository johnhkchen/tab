---
title: Run it yourself
description: Run Tab on your own computer or server with one command. Free, forever.
---

Running Tab yourself is free, forever, and your data never leaves your machine.

## What you need

- A computer that stays on: a spare laptop, a home server, or a small rented
  server (a few dollars a month).
- [Docker](https://docs.docker.com/get-docker/).

## Start it

```sh
git clone https://github.com/johnhkchen/tab.git
cd tab
docker compose up
```

Open <http://localhost:4000>. That's all: the database is created and kept up to
date every time Tab starts.

To check everything is running, open <http://localhost:4000/healthz>. You should
see `"db": "ok"`.

## What's running

| Part      | What it does                                                              |
| --------- | ------------------------------------------------------------------------- |
| `web`     | The app you use, on port 4000.                                            |
| `db`      | The database. Your data lives in a Docker volume called `tab-db`.         |
| `extract` | Reads bills and receipts. Optional: everything else works without it.     |

## Settings

Put these in a file called `.env` next to `compose.yaml` if you need them:

| Setting             | What it's for                                                     | Default     |
| ------------------- | ----------------------------------------------------------------- | ----------- |
| `PORT`              | The port Tab is reachable on.                                     | `4000`      |
| `TAB_LISTEN`        | Which address Tab listens on. Use `127.0.0.1` behind a reverse proxy, or on a server that runs other things. | `0.0.0.0` (every address) |
| `PHX_HOST`          | The address people type to reach Tab.                             | `localhost` |
| `POSTGRES_PASSWORD` | The database password. Set it before the first start.             | `postgres`  |
| `SECRET_KEY_BASE`   | Signs logins. Leave it out and Tab makes one on first start.      | (made for you) |
| `TAB_CURRENCY`      | The currency every amount is in, one per install (`USD`, `EUR`, `GBP`…). | `USD` |

## Email

Tab emails you a link to sign in, and lets people know when an expense or
payment involves them. It doesn't run its own mail server; it hands mail to a
service you already have.

- **No settings:** emails go to Tab's log instead. To sign in, run
  `docker compose logs web`, find the link, and open it in your browser.
  Everything else works.
- **[Resend](https://resend.com):** the easiest. Make an account, add your
  domain, create an API key, and set `RESEND_API_KEY`.
- **Any other mail service** (Fastmail, Gmail with an app password, Amazon SES,
  Postmark): set the `SMTP_` settings it gives you.

| Setting         | What it's for                                                  | Default |
| --------------- | -------------------------------------------------------------- | ------- |
| `RESEND_API_KEY` | Send through Resend.                                          | (none)  |
| `SMTP_HOST`     | Send through this mail server instead.                         | (none)  |
| `SMTP_PORT`     | Its port. 465 uses TLS from the start; others upgrade to it.   | `587`   |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | Your login for it.                            | (none)  |
| `SMTP_TLS`      | Set to `if_available` only for a local relay that has no TLS.  | (TLS required) |
| `TAB_MAIL_FROM` | The address Tab's mail comes from. Use one your service lets you send as. | `tab@` your `PHX_HOST` |

## Reading bills

Tab can read photos, PDFs, and forwarded email with Claude. Without these
settings Tab takes them in, and people fill in each bill by hand beside the
original.

- **Reading:** make an API key at [platform.claude.com](https://platform.claude.com)
  and set `ANTHROPIC_API_KEY`. It goes to the `extract` service only. Reading a
  bill costs less than a tenth of a cent; a statement of several pages, about
  two tenths of a cent. Set a monthly spending limit on the key in case.
- **Forwarded email:** Tab receives mail through [Resend](https://resend.com).
  Add a domain just for this, like `bills.example.com` (not the one your own
  email uses), turn on **Receiving** on its page, and add the record Resend
  shows. Then add a webhook for `email.received` pointing at
  `https://<your PHX_HOST>/inbound/resend`, and set the settings below. Tab
  must be reachable from the internet for this part.

| Setting                 | What it's for                                                    | Default |
| ----------------------- | ---------------------------------------------------------------- | ------- |
| `ANTHROPIC_API_KEY`     | Turns bill reading on (on `extract`).                            | (off)   |
| `TAB_INBOUND_DOMAIN`    | The domain forwarding addresses live on, like `bills.example.com`. | (none) |
| `RESEND_WEBHOOK_SECRET` | The webhook's signing secret, from Resend.                       | (none)  |
| `RESEND_API_KEY`        | Also fetches the mail that arrived. Needs full access.           | (none)  |
| `TAB_READS_PER_DAY`     | How many documents one person can send for reading each day.     | `30`    |

## Updating

```sh
git pull
docker compose up -d --build
```

Tab updates its database on the way up, so there's no separate step.
