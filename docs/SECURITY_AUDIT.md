# Open-source security audit

Audit date: 2026-07-16

## Executive summary

The publishable Git index contains no detected credentials, private keys, personal macOS paths, personal quick prompts, runtime logs, or local environment files. The directory had no Git repository or commit history before this preparation, so there is no historical Git secret exposure to rewrite. No remote has been configured and no files have been published.

Two high-impact local issues and one medium-impact browser boundary issue were corrected during preparation. Five automated security regression tests and a tracked-file release scanner now run locally and in CI.

## Findings

### SEC-001 — Local configuration and archive could be published

- Severity: High
- Status: Fixed
- Location: `.gitignore:12-23`, `desk-sprite/.desk-sprite.env.example:1-9`
- Evidence: The original directory contained `.desk-sprite.env` with mode `0644`, runtime logs/PID, a 478MB ZIP containing that env file and build output, plus duplicate source-media directories.
- Impact: A future Gateway Token, local paths, logs, or build artifacts could be committed or shared accidentally.
- Fix: All local state, archives, build output and duplicate media are ignored. The real env file is now `0600`; only a placeholder example is tracked.
- Verification: `git status --ignored`, staged filename inspection, release scanner, and a secret-pattern scan.

### SEC-002 — Editable env values were evaluated as shell code

- Severity: High
- Status: Fixed
- Location: `desk-sprite/launch.sh:16-46`, `desk-sprite/console_server.py:37-67`
- Evidence: The original launcher used `source .desk-sprite.env`, while the local console wrote user-controlled strings into that file.
- Impact: A value containing shell substitution could execute local commands the next time the pet restarted.
- Fix: The launcher now parses only five allowlisted keys and exports values as data. The API rejects NUL and newline characters and validates URL, number, and script-path formats.
- Verification: Shell syntax validation and `test_rejects_multiline_config_values`.

### SEC-003 — Local console lacked browser-origin and Host validation

- Severity: Medium
- Status: Fixed
- Location: `desk-sprite/console_server.py:70-98`, `desk-sprite/console_server.py:193-260`
- Evidence: The original API accepted POST requests without validating Host, Origin, or `Sec-Fetch-Site`, and returned the configured Gateway Token from `/api/config`.
- Impact: A malicious browser page could attempt cross-site state changes against the loopback service; permissive Host handling also increased DNS-rebinding exposure.
- Fix: The service remains loopback-only and now validates the bound port, loopback Host, Origin and fetch site. It adds no-store, framing, content-type, referrer, permissions, resource-policy and CSP headers. JSON bodies are capped at 64KiB.
- Verification: Live HTTP checks returned `200` for the valid loopback request and `403` for invalid Host and cross-origin POST requests.

### SEC-004 — Personal and machine-specific defaults were embedded in source

- Severity: Medium
- Status: Fixed
- Location: `desk-sprite/Sources/DeskSprite/main.swift:57-64`, `desk-sprite/Sources/DeskSprite/main.swift:1299-1308`, `desk-sprite/console_server.py:172-180`
- Evidence: Source contained a private volume path, a machine-specific OpenClaw start script and a quick prompt naming a private contact.
- Impact: Publishing would disclose personal context and make service control fail on other machines.
- Fix: Defaults now use standard home-relative OpenClaw locations, the start script is optional configuration with a CLI fallback, and example prompts are generic.

### SEC-005 — Inline console code weakens CSP hardening

- Severity: Low
- Status: Accepted for this release
- Location: `desk-sprite/console/index.html:1-845`, `desk-sprite/console_server.py:194-202`
- Evidence: The single-file console contains inline CSS and JavaScript, so its CSP currently permits `unsafe-inline` for style and script.
- Impact: This reduces CSP's defense-in-depth value if an HTML injection bug is introduced later.
- Mitigation: The console has no third-party scripts; user-provided prompt text is assigned through input values or `textContent`. Existing `innerHTML` assignments use fixed SVG constants only. Host/Origin validation and loopback binding reduce exposure.
- Recommended follow-up: Move CSS and JavaScript into same-origin static files, then remove both `unsafe-inline` allowances.

## Non-security release risks

- Visual asset rights cannot be proven solely from the repository. The two console PNG files have ChatGPT download provenance metadata; MOV files have no author/copyright metadata. The repository owner must confirm the right to distribute every included visual under MIT before making the repository public.
- The tracked repository is about 381MB. All files are below GitHub's 100MiB hard limit, but `media/idle-core.mov` is above 50MiB and will trigger a warning. Repeated binary revisions should use Git LFS or release assets.

## Verification performed

- `swift build --package-path desk-sprite`
- `python3 -m unittest discover -s desk-sprite/tests -v`
- Python and Shell syntax checks
- Live loopback HTTP allow/deny checks and response-header inspection
- Staged filename, size, secret-pattern, personal-path and diff-whitespace scans
- `python3 scripts/check_release.py`
