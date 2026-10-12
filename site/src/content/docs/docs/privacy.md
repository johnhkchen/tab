---
title: How your privacy is kept
description: What stops other people from seeing your data in Tab, and how to check it yourself.
---

Most apps keep your data private by being careful in their own code. Tab also
does that, but it doesn't rely on it. The database itself refuses to hand over
rows you're not allowed to see.

## The short version

- **Your group sees your group's shared bills.** Nobody outside the group can.
- **Your own spending is yours.** Other people in your group can't see it, not
  even whoever set the group up.
- **Nothing is ever deleted behind your back.** Changes are recorded, not erased.
- **The bill reader can't change anything.** It can only suggest an entry. You
  confirm it before it's added.

## How it works

Every time you use Tab, the app asks the database for data *as you*. The database
has a written rule for each kind of data, saying who may read it, add it, and
change it. If a request breaks a rule, the database refuses, even if the app has
a bug. These rules are called row-level security, and they're built into
Postgres.

The account the app uses for your requests has no permission to delete anything
and no way to skip the rules.

## Check it yourself

Tab is open source, so you don't have to take our word for it:

- The rules are in
  [`web/priv/repo/migrations/`](https://github.com/johnhkchen/tab/tree/main/web/priv/repo/migrations).
- The tests that try to break them are in
  [`web/test/tab/rls_test.exs`](https://github.com/johnhkchen/tab/blob/main/web/test/tab/rls_test.exs).
