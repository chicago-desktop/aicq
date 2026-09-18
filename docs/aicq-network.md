# aICQ between computers

**Status:** phase 1 (presence) confirmed by the owner on two nodes, both ways, 2026-09-18; phase 2 (messages) built. Owner's request:
"now that there is a network, aICQ must work between nodes." Designed with
the session that coordinates the cluster work. The owner decided two points:
the automatic **Network** group, and broadcasting who is logged on.

This file is the contract for the work across nodes. Change it here first
if the contract has to change.

## 1. What stays as it is

- **Every node keeps its own database** and its own accounts. Accounts are
  not federated: each node asks its own password and answers for its own
  people, as the Remote Desktop does. This is also ICQ's metaphor: a
  number belongs to its server.
- The windows, the messenger and the presence service keep their jobs on
  their own node. What crosses the network is the presence service's roster
  (phase 1) and the messenger's messages (phase 2).

## 2. Identity of a person on another computer

**Stored as `net:<node>:<user_id>`, shown as `<name> (<node>)`.**
- `<node>` is the cluster name of the node the person logged on to, i.e.
  `system.cluster.members()`'s name. The precondition is
  `relay.node_name == cluster.name`.
- `<user_id>` is that node's own id of the person.

The plain form `user@node` cannot be used. A local `user_id` is sometimes an
e-mail address (measured on the owner's database: `butschster@gmail.com`),
so a string with `@` does not tell a remote person from a local one. The
prefix does, and the node comes before the id, so an id containing `:` or
`@` stays whole. A local id never starts with `net:`: the users module mints
UUIDs or e-mail addresses.

**The node is taken from the sending process, never from a body.** A roster
or a message says which of ITS people it speaks for; the node is the node of
`message:from()`. A node can speak for its own people and cannot forge
another node's. That is the same trust line as "each node asks its own
password", drawn to the end. The cluster's own identity keys
(`trusted_peer_keys`) authenticate the node.

## 3. Presence (phase 1)

**Through pg, in a scope of aICQ's own** (`chicago.aicq:network`, kind
`pg.scope`). The same entry id on every node is one scope, so nothing is
wired in the application.
- Each node's presence service joins the group `aicq.presence`. pg's
  membership says which nodes run aICQ, and pg drops a departed node's
  members when the node leaves.
- Every `ANNOUNCE_S` (10 s) it broadcasts its roster on the topic
  `aicq.roster` to the whole group, itself included: `{p = {{i = user_id,
  m = name}, …}}`. The list holds the people logged on to at least one
  desktop of that node, from the tray's own `desktop.list` answers. Keys are
  strings or a gapless list: integer keys with a hole are lost between nodes.
- Why pg here, when the Remote Desktop refused it: there the need was a
  point-to-point stream, and pg is a fan-out with a breaker. "Who is online"
  is exactly a broadcast to a group.

**Judged per node, in three states** (`network.judge`):

| State | When | Its people |
|---|---|---|
| `fresh` | a roster from the node within `FRESH_S` (35 s: three announcements and a margin) | online if in its roster |
| `unknown` | no fresh roster, but the node is still a member of the cluster and of the group | kept as last heard, shown as unknown |
| `gone` | the node left the cluster's membership or the pg group | offline; they leave the Network group |

**The absence of news alone never means offline.** pg's broadcast skips a
node silently while its circuit breaker is open (measured). A missed roster
therefore makes that node `unknown`, and its people stay where they were.
Only the membership, not a timer, ends a node. Without this the Network
group would blink at every skipped broadcast.

**Without a cluster** there are no other members, and aICQ is "this
computer only". The pg scope works on a lone node too; if it cannot be
opened, the presence service logs why and keeps its tray work: a missing
network never stops the local messenger.

**Privacy (owner, 2026-09-18).** Every node of the cluster learns the names
of everyone logged on to every other node. That is accepted: the cluster is
trusted, because its nodes share the gossip secret and each other's
identity keys, so they are machines of one owner.

### What a person sees

- **Network (N)** (owner's decision): a group of the contact list, filled
  by itself with everyone logged on to another computer and not in the
  person's contacts. Its rows read `<name> (<node>)`.
  - A person in it has the flower when the node is `fresh`, and the grey
    flower with "status unknown" when it is `unknown`.
  - They leave the group when they log off (a fresh roster without them) or
    when their node is `gone`, and at no other time.
  - The group is hidden while empty.
- **Add to Contacts** on a Network row moves the person into People. There
  they stay when offline, as in ICQ, with the name last heard
  (`chicago_aicq_remote`, §4).
- Send Message works on a Network row and on a remote contact (§5).

## 4. Data (migration `chicago.aicq:03_network`)

```
chicago_aicq_remote (id TEXT PRIMARY KEY,   -- net:<node>:<user_id>
                     node TEXT NOT NULL,
                     name TEXT NOT NULL,
                     seen_at TEXT NOT NULL)
```

A remote person's name as last heard in a roster. The window writes it,
under the person's own actor, when it adds that contact and when it reads a
fresher name. The local users directory knows nothing about remote people.

## 5. Messages (phase 2)

**Status:** built 2026-09-18, awaiting the two-node run.

Messages go point to point. Each node's messenger takes
`chicago.aicq.messenger@<node>` in the cluster's EVENTUAL registry (policy
`chicago.aicq:messenger_network`, its own entry). Without a cluster that
name is refused, the messenger says "aICQ messages stay on this computer",
and local messages work as before. A message to `net:<node>:<id>` is offered
to that name on the topic `aicq.deliver`:
`{i = message id, f = the sender's id here, t = the recipient's id there,
b = text, m = the sender's name}`.

**A reply confirms delivery; a successful send does not.** A cross-node
`process.send` answers success even when the transport fails (measured).
A reply alone is still not enough, because without a rule for no reply an
unconfirmed message is only lost more politely. So:
- **Stored first, pending until confirmed.** The sender's row is written as
  every row is. `delivered_at` stays NULL until the other computer answers
  (migration `04_delivery` adds `delivered_at` and `failed`). A message
  between two people of one computer ignores both columns.
- **Offered until answered.** At once on sending, then every `RETRY_S`
  (5 s), and at once when the presence service hears that node again after
  silence or absence (`aicq.node_back`).
- **Stored once there.** The receiving messenger builds `from_id` as
  `net:<node of the sending process>:<f>`; the body never names the node.
  It inserts under the sender's message id with
  `INSERT … ON CONFLICT (id) DO NOTHING` and answers `aicq.delivered {i}`
  either way, so an offer that comes again is stored once and stops. The
  time is the receiving computer's, so its history keeps the order it saw.
  A new row is told there as a local one is: the watching windows, the tray
  and the balloon, with the sender's name as they gave it.
- **Refused for good.** The receiver answers `{i, r = reason}` (no
  recipient, no text, too long, a node that cannot take part). The sender
  marks the row `failed` and stops offering it. A message that could not be
  stored is not answered, so it comes again. A delivery from the node itself
  is refused and not answered, so a computer never loops on itself.
- **Only the addressee confirms.** An acknowledgement is taken only from
  the node the message was addressed to (`network.acked`). node-c cannot
  mark a message to node-b delivered.

**What the window shows.** The SDK's list has no grey for a single line, so
the state is said in words under the text: "(not delivered yet: it will be
when node-b is back)", or "(not delivered: <reason>)".

**The messenger's writes.** The runtime checks only `db.get` on a database:
there is no SQL right narrower than it. The messenger already holds `db.get`
to read a message's ends, so a separate write grant cannot be expressed. The
narrowing is in the code: `people.receive`, `people.delivered` and
`people.failed`, one statement each. This is stated here and in the index
rather than implied by a policy that would grant nothing.

**Someone of the same name in two places.** "Butschster" in People and
"Butschster (node-b)" in Network are two accounts on two computers. Nothing
merges them by name, because an equal name is not the same person. The node
in the label is what tells them apart.
