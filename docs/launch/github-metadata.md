# GitHub metadata for kanziw/bluehop

Applied when the public repository was created (2026-10-15, see `docs/PROPOSALS.md` §3). Keep this file in sync when the settings change.

**Description** (≤ 350 characters):

> iMessage to Telegram relay, one bot per chat. Forward the iMessage 1:1 chats you choose to Telegram bots and reply from Telegram. Tiny macOS Swift binary you build on your Mac: zero dependencies, no open ports, no bluehop-operated server, SIP stays on. Bot messages are stored by Telegram (not E2EE).

The live description (set when 0.5.0 shipped) still says "no cloud"; replace it with the text above by hand (Settings → General, or `gh repo edit kanziw/bluehop --description …`). Changing published metadata is the maintainer's decision.

**Website:** the GitHub Pages site, built from `docs/site/` (plus `llms.txt` from the repo root) and published on the `gh-pages` branch with `bash scripts/publish-site.sh --push`. It serves `index.html`, `llms.txt`, `sitemap.xml` and `social-preview.png`. Crawlers read `robots.txt` only at the host root, `https://kanziw.dev/robots.txt`, which comes from the account's Pages site (`kanziw/kanziw.github.io`) behind Cloudflare; its `Sitemap:` line points to `https://kanziw.dev/bluehop/sitemap.xml`. The account's Pages domain makes it <https://kanziw.dev/bluehop/> (`https://kanziw.github.io/bluehop/` redirects there).

**Topics** (10; GitHub allows up to 20, lowercase, hyphens):

`imessage`, `imessage-bridge`, `telegram`, `telegram-bot`, `macos`, `swift`, `self-hosted`, `launchagent`, `zero-dependency`, `relay`

**Social preview:** `docs/launch/social-preview.png` (1280×640). Regenerate with `swift docs/launch/render-social-preview.swift docs/launch/social-preview.png` and copy it to `docs/site/social-preview.png`. GitHub has no API for this image: upload it by hand in Settings → General → Social preview → Edit → Upload an image.

**Settings:** issues on, private vulnerability reporting on, wiki off, projects off. Discussions optional, off for now.

**Sponsorship:** a later goal. `.github/FUNDING.yml` is a commented placeholder until a sponsor account exists.
