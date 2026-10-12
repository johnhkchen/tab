# Tab

Keeps the running tab for your house, so nobody has to.

Tab tracks who paid for what and who owes whom, for housemates, families, and
friends who share costs. It doesn't move money; it keeps the record straight.
Your shared bills are visible to your group. Your own spending stays yours, and
the database itself enforces that, not just the screens.

> **Version 0.1.0 is the foundation.** It runs, but there's nothing to log
> expenses with yet. See [CHANGELOG.md](CHANGELOG.md) for what's in each version.

## Run it on your own machine

You need Docker. Then:

```sh
git clone https://github.com/johnhkchen/tab.git
cd tab
docker compose up
```

Open <http://localhost:4000>. That's it: the database is set up and kept up to date
on every start, and your data lives in a Docker volume called `tab-db`.

To check everything is running: <http://localhost:4000/healthz>.

## Work on it

You need [mise](https://mise.jdx.dev) and Docker.

```sh
mise install       # Erlang, Elixir, and BAML, at the pinned versions
mise run setup     # start Postgres, fetch dependencies, create the database
mise run dev       # web app on :4000, extraction service on :4100
mise run site:dev  # the public website, with live reload
mise run check     # everything CI checks; green here means green there
```

`mise tasks` lists the rest.

## What's in the box

| Folder     | What it is                                                                    |
| ---------- | ----------------------------------------------------------------------------- |
| `web/`     | The app people use. Elixir + Phoenix, on Postgres with row-level security.    |
| `extract/` | Reads bills and receipts and suggests entries. Written in BAML. It can't touch the database, so a sneaky receipt can only ever suggest, never write. |
| `site/`    | The public website: landing page, pricing, and docs. Astro + Starlight, on Cloudflare Workers. |
| `scripts/` | Version check and release tagging.                                            |

## Privacy, checked by the database

Every person-facing query runs as a Postgres role that can't bypass row-level
security and can't delete anything. You can read the rules yourself in
`web/priv/repo/migrations/` and the tests that prove them in `web/test/tab/rls_test.exs`.

## License

[AGPL-3.0](LICENSE). Run it, read it, change it. If you offer a changed version to
other people over a network, share your changes too.
