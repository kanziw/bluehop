# bluehop: rules for agents and contributors

bluehop is a single Swift binary (`bluehop`, see Identifiers) that links iMessage 1:1 chats to Telegram bot chats, one bot per chat ("mappings", run side by side in one process). Multi-mapping design: `docs/design-multi-mapping.md`. Skill file for agents operating an install: `skills/bluehop/SKILL.md`. Sources of truth: requirements, data flow and security in `SPEC.md`; iMessage-side limits in `docs/imessage-limits.md`; observed chat.db row shapes and the tests that pin them in `docs/observed-facts.md`. Setup and operation for agents: `docs/AGENT-GUIDE.md`.

## Hard rules
- **Zero external packages.** Do not add `dependencies:` / `.package(` to `Package.swift`. If you think one is needed, stop and report to the operator instead (security review comes first).
- **No open ports, no web server.** The only outbound host is `https://api.telegram.org`. Do not make the base URL configurable from the config file (tests inject it through the initializer only).
- **Open chat.db with `SQLITE_OPEN_READONLY` only.** Write nothing under `~/Library/Messages`.
- Every chat.db message query is scoped to configured chat ROWIDs (`chat_message_join.chat_id = ?` or `IN (…)` of mapped chats). The only exception is `listOneToOneChats` (guid, handle, service, last activity; no message text).
- One mapping never reads or writes another mapping's state: every `StateStore` query filters on its `mapping_id`. Keep it that way.
- Bot tokens never on argv or in output. The CLI reads them from stdin or a hidden prompt; do not add a flag that takes a token value.
- Pass values to osascript through argv only. Never interpolate message text or identifiers into the script string.
- Never put message text, phone numbers, email handles or the bot token in logs or error messages.
- Never use the real `~/Library/Messages/chat.db` in tests. Tests build a temporary SQLite from the fixture schema in `Tests/`.

## Build and test (local gate)
Run `bash scripts/setup-dev.sh` once per clone. It sets `core.hooksPath=.githooks`:
- `pre-commit`: `scripts/check-staged.sh` on the staged lines (whitespace errors, conflict markers, tab indentation, bot-token / phone-number / chat-guid / Telegram-id / personal-e-mail shapes, and private terms listed in the local, uncommitted `.git/info/pii-denylist`).
- `commit-msg`: the Conventional Commits rule below.
- `pre-push`: `bash scripts/check.sh` (forbidden patterns + `swift build` + `swift test`).

Never bypass the hooks with `--no-verify`. If a hook is wrong, fix the hook in its own commit.

```bash
bash scripts/check.sh           # forbidden-pattern scan + swift build + swift test. Must pass before every commit
swift build                     # debug build
swift test                      # unit tests (XCTest, needs Xcode)
bash scripts/build-release.sh   # signed release binary -> dist/bluehop
```
`scripts/check.sh` fails on: an external package or `Package.resolved`; opening a DB read-write outside `StateStore`/`SQLite`; `ChatDB` not opening read-only; listening-socket APIs (`NWListener`, `bind(`, `listen(`, `HTTPServer`, `NSNetService`, `CFSocketCreate`); any hard-coded URL other than `https://api.telegram.org`; `osascript` outside `Platform.swift`.

## Install (on the operator's Mac, run by a person)
`bash scripts/install.sh`: runs the gate, builds and signs a release, places it at `~/Library/Application Support/bluehop/bin/bluehop`, and registers the LaunchAgent `dev.kanziw.bluehop`. Step-by-step with checks: `docs/AGENT-GUIDE.md`.
Agents do not grant macOS permissions, do not enter or read the bot token, and do not send real messages. Diagnostic commands that send (`diag-send-file`) need the operator's explicit go-ahead.

## Layout
- `Sources/BluehopCore/`: logic (under test). `Relay.swift` is the two-way engine for one mapping; `Supervisor.swift` runs one worker per mapping and reloads the config; `Config.swift` holds the mapping list, migration and guard rails; `MappingAdd.swift` the `mapping add` flow; `CLIArgs.swift` the argument parser and exit codes; `ChatPicker.swift` the terminal-free picker logic.
- `Sources/BluehopCLI/`: `main.swift` (command table, help), `Commands.swift` (`run`, `chats`, `mapping list|add|remove|pause|resume|test`, `doctor`, `status`, `telegram-ids`, `resume`, diagnostics, `version`), `Terminal.swift` (raw-mode picker, hidden prompt).
- CLI contract: every command and every script in `scripts/` handles `--help`/`-h` before anything else and exits 0 without side effects; unknown flags exit 2; `--json` output keys, the error codes in `ErrorCodes.catalog` (README "Machine-readable checks") and exit codes must stay stable (changing them is a breaking change). A new command needs a row in the side-effect table of `docs/AGENT-GUIDE.md` and an entry in `CLIBinaryTests.allCommands`.
- `Tests/BluehopCoreTests/`: fixture chat.db, mock Telegram (URLProtocol), fake Messages sender.

## Identifiers
`dev.kanziw.bluehop` is the Keychain service, LaunchAgent label, code-signing identifier and bundle identifier. Scripts and code use it together; do not change one without changing all of them (and do not rename it without the owner's decision).
The binary is `bluehop`, the Swift targets are `BluehopCore` and `BluehopCLI`, install paths are under `~/Library/Application Support/bluehop`, and the log is `~/Library/Logs/bluehop.log`. Changing any of these identifiers makes macOS treat the binary as a new app, so every install has to grant Full Disk Access and Automation again and move its Keychain item, config and state.

## Commits
- [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <summary>`.
- Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`. Add `!` (`feat!:`) and a `BREAKING CHANGE:` footer for breaking changes (config keys, identifiers, CLI behavior).
- Summary in English, imperative mood ("add", not "added"), no trailing period, at most 72 characters. The body explains why, wrapped at 72.
- One logical change per commit. Run `bash scripts/check.sh` before every commit that touches code, tests, scripts or packaging.
- Incident narratives, ticket numbers and dates belong in the commit body, not in code comments. Comments describe the current behavior and its reason.

## Branches and pull requests
- Contributors fork and open pull requests against `main`. Keep each PR to one topic.
- `bash scripts/check.sh` must pass before merge. There is no hosted CI yet; a ready template is in `docs/ci-template/swift.yml` and gets enabled when outside contributors arrive.
- Never put real phone numbers, email handles, chat guids, Telegram ids, bot tokens or message text in code, fixtures, test names, logs, issues or PR descriptions. Fixtures use fake GUIDs and made-up text.
- Changes to the security model (new permission, network host, dependency, write path) need an issue and maintainer agreement first.

## Changelog and versions
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Add user-visible changes under `## [Unreleased]` in the same PR.
- Versions follow [SemVer](https://semver.org/); before 1.0.0, a minor bump may break things.
- The version lives in two places that must match: `let version` in `Sources/BluehopCLI/main.swift` and `CFBundleShortVersionString` in `packaging/Info.plist`.

## Release flow (maintainers)
1. Move the `Unreleased` entries to `## [X.Y.Z] - YYYY-MM-DD` and update the compare links.
2. Bump the version in `main.swift` and `Info.plist`; run `bash scripts/check.sh`.
3. Commit `chore(release): vX.Y.Z`, tag `vX.Y.Z` (annotated), push the commit and the tag.
4. Create the GitHub release from the tag with the changelog section as notes. No binaries are attached until signed and notarized builds exist (`docs/PROPOSALS.md` §4).
5. Publish the site: `bash scripts/publish-site.sh --push` (copies `docs/site/` and `llms.txt` to `gh-pages`), then check that `https://kanziw.dev/bluehop/`, `/llms.txt` and `/sitemap.xml` return 200.

## Maintainer note
The public repository is [`kanziw/bluehop`](https://github.com/kanziw/bluehop). The maintainer develops in a separate private repository, where the maintainer and agents working for the maintainer commit directly to `main`, and exports cleaned releases to the public repository (`docs/PROPOSALS.md` §3). That is not a rule for public contributors, who use pull requests as above. Agents must not change any repository's visibility, settings or published metadata without the maintainer's explicit decision.
