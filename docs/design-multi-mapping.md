# Design: several chat mappings in one bluehop (0.5.0)

Status: accepted, implemented in 0.5.0. The Korean spec (`SPEC.md`) is updated to match.

## 1. Goal

Up to 0.4.x bluehop linked exactly one iMessage 1:1 chat to one Telegram chat. 0.5.0 runs **several independent 1:1 links ("mappings") in one process**. Each mapping has its own Telegram bot token, so every linked conversation shows up as its own bot chat in Telegram. Adding and inspecting mappings is done from the CLI, interactively for people and with flags plus `--json` for agents.

Non-goals (unchanged): group chats, one bot serving several iMessage chats, hosted service, SIP-disabled features.

## 2. Configuration model

`~/Library/Application Support/bluehop/config.json` (0600 in a 0700 folder):

```json
{
  "version": 2,
  "mappings": [
    {
      "id": "family",
      "enabled": true,
      "telegram": {
        "chatId": 123456789, "allowedUserId": 123456789,
        "botId": 111111, "botUsername": "family_relay_bot",
        "tokenSource": "keychain", "tokenAccount": "bot-token:family", "tokenFile": null
      },
      "imessage": { "chatGuid": "any;-;+15555550123", "handle": "+15555550123" },
      "relay": { "mirrorOwnMessages": true, "telegramReactionMode": "ignore", "outboxDirectory": null }
    }
  ]
}
```

- `id`: short slug, `^[a-z][a-z0-9-]{0,31}$` (starts with a letter so it never looks like the numeric staging folders of 0.4.x). Used in the Keychain account, the state DB, log prefixes and CLI arguments.
- `enabled`: `false` means paused. A paused mapping runs no worker at all (no Telegram polling, no iMessage reading).
- `telegram.botId` / `botUsername`: recorded from `getMe` when the mapping is added. The bot id is the number before `:` in the token; it is not secret and lets the CLI enforce "one token per mapping" without reading every token from the Keychain.
- `telegram.tokenAccount`: Keychain account under service `dev.kanziw.bluehop`. New mappings use `bot-token:<id>`. `tokenSource: "file"` with `tokenFile` stays supported per mapping.
- `relay`: per-mapping options, same keys as before.

### 2-1. Backward compatibility and migration

- A 0.4.x config (top-level `telegram` / `imessage` / `relay`, no `version`) is read as **one mapping with id `default`** whose token is the old Keychain account `telegram-bot-token`. No manual edit, no Keychain move.
- The first CLI command that writes the mapping list (`mapping add/remove/pause/resume`) rewrites the file as version 2. Before writing it copies the old file to `config.json.v1-backup` (0600) once. The migrated `default` mapping keeps `tokenAccount: "telegram-bot-token"`.
- `run`, `doctor`, `status` and `mapping list` never write the config.
- Writes are atomic: write a 0600 temp file in the same folder, then `rename`.

### 2-2. Guard rails (validated on every load and before every write)

| Rule | Why |
|---|---|
| ids unique and slug-shaped | Keychain account, state rows and CLI arguments are keyed by id |
| an iMessage chat (same `chatGuid`, or same normalized `handle`) appears in at most one mapping | two workers would both relay the same conversation, and outgoing echoes could be matched by the wrong worker |
| a bot token is used by at most one mapping (same `botId`, same Keychain account, or same token file) | Telegram `getUpdates` has one consumer per token; two pollers steal each other's updates and get `409 Conflict` |
| (bot, Telegram chat id) pair unique | implied by the rule above; checked anyway so that a hand-edited file fails loudly |

At runtime the supervisor also compares the bot id of each loaded token (defense in depth for hand edits and legacy mappings without `botId`): a mapping whose token belongs to a bot already used by an earlier mapping is not started and reports the conflict in `status`.

## 3. Runtime

One process (`bluehop run`, LaunchAgent `dev.kanziw.bluehop`), one **worker per enabled mapping**.

```
 Supervisor ── watches config.json (mtime, every 5 s) ── reconcile: start / stop workers
   ├─ Worker "family" ── Relay (own TelegramClient, StateStore view, rate limiters, breakers, chat.db connection)
   ├─ Worker "work"   ── Relay (...)
   └─ ChatActivity (shared, one read-only chat.db connection):
         one grouped query per second: SELECT chat_id, MAX(message_id) FROM chat_message_join
         WHERE chat_id IN (<mapped chat rowids>) GROUP BY chat_id
```

- **Workers run concurrently** (one Swift task each). A worker's loop is the 0.4 loop (`getUpdates` long-poll → new iMessage rows → settle sends) for its mapping only.
- **Shared iMessage polling:** the shared `ChatActivity` reads the latest message ROWID of every mapped chat with one query (at most once per second, whoever asks first refreshes for everyone). A worker reads message rows only when its chat has rows past its cursor, or when it is waiting for something (attachment download, echo grace). Every query stays scoped to configured chat ROWIDs.
- **Isolation:** each worker owns its rate limiters, safety breakers, halt state, cursors, Telegram offset, echo-pending outbox and staging folder (`<outbox>/<id>/`). A worker never touches another mapping's rows.
- **Failure containment:** a worker that cannot start (token missing, chat not found, Keychain denied) records the error and retries with backoff (5 s doubling to 5 min). `getUpdates` failures back off per worker (3 s doubling to 60 s), so a revoked token or a `409 Conflict` slows only that worker. A safety halt stops only that mapping. The process exits only if the config cannot be read at start; a bad config edit while running is logged and the old mappings keep running.
- **Hot reload:** pause/resume/add/remove take effect within about 5 s without restarting the LaunchAgent. A changed mapping is stopped and started again with its new settings. Cancellation happens at await points only, so a send that has begun completes and is recorded in the outbox before the worker stops; the outbox idempotency rule (never send the same Telegram message twice) still holds across restarts.
- Known limit: AppleScript sends and media conversion are blocking calls on the worker's thread. With many mappings sending at once, one worker can delay another for up to the call's timeout (30 s for a send). Recommended up to about 8 mappings.

## 4. State DB

`state.sqlite` (0600) stays one file. Schema version 2 (`PRAGMA user_version = 2`) adds `mapping_id TEXT NOT NULL` to every table and to every primary key:

| Table | Key |
|---|---|
| `kv` | `(mapping_id, k)`: `imsg_cursor`, `tg_offset`, `halted`, health keys |
| `mapping` (message id map) | `(mapping_id, imsg_guid, part)` |
| `outbox` | `(mapping_id, tg_message_id, part)` (different bots reuse message ids) |
| `pending_attachment` | `(mapping_id, rowid)` |
| `reaction_state` | `(mapping_id, target_tg)` |

`StateStore(path:, mappingID:)` is a view: every query filters on its mapping id, so echo matching, idempotency and cursors are per mapping by construction.

Migration from version 0/1 (0.4.x): inside one `BEGIN IMMEDIATE` transaction, rebuild each table with the new key and copy existing rows with `mapping_id = 'default'`. Before migrating, `VACUUM INTO 'state.sqlite.v1-backup'` makes a consistent copy. A second process opening the file during the migration waits on the lock and then sees version 2.

Health keys written by each worker (no message content): `health.state` (`starting`, `running`, `backoff`), `health.last_tg_ok` (unix time of the last successful `getUpdates`, written at most every 10 s), `health.last_imsg_scan`, `health.last_error`, `health.last_error_at`. `bluehop status` reads them; it never opens chat.db or the network.

## 5. CLI

Every command accepts `--help`, and every command that reads the config accepts `--config PATH` (default `~/Library/Application Support/bluehop/config.json`; the state DB lives next to it). Unknown flags and extra arguments are errors (exit 2). `--json` prints one JSON object on stdout; human text goes to stdout, errors to stderr. With `--json`, errors are also printed as `{"ok": false, "error": {"kind", "message"}}`.

| Command | Purpose |
|---|---|
| `bluehop run` | run every enabled mapping (LaunchAgent) |
| `bluehop chats [--json] [--search TEXT] [--limit N]` | local iMessage 1:1 chats: guid, handle, service, last activity, which mapping uses it. No message content |
| `bluehop mapping list [--json]` | configured mappings (no tokens) |
| `bluehop mapping add [--id ID] [--chat GUID\|HANDLE] [--token-stdin \| --token-file PATH] [--telegram-chat ID] [--allowed-user ID] [--wait SEC] [--dry-run] [--json]` | add a mapping (see 5-1) |
| `bluehop mapping remove ID [--keep-token] [--purge-state] [--json]` | delete the mapping and its Keychain item (unless `--keep-token`); `--purge-state` also deletes its state rows |
| `bluehop mapping pause ID` / `resume ID` | set `enabled` |
| `bluehop mapping test ID [--messages] [--json]` | doctor for one mapping including `getMe`; never sends |
| `bluehop doctor [--mapping ID] [--messages] [--telegram] [--json]` | checks for all or one mapping |
| `bluehop status [--json]` | per-mapping health from the state DB, and whether the LaunchAgent runs |
| `bluehop telegram-ids [--mapping ID \| --token-stdin \| --token-file PATH]` | ids of recent senders to a bot |
| `bluehop resume [--mapping ID] [--skip-backlog]` | clear a safety halt |
| diagnostics (`selfcheck-attributed`, `diag-echo`, `diag-send-file`, `diag-audio`) | take `--mapping ID` (required when more than one mapping exists) |
| `bluehop list-chats` | kept as an alias of `bluehop chats` |

Exit codes: `0` ok, `1` failure (a check failed, network, Keychain), `2` usage error, `3` conflict (guard rail, id exists), `4` not found (mapping id, chat), `5` timed out (waiting for a Telegram message), `130` cancelled by the user.

### 5-1. `mapping add`

Interactive mode only when stdin is a terminal and a value is missing; otherwise every missing value is an error, never a prompt.

1. **Token**: `--token-stdin` reads one line from stdin; `--token-file PATH` keeps the token in a 0600 file instead of the Keychain; otherwise (terminal) a hidden prompt with echo off. Tokens are never accepted on the command line and never printed.
2. **Validate**: token shape, then `getMe` → bot id and username. Refuse if another mapping uses the same bot (exit 3).
3. **Chat**: `--chat` accepts a guid or a handle (the most recently active 1:1 chat with that handle). Otherwise an arrow-key picker over local 1:1 chats (type to filter, Enter to pick, Esc to cancel). Chats already mapped are shown but cannot be picked. If the terminal cannot do raw mode the picker falls back to a numbered list.
4. **Telegram ids**: `--telegram-chat` and `--allowed-user`, or detection: the CLI asks the person to send any message to the bot and waits (`--wait`, default 120 s) for a private message no older than 10 minutes. In a terminal the detected sender is shown for confirmation. Several different senders → conflict, use the flags.
5. **Id**: `--id`, or a prompt with a default derived from the bot username, or (non-interactive) the derived default.
6. **Write**: Keychain item `dev.kanziw.bluehop` / `bot-token:<id>` through `security -i` with the token on stdin (not argv), trusting the installed binary and the running binary (`-T`); then the config (migrating a v1 file first). If the config write fails the new Keychain item is removed.
7. **Doctor** for the new mapping. A running service picks the mapping up within about 5 s.

`--dry-run` stops after step 5 and prints what would be written.

### 5-2. Full Disk Access from a terminal

macOS attributes a command run from Terminal to Terminal, so `chats` and the picker cannot open chat.db unless the terminal app has Full Disk Access (which this project does not recommend). When opening chat.db fails, the CLI re-runs the read-only part (`chats --json`, `doctor --json`) through a one-shot launchd job of the installed binary, which has its own permission (the same mechanism as `scripts/agent-run.sh`). The one-shot child sets `BLUEHOP_ONESHOT=1` so it never recurses.

## 6. Agent skill

`skills/bluehop/SKILL.md` in the repository: when to use, install, add a mapping non-interactively, inspect, troubleshoot, safety rules. Linked from README, AGENT-GUIDE and llms.txt.

## 7. Tests

| Area | Test |
|---|---|
| config v1 read as `default`, v2 round trip, migration writes backup once | `MultiMappingConfigTests` |
| guard rails: duplicate id, chat, handle, bot, token account | `MultiMappingConfigTests` |
| state DB v1 → v2 migration keeps rows under `default`, backup made | `StateMigrationTests` |
| state views isolated (cursor, offset, halt, outbox with the same message id) | `StateMigrationTests` |
| echo matching per mapping (two bots send the same text) | `MultiMappingRelayTests` |
| one failing worker (401 on `getUpdates`, chat not found at start) does not stop another | `MultiMappingRelayTests` |
| shared chat activity: no row query when nothing new | `MultiMappingRelayTests` |
| supervisor reconcile (start, stop, restart on change, duplicate bot at runtime) | `SupervisorTests` |
| argument parsing: unknown flag, missing value, `--flag=value`, help | `CLIParsingTests` |
| `--json` shapes for `mapping list`, `chats`, `status`, errors | `CLIParsingTests`, `CLIBinaryTests` |
| chat picker state machine and key decoding (no terminal IO) | `ChatPickerTests` |
| Telegram id detection (age window, several senders, bots ignored) | `MappingAddTests` |
| `mapping add` flow with fake token store and mock Telegram | `MappingAddTests` |
| built binary: `--help` on every command, unknown flag exit 2, mapping list/pause/resume on a temp config | `CLIBinaryTests` |

Not covered by automated tests: real Keychain writes, the real terminal raw mode, launchd one-shot fallback, and several real bots polling Telegram at once.
