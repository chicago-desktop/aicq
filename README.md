# chicago/aicq

aICQ for the Chicago desktop (`chicago/shell`), in the manner of ICQ:

- one **contact list** with two groups that never mix — **People** and
  **Agents**, each headed `People (2/7)` (online / total), online first, the
  status by picture, and **Not in List** for someone who wrote to you;
- a **message window** between people — history above, the input below,
  Send with Ctrl+Enter; messages to someone offline wait for them;
- **Add Contact…** — find a person by e-mail, UIN or a name prefix;
- the **dialog with an agent** — a stock chat session under your own actor,
  and **Add Agent…**;
- the **tray item** next to the clock on every running desktop: the envelope
  `aICQ (N)` while you have unread messages, otherwise the flower with the
  people and agents online.

The contract — who is who, the tables, presence, delivery — is
[docs/aicq-people.md](docs/aicq-people.md).

## Parts

Namespace `chicago.aicq`.

| Entry | What |
|---|---|
| `contacts` | The contact list, in Programs. |
| `message`, `add_contact` | The message window and Add Contact, opened from the list. |
| `dialog`, `new_agent` + `agents` | The agent dialog on the stock session, and Add Agent with the libraries of the web page "Agents". |
| `aicq` | The pure model the windows and the presence service share: groups, rows, menus, Info sheets, tray items. |
| `people` | People's data under the caller's actor: contacts, messages, unread counts, find through the users directory behind its gate. |
| `messenger` + `messenger.service` | Pings the windows watching either end of a stored message; stores nothing. Registered as `chicago.aicq.messenger`, actor `chicago.aicq.messenger`. |
| `presence` + `presence.service` | Asks every desktop who is logged on and puts the item in each tray; answers `aicq.who`. Registered as `chicago.aicq.presence`, actor `chicago.aicq.presence`. |
| `01_people`, `02_dismissed` + `legacy` | The tables `chicago_aicq_contacts`, `chicago_aicq_messages`, `chicago_aicq_dismissed`, and the one-time move of an application's `app_chat_*` rows. |
| `images` | The image pack under `assets/images` (32 and 16 px), called `chicago.aicq:images/<name>`; drawn by `tools/chat_icons.py`. |

The tray item's key is `chicago.aicq`; an item not refreshed for 180 s is
removed by the compositor.

## What the application provides

| Requirement | Default | What |
|---|---|---|
| `chicago.aicq:target_db` | `app:db` | The database of aICQ's tables. The people library reads it back from the migration entry; the windows and both services get `db.get` on it. |
| `chicago.aicq:process_host` | `app:processes` | The host the presence service and the messenger run on. |

```yaml
- name: chicago-aicq
  kind: ns.dependency
  component: chicago/aicq
  version: "*"
  parameters:
    - name: chicago.aicq:target_db
      value: app:db
    - name: chicago.aicq:process_host
      value: app:processes
```

aICQ needs the platform, and declares it as dependencies at the versions it
was built against; the application binds their requirements as usual:

| Module | From | What aICQ uses |
|---|---|---|
| `kickside/agents` | 0.1.41 | the roster of reachable agents, creating a person's agent, the agent reference |
| `kickside/models` | 0.1.49 | the model catalog Add Agent offers |
| `kickside/users` | 0.1.41 | the users directory behind `kickside.contract:directory` |
| `kickside/component` | 0.1.36 | an agent's context for its Info sheet |
| `wippy/session` | 0.4.3 | the stock chat session the agent dialog raises |

A window runs under the logged-on person's actor ("Log On to Windows"): what
it needs of the platform — a session, the agent registry, the contracts —
comes with that person's group. The windows' own policies are for talking to
processes and for aICQ's database. Under the shell's service actor (a shell
without logon) a window says the refusal in words.

### Moving from the stand's `src/app/chat`

Before this module aICQ lived in an application's `src/app/chat` (namespace
`app.chat`, tables `app_chat_*`). The migrations copy those rows into the new
tables when the old tables exist, so contact lists, history and dismissals
survive the switch; a row already in the new table wins. The entry ids moved
to the new namespace (`app.chat:contacts` → `chicago.aicq:contacts`), and so
did the service names (`app.chat.presence` → `chicago.aicq.presence`, the
same for the messenger) and the tray key (`app.chat` → `chicago.aicq`).
The message topics (`aicq.*`) kept their names.

## Development

```bash
make lint    # late locals, then `wippy lint` with the runtime fork's build
make test    # the harness in test/ boots the module with the shell, the base and the platform stand-ins
make icons   # redraw assets/images/{32,16}/*.png
```

**A build of the runtime fork from its releases is required**
([chicago-desktop/runtime](https://github.com/chicago-desktop/runtime),
`v0.3.40a-chicago.2` or newer): it resolves the shell and the base from
GitHub by tag, and the shell declares entries with the `gfx` module, which
the release runtime does not have. The Makefile uses
`~/repos/wippy/runtime/dist/wippy-linux-amd64`; override it with `WIPPY=…`.

`chicago/shell` and `chicago/tui-desktop` are resolved from their GitHub
repositories by tag (`component: github.com/chicago-desktop/shell`,
`version: ">=0.2.0"` in `src/_index.yaml`, the shell also in the harness;
v0.2.0 is the first tag). No working copy of either is needed beside the
module: `wippy update` here and in `test/` writes them into the two
`wippy.lock` files, the first time by cloning them into `~/.wippy/git`. The
platform (kickside/*, wippy/session) stays the Hub's.

`make lint` checks the module against the real platform modules at the versions
in `wippy.lock`. `make test` does not boot the platform: `test/stubs/` stands
in for each module with only the libraries aICQ imports — two reachable agents,
an empty model catalog, a users directory over a table the suites fill (written
to the behaviour of kickside/users 0.1.41: the 50 newest accounts), and a
session and component that refuse. Their lock entries keep the real versions
without a hash, so the module's lower bounds hold.

The suites live in `test/src`, not in `src`: `exclude_meta: type: [test]`
drops test entries from a module loaded as a dependency, and the harness loads
it as one.

## License

MIT.
