# Proposals and decisions

Each section says what would change and what it needs from the maintainer. Sections marked **Decided** record what was chosen; everything else is still a proposal and has not been applied.

## 1. Project name (Decided: bluehop)

**Decision (2026-10-15): the project is named bluehop**, with the tagline "iMessage to Telegram relay for one chat" (since 0.5.0, several chats are supported and the tagline is "iMessage to Telegram relay, one bot per chat"). The name is used for the repository, docs, site, `llms.txt`, social preview and every runtime identifier: the binary `bluehop`, the Swift targets `BluehopCore` and `BluehopCLI`, `dev.kanziw.bluehop` (Keychain service, LaunchAgent label, signing and bundle id), paths under `~/Library/Application Support/bluehop` and the log `~/Library/Logs/bluehop.log` (since 0.4.1, see §2-6).

The analysis that led to the decision:

A purely descriptive name ("iMessage relay") is weak as a brand: it is generic, it collides with existing public repos, and it is easy to confuse with [openclaw/imsg](https://github.com/openclaw/imsg) (a Messages.app CLI for agents). A name without "Apple", "iMessage", "Mac" or "Telegram" avoids trademark trouble; the keywords belong in the description and README title instead.

Checks run on 2026-10-15:
- **GitHub:** `gh api search/repositories -f q="<name> in:name"`; "exact" counts repos whose name equals the candidate.
- **Homebrew:** `https://formulae.brew.sh/api/formula/<name>.json` and `/api/cask/<name>.json` (404 = free).
- **Packages:** npm `registry.npmjs.org/<name>`, PyPI `pypi.org/pypi/<name>/json`, crates.io `/api/v1/crates/<name>` (404 = free).
- **Domains:** RDAP at the .dev/.app registry, `https://pubapi.registry.google/rdap/domain/<name>.dev|.app` (404 = not registered; control `google.dev` returned 200). Not a purchase quote.
- **Trademarks:** only a general web search for the exact word. **A USPTO/EUIPO register search was not done** (their search UIs need a browser session). Do one before committing to a name.

| Name | Meaning | GitHub (exact / any) | Homebrew | npm / PyPI / crates | .dev / .app | Obvious conflicts (web search) | Verdict |
|---|---|---|---|---|---|---|---|
| **ferrybird** | A ferry between two shores; a bird carrying messages | 0 / 1 | free | free / free / free | free / free | none found | **Top pick** |
| **bluehop** | One hop from the blue bubble | 1 / 22 | free | free / free / free | free / free | "BlueHopper" (outdoor lighting app), "Blue Hope" app: different fields | Good runner-up |
| **quaypost** | A post office on the quay | 0 / 0 | free | free / free / free | free / free | none found | Clean but harder to say |
| **ferrylet** | A small ferry | 0 / 0 | free | free / free / free | free / free | none found | Clean, a bit cute |
| bubbleferry | Ferrying message bubbles | 0 / 0 | free | free / free / free | free / free | none found, but "bubble" invites confusion with BlueBubbles | Avoid |
| macferry | A ferry on your Mac | 0 / 0 | free | free / free / free | free / free | contains "Mac", an Apple trademark | Avoid |
| relaybell | A bell when a message arrives | 1 / 1 | free | **taken / taken** / free | free / free | RelayBell, an existing push-notification product with SDKs on npm and PyPI | Avoid |
| pairpost | Post between a pair | 1 / 3 | free | free / free / free | free / taken | rivera-daniel/pairpost: an encrypted contact channel "for people and their agents" (same space) | Avoid |
| twinline | Two lines joined | 10 / 28 | free | free / free / free | free / taken | "Twinline: Second Phone Line" (calls and texts app), a SIP softphone, banking software | Avoid |
| tincan | Tin-can telephone, 1:1 | 68 / 372 | free | taken / taken / taken | taken / taken | mvanhorn/agent-tincan (305 stars, agent messaging) | Avoid |
| isthmus | A land bridge joining two areas | 24 / 142 | free | taken / free / taken | taken / taken | many projects | Avoid |

The original recommendation was **ferrybird**, with the tagline "iMessage to Telegram relay for one chat"; the maintainer chose **bluehop**.

## 2. Install and operations UX

Today a new user runs `install.sh --no-load`, a `security` command, two System Settings screens, `telegram-ids`, `list-chats`, hand-edits JSON, `doctor`, and `install.sh` again. Each step is a place where a new setup can get stuck (running `telegram-ids` after the relay already started, ad-hoc signing losing permissions on reinstall, a doctor failure during reinstall leaving the service stopped). Proposed, in order of value; none is implemented except 2-6.

| # | Proposal | What changes | Size |
|---|---|---|---|
| 2-1 | **`bluehop setup`** interactive command | One guided flow: read the token from a hidden prompt into the Keychain; open the Full Disk Access and Automation panes (`x-apple.systempreferences:` URLs) and wait until access works; call `getUpdates` once to show "Send any message to @yourbot" and pick up `chatId`/`allowedUserId`; list 1:1 chats with masked handles and let the user pick one; write `config.json` with 0600; run `doctor --messages --telegram`; offer to start the LaunchAgent. Must run through launchd (like `agent-run.sh`) so the permission belongs to the binary. Re-runnable: each step is skipped when already done. | Medium, new CLI code + tests |
| 2-2 | **`status`, `upgrade`, `uninstall` commands** | `status`: LaunchAgent state, pid, version, last start line, halt reason, backlog, no message text. `upgrade`: download the latest signed release (2-4), verify signature and SHA-256, swap the binary, restart, confirm the new pid and a clean start, roll back on failure. `uninstall [--purge]`: what `uninstall.sh` does, plus the attachment staging folder and the log, and prints the System Settings entries to remove. | Small to medium |
| 2-3 | **Safer `install.sh`** | Do not `bootout` a running relay until the new binary has passed `doctor`; if doctor fails after replacing, restore the previous binary and restart it. Today a failing doctor leaves the service stopped. | Small |
| 2-4 | **Signed and notarized release binary** (detailed plan in §4) | GitHub Actions on tag `v*`: build universal (arm64 + x86_64) release, sign with a Developer ID Application certificate (secrets in the repo's Actions secrets), notarize with `notarytool`, publish `bluehop-vX.Y.Z-macos.zip` + SHA-256 + build provenance (`actions/attest-build-provenance`). Users no longer need Xcode, and permissions survive upgrades because the signing identity is stable. Needs an Apple Developer Program membership (paid, owner decision). | Medium + owner account |
| 2-5 | **Homebrew tap** | `brew install <owner>/tap/<name>` installing the notarized binary from 2-4, with `brew services` or the `setup` command creating the LaunchAgent. A tap is a separate public repository, so it is a public step. | Small after 2-4 |
| 2-6 | **Identifiers (Decided, done in 0.4.1)** | `dev.kanziw.bluehop` is the Keychain service, LaunchAgent label, signing and bundle id: it sits under the maintainer's domain `kanziw.dev`, which also hosts the project site, so no new domain is needed. A separate project domain (e.g. `dev.bluehop.relay`) or `io.github.kanziw.bluehop` stays possible later, but any identifier change makes macOS ask for Full Disk Access and Automation again and needs the Keychain item, config and state moved. | Done |
| 2-7 | **Health alert when the relay stops** | A launchd-run watchdog is not possible from inside the relay, so: (a) the relay already posts to Telegram on safety halts; add a message on clean shutdown and on startup after a crash ("restarted after exit code N"); (b) optional `bluehop heartbeat` one-shot LaunchAgent every 15 minutes that checks the main job is running and the last loop timestamp in `state.sqlite` is fresh, and if not, sends one Telegram message (with a cooldown). Outbound to `api.telegram.org` only, so it keeps the no-open-ports rule. | Small to medium |
| 2-8 | **English UI strings** (partly done in 0.5.1: `--lang en` for `doctor`, `mapping test`, `status`, and stable error codes in their JSON) | Bot replies, logs and the remaining CLI text are Korean only. Add an English string table with a `relay.language` config key (`"ko"` default for existing installs, `"en"` for new ones). | Medium |
| 2-9 | **Strict CLI arguments (Done in 0.5.0 and 0.5.1)** | Every command has `--help`, unknown flags exit 2 (0.5.0). Since 0.5.1 `--help`/`-h` wins anywhere before `--`, and every script in `scripts/` handles `--help` first and rejects unknown arguments. | Done |
| 2-10 | **Formatter in pre-commit** | `swift format` ships with the toolchain (6.2.3 here), but its default style reports about 4,300 findings on the current code (mostly 2- vs 4-space indentation). Add a `.swift-format` config matching the current style (4 spaces, longer lines), reformat once in a single `style:` commit, then run `swift format lint` on staged Swift files in pre-commit. | Small, one large diff |

## 3. Public release (Decided, done 2026-10-15)

**Decision: publish a fresh public repository, [kanziw/bluehop](https://github.com/kanziw/bluehop), whose history starts with one squashed commit of the cleaned tree. The maintainer's private development repository stays separate.** The private repository is not made public because its early history contains personal references that are not in the current tree; making it public would need a history rewrite and a full-history secrets scan first.

Release procedure (first done for v0.4.0):
1. In the private repo: `bash scripts/check.sh` passes (there is no hosted CI yet; the hooks in `.githooks/` enforce it locally), `CHANGELOG.md` has the release section, version bumped in `main.swift` and `Info.plist`, no `[OWNER: …]` placeholders anywhere.
2. Personal-data check of the tree to be published (not history): run `scripts/check-staged.sh`-style patterns over every tracked file (`git add -A -n` is not enough; also grep for private terms from `.git/info/pii-denylist`, local absolute paths, and phone/email/guid/id/token shapes beyond the documented placeholders), and make sure `.DS_Store`, `dist/`, `.build/` are absent.
3. Export the tree without history: `git archive --format=tar HEAD | tar -x -C <empty dir>`, commit it in the public repo's clone (one commit per release, authored by the maintainer), tag `vX.Y.Z`, push.
4. Metadata (`docs/launch/github-metadata.md`): description, topics, homepage, private vulnerability reporting, Pages from `docs/site/` on the `gh-pages` branch. The social preview image is uploaded by hand (Settings → General → Social preview). When outside contributors start sending PRs, enable CI by copying `docs/ci-template/swift.yml` to `.github/workflows/ci.yml`.

## 4. Signed, notarized release binaries with checksums (proposal, not started)

Today the GitHub releases have notes but no downloadable assets: every user builds with full Xcode, and an ad-hoc signed build makes macOS ask for Full Disk Access and Automation again after each reinstall. Proposal, in the order it would be done. Nothing here is implemented; steps 1 and 2 need owner decisions.

1. **Owner decisions.** (a) Join the Apple Developer Program (paid, yearly) for a *Developer ID Application* certificate; notarization is not possible without it. (b) Decide where signing happens: on the owner's Mac with a script (the key never leaves that Mac; simplest), or in GitHub Actions (the `.p12` and an App Store Connect API key live in Actions secrets; reproducible, but the key leaves the Mac). Recommendation: start with the local script, move to Actions only when there is a second maintainer.
2. **Identity stays `dev.kanziw.bluehop`.** Keep the code-signing identifier, so TCC permissions follow the Team ID + identifier. Moving existing users from an Apple Development or ad-hoc signature to Developer ID makes macOS ask for the permissions one more time; the release notes must say so.
3. **Build.** `scripts/build-release.sh --universal` (new flag): `swift build -c release --arch arm64 --arch x86_64`, embed `Info.plist`, sign with `--options runtime --timestamp` (a secure timestamp is required for notarization; today's build uses `--timestamp=none`) and the existing entitlements.
4. **Notarize.** Zip the binary (`ditto -c -k --keepParent`), `xcrun notarytool submit --wait` with a keychain profile, then check `spctl -a -vvv -t install` and `codesign --verify --strict`. A bare Mach-O cannot be stapled, so Gatekeeper checks the ticket online on first run; shipping a signed `.pkg` would allow stapling and is an option for later.
5. **Publish.** Attach to the GitHub release: `bluehop-vX.Y.Z-macos-universal.zip`, `SHA256SUMS` (`shasum -a 256`), and the notarization log. Optionally sign `SHA256SUMS` (minisign or `gh attestation` / `actions/attest-build-provenance` when built in Actions) so the checksum file itself can be verified.
6. **Install from a release.** `scripts/install.sh --from-release vX.Y.Z` (new): download the zip and `SHA256SUMS` over HTTPS from github.com, verify the checksum and `codesign -dv` Team ID before placing the binary, then the same LaunchAgent steps as today. The relay binary itself stays limited to `api.telegram.org`; only the install script talks to GitHub. This removes the full-Xcode requirement for users (developers still need it).
7. **Docs and checks.** README, AGENT-GUIDE, site and `llms.txt` get a "download" path next to "build from source"; `AGENTS.md` release flow gets the notarize and checksum steps; a release is not announced until the checksum and `spctl` checks above pass on a second Mac.

Size: about a day of work after the Developer ID certificate exists, most of it in steps 3, 4 and 6. Risk: a wrong Team ID or identifier change resets users' permissions, so step 2 is checked before the first public binary.
