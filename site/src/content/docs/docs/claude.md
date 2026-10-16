---
title: Use Tab from Claude
description: Connect Claude to Tab, then ask it what you owe or tell it what you spent.
---

Version 0.5.0 lets Claude use Tab as you. Ask "what does Marcus owe me for
utilities?" or say "add $43 of groceries, split evenly," and Claude does it in
Tab. Claude runs on your own Claude plan, so Tab charges nothing for it.

## Connect Claude Code

Your **You** page in Tab shows the command for your copy of Tab. It looks like
this:

```sh
claude mcp add --transport http tab https://your-tab.example/mcp
```

Run it, then type `/mcp` in Claude Code and pick **tab**. Your browser opens
Tab, where you choose what Claude may do and press **Connect**.

## Connect Claude Desktop or claude.ai

In Claude's settings, open **Connectors** and add a custom connector with the
address from your You page (it ends in `/mcp`). Claude sends you to Tab to
sign in and connect.

## What Claude can do

- **Look:** your groups, balances, recent expenses, the fewest payments to
  settle up, and your bills to check.
- **Add:** expenses, split any way Tab can split them, and payments. Claude
  can add only if you leave **Let it add expenses and record payments** ticked
  when you connect.

Claude can't edit or delete anything, confirm a payment, or save a bill to
check. Those stay on the web, where you see the whole picture.

Everything Claude adds says **from Claude**, and your housemates get the same
emails as when you add it yourself. A payment to a housemate still waits for
them to confirm it.

## What Claude sees

The same things you see in Tab, and nothing more. The database checks each
request against your own account, as it does for the web pages. Claude never
sees anyone's private spending or a group you're not in.

## Disconnect

Your **You** page lists each connection and when it last did anything.
**Disconnect** stops it at once.

## If you run your own Tab

Claude Code connects from your own computer, so a Tab on your home network or
on Tailscale works. Claude Desktop and claude.ai connect from Anthropic's
servers, so they need your Tab on a public https address. To turn all of this
off, set `TAB_MCP=off`.
