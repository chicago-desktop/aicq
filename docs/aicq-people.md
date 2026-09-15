# aICQ: people as contacts

**Status:** proposed, 2026-09-15. Owner's request: "aICQ has agents; add
ordinary users to it." With the `terminal.ssh` host every SSH connection
gets its own Chicago desktop under the person who logged on, so several
people can be on the stand at once. aICQ becomes what ICQ was: a list of
people, who is online, messages between them — with the agents staying in
the same list.

This file is the contract between the two halves of the work (data layer
and service; the windows). Change it here first if the contract has to
change.

## 1. What a person sees

- **People and agents are separate** (owner, 2026-09-15: "users must be
  separated from agents"). The contact list has two top-level groups,
  **People** and **Agents**, each collapsible, each headed with ICQ 2000's
  counter `People (2/7)` — online / total. Inside a group online rows come
  first, then offline, then by name; the status is the picture, not a
  sub-group. People carry the ICQ flower (`chicago.aicq:images/aicq` online,
  `aicq_off` offline); agents carry `chicago.aicq:images/agent` (online) and
  `agent_off` (grey). The old Online/Offline groups of agents go away. The
  two groups never mix: an agent is never shown under People, a person never
  under Agents, and each group has its own "Add…" (Add Contact… under
  People, Add Agent… under Agents).
- A person with unread messages shows `Anna (2)` and the picture
  `chicago.aicq:images/message` (an envelope) instead of the flower until the
  messages are read.
- **Add Contact…** (a button next to Add Agent…, and in the field's context
  menu): a dialog with one search field — an e-mail, a name (three letters
  or more) or a UIN — a results table (Name, UIN) and Add. ICQ called it
  "Add/Invite Users".
- Right click on a person: **Send Message**, ―, **Info…** (name, UIN,
  online or not, on how many desktops), **Remove Contact**.
- Double click on a person opens the **message window** `chicago.aicq:message`:
  titled `<name> - aICQ`, the history above (sender, time, text), an input
  below, **Send** (default; Ctrl+Enter), **Close**. Opening it marks that
  person's messages read. Messages arriving while it is open appear in it.
- Messages to an offline person are kept and shown when they open aICQ
  (ICQ's offline messages).
- **Not in List** (owner, 2026-09-15: "the person who wrote me vanished once
  I opened the message; there must be a way to add them"). Someone who wrote
  to you and is not your contact goes to a third top-level group, **Not in
  List (N)**, shown between People and Agents only when it is not empty —
  ICQ 99's own group. They stay there after their messages are read, newest
  conversation first, until you add or dismiss them. Their context menu:
  **Add to Contacts**, Send Message, Info…, ―, **Remove from List**
  (dismiss; a new message from them brings them back). The message window
  shows **Add to List** next to Send while its peer is not a contact; after
  adding it disappears and the person moves to People.
- The tray flower of each desktop becomes the envelope with `aICQ (N)` and
  the title `N new message(s)` while its person has unread messages; a click
  opens the contact list. No window pops up on its own over someone's work.
  Without unread messages the tray title keeps the two kinds apart too:
  `2 people online, 4 agents`.

## 2. Identity

**The sender and the reader are the actor of the process, never a field of
a message.** Every desktop spawns its windows under the person who logged
on, so in a window `security.actor()` is that person. Rows are written and
read by the window's own process (its policy `chicago.aicq:window_db` gives
`db.get` on the database the application names, `target_db`),
with `from_id` / the reader's id taken from the actor. A message body field
that names a user is ignored. The first task of the data half is to measure
that `security.actor():id()` in a desktop window equals the users table's
id of the person who logged on, and to write the result here.

**Measured 2026-09-15: it does.** The chain, each step read in code:
`app.desktop:logon` → `kickside.users:session.mint(user)` →
`security.new_actor(tostring(user.user_id), …)` → the token store keeps that
actor → the shell's `chicago.shell.logon:provider.redeem` gets it back
with `store:validate(token)` → the compositor spawns every window
`:with_actor(IDENTITY.actor)` (`chicago.tui_desktop.desktop:library`,
`spawner`). On the stand's database the token store's own payload says the
same: all 19 tokens minted by desktop logons (`meta.source = tui_desktop`)
and all 6 web ones carry an `actor_id` that is a row of `app_users.user_id`
(0 without a row). `desktop.list`'s `user.id` is the logon answer's
`user_id`, the same `tostring(user.user_id)`.

## 3. Data

Migrations `chicago.aicq:01_people` and `02_dismissed`, in the database the
application names (`target_db`). Where an application kept aICQ's rows in the
stand's tables `app_chat_contacts`, `app_chat_messages` and
`app_chat_dismissed`, they are copied over once (`chicago.aicq:legacy`); a
row already in the new table wins:

```
chicago_aicq_contacts  (owner_id TEXT, contact_id TEXT, created_at TEXT,
                    PRIMARY KEY (owner_id, contact_id))
chicago_aicq_messages  (id TEXT PRIMARY KEY, from_id TEXT, to_id TEXT,
                    body TEXT, created_at TEXT, read_at TEXT NULL)
                    index on (to_id, read_at), on (from_id, to_id, created_at)
chicago_aicq_dismissed (owner_id TEXT, other_id TEXT, dismissed_at TEXT,
                    PRIMARY KEY (owner_id, other_id))      -- migration 02
```

Contacts are one-way, as in ICQ without authorization: adding someone does
not ask them. Sending does not require being in each other's list.

## 4. The library `chicago.aicq:people`

Runs in the calling window's process, under the caller's actor. Every
function answers `value, nil` or `nil, reason` (a denial is named, not
turned into an empty list).

| Function | Answer |
|---|---|
| `me()` | `{id, name, uin}` of the caller |
| `contacts()` | the caller's contacts `{{id, name, uin, online, desktops, unread, listed, last_at}}`, by name, plus **everyone who has written to the caller and is not a contact** (`listed = false`, the Not in List group) unless dismissed after their last message — read or unread, newest conversation first. `last_at` is the pair's newest message either way (nil without messages); only a message FROM them undoes a dismissal; a person with unread messages is shown even when dismissed (the tray's envelope must point at a row). When presence could not be read, `online`/`desktops` are `nil` and the list's field `why` says why |
| `find(query)` | at most 20 `{id, name, uin}` by name: exact e-mail (the query has `@`), UIN (9 digits), else a name prefix ≥ 3 letters matched against the full name only; the caller is left out; never e-mail addresses in the answer |
| `add(user_id)`, `remove(user_id)` | `true`; `add` refuses the caller and an account the directory does not know |
| `dismiss(user_id)` | `true`; takes a Not in List person off the list until they write again (a row in `chicago_aicq_dismissed (owner_id, other_id, dismissed_at)`, migration 02); `add` clears it. Refuses the caller and an account the directory does not know |
| `send(to_id, text)` | the message id; stores the row, then tells the messenger. Refuses an empty text, one over 4000 characters, the caller, an unknown account. A third value names a messenger that was not reached — the row is stored all the same |
| `history(user_id, limit)` | `{{id, from_id, to_id, body, at, read}}`, oldest first, the last `limit` (default 200, 1…1000) of the pair |
| `mark_read(user_id)` | how many were marked; then `aicq.read` to the messenger, so the tray drops the envelope at once |
| `unread()` | `{[from_id] = count}` for the caller |
| `online()` | `{[user_id] = desktops}` from the presence service (§5), or `nil, reason` |
| `uin(user_id)` | a stable 9-digit number derived from the id, display only |

`name` is `people.display_name`: the full name, else the e-mail, else the id —
the rule the stand's logon names the person by, copied into the module. Presence: a person is online while at
least one running desktop (`window_api.desktops` over the shell's family of
names) reports them in `desktop.list` as `user.id`; `desktops` is how many.
The presence service is the one that asks the desktops; the library asks
the service (`aicq.who`, answered on the topic `aicq.online`, 2 s), because a
window's `desktop.reply` subscription belongs to its `window_api`.

Reading other people's names and e-mails needs the users table. If the
users module has a lookup a signed-in user may call, `find` uses it with
its gate (`security.can("access", …)`: a window goes past the router, so it
checks the handler's gate itself). If it has none, `find` goes through a function
entry `chicago.aicq:directory` with its own actor (a callee runs under its own
declared actor — measured 2026-09-14) that answers only the three query
shapes above and returns only `{id, name, uin}`.

**Chosen 2026-09-15: the users module's lookup; `chicago.aicq:directory` is
not written.** It is the contract `kickside.contract:directory` (`search`,
`resolve`, `exists`), the one the sharing picker uses. A signed-in user may
call it: `contract.*` on `kickside.*` comes with the application's user group
(on the stand `app.security:user`)
(`user.runtime_contracts`), and `access` on `kickside.users.directory:*`
with the users module's `user_security_scope`
(`directory_endpoint_access`) — so the gate is
`security.can("access", "kickside.users.directory:directory_search")`
(`…:directory_resolve`, `…:directory_exists` for the other two). Its search
is free text over name, e-mail and id, up to 100; the library narrows it to
the three shapes and drops the e-mail. A UIN cannot be searched for, so it
is looked for among the directory's first 100 accounts, and when that list
is full and holds no match the answer is a refusal that says so, not an
empty list. Names are `display_name` over `{user_id, email, full_name}` read
back from the directory's label and sublabel: an account without a full
name is shown by its e-mail, as the stand shows it elsewhere and as the
directory itself answers any signed-in user — which is also why a name
query never matches an e-mail.

**The directory reads only the 50 newest accounts** (found 2026-09-15): its
adapter lists them with `user_repo.list()` and no options, and that defaults
to `limit 50, ORDER BY created_at DESC`. An older account is found by no
query and its name does not resolve (a contact shows its id); the sharing
picker has the same blind spot. It is the users module's to fix and is
reported, not worked around. What the library does about it is say so: a
UIN not found while the directory's list is full, and an e-mail not found
that `exists` (which looks the account up directly) knows, both answer a
refusal naming the 50, not an empty list. A name not found cannot be told
apart from nobody.

**The tray items are `chicago.aicq:aicq`'s** — one builder each: the envelope
`aicq.mail(unread, base)`, the flower `aicq.pick(agents, why, report, now,
people)`, where `people` is how many people besides that desktop's own person
are online (the title `2 people online, 4 agents`). The presence service
only decides which one a desktop gets.

## 5. The messenger service `chicago.aicq:messenger`

A `process.service` with `auto_start`, registered as `chicago.aicq.messenger`,
its own actor. It stores nothing; the rows are already written.

- `aicq.sent {message_id, to_id}` — from a sender's window after the insert.
  The messenger pings every window that watches `to_id` with
  `aicq.new {from_id, message_id}` and asks the presence service to refresh
  the recipient's tray at once.
  *As built:* the messenger reads `from_id` and `to_id` from the stored row
  by `message_id` (its actor has `db.get` on aICQ's database) and ignores the body's
  `to_id`, so a forged `aicq.sent` can at most ping about a real row. It
  pings the watchers of both ends with `aicq.new {from_id, to_id,
  message_id}` — the sender's other desktops show the message too — and
  sends `aicq.refresh {user_id = to_id}` to the presence service.
- `aicq.read {user_id}` — from a window after `mark_read`; the messenger asks
  the presence service to refresh that person's tray. A forged one only
  refreshes a tray.
- `aicq.watch {user_id}` / `aicq.unwatch` — a contact list or a message
  window says whose messages it shows. A forged watch only yields pings
  ("reload"); the content is read by the window under its own actor.
  A window watches its own person (the reader), not the peer: the pings a
  person needs are the ones about messages to them. The messenger monitors
  a watching process and drops its watches when it exits; `aicq.unwatch`
  without `user_id` drops all of the sender's.
- The presence service (`chicago.aicq:presence`) pushes the tray **per
  desktop**: for each running desktop it reads `user.id` from
  `desktop.list`, counts that person's unread messages, and pushes the
  flower or the envelope with `aICQ (N)`. A desktop without a logged-on
  person keeps today's agent count.
  *As built:* every tick it sends `desktop.list` to each running desktop and
  takes the answers as they come (the loop does not wait), pushing that
  desktop's item on each; `aicq.refresh` pushes the desktops of that person
  at once. It also answers `aicq.who` with `aicq.online {online = {[user_id]
  = desktops}}` from the answers of the last two ticks.

## 6. Tests and evidence

The module's harness (`test/`, platform stand-ins in `test/stubs/`; README
"Development"). The data half: the library against a real SQLite
(contacts, send, history order and limit, unread, mark_read, find's three
shapes and the 20 cap, UIN stability), identity taken from the actor (a
body `from_id` ignored), the messenger's pings, the per-desktop tray item
for 0 and 3 unread. The windows half: the contact list rows for people and
agents with unread markers, Add Contact's search and add, the context menu,
the message window's update (send, incoming ping reloads, mark read on
open), layouts without overlaps, a shot `aicq-people.png` (two people online,
one with 2 unread, an agent) and `aicq-message.png`. Mutation per test.
Live check by the owner: two SSH desktops as two people, a message from one
appears in the other's tray and window.
