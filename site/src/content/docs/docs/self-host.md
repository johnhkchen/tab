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
| `PHX_HOST`          | The address people type to reach Tab.                             | `localhost` |
| `POSTGRES_PASSWORD` | The database password. Set it before the first start.             | `postgres`  |
| `SECRET_KEY_BASE`   | Signs logins. Leave it out and Tab makes one on first start.      | (made for you) |

## Updating

```sh
git pull
docker compose up -d --build
```

Tab updates its database on the way up, so there's no separate step.
