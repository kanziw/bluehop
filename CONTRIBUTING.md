# Contributing

Thanks for helping. The rules for code, commits, tests and releases live in one place, [AGENTS.md](AGENTS.md), and apply to people and coding agents alike. Please read it before opening a pull request.

The short version:

1. Open an issue first for anything larger than a small fix, so we can agree on scope. This project stays deliberately small (one chat, Telegram only, no dependencies, no open ports).
2. Fork, branch from `main`, keep the change focused, and run `bash scripts/setup-dev.sh` once to enable the repo's git hooks (pre-commit checks, commit-message check, build and tests before push). Do not bypass them with `--no-verify`.
3. Run `bash scripts/check.sh` (forbidden-pattern scan + `swift build` + `swift test`) and make sure it passes.
4. Use [Conventional Commits](https://www.conventionalcommits.org/) and add a line to `CHANGELOG.md` under "Unreleased" for user-visible changes.
5. Never include real phone numbers, email handles, chat guids, Telegram ids, bot tokens or message text in code, fixtures, logs, issues or screenshots.

Security problems: please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
