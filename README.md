# QuotaBar

Native macOS menu bar monitor for Claude Code and Codex quotas, with a compact usage menu and a settings window. Both providers appear together in the menu. Refresh and Settings sit at the top right; platform names are shown in full in the menu bar.

- **Appearance**: battery, progress bar, percentage, badge percentage, or ring indicators; usage, monochrome, or accent colors; system, light, or dark theme. Badge percentages use rounded green/yellow/red backgrounds in usage-color mode. The preview and menu bar use the same renderer.
- **Usage menu**: session and weekly quota, Claude per-model limits, local daily tokens, Codex full-reset count and earliest expiry. Reset times can show the date, countdown, or both. Missing windows and saved-log data are labeled explicitly.
- **History**: provider filter, 5-hour / 24-hour / 7-day / 30-day / 90-day ranges, previous/next navigation, and JSON/CSV export of the visible samples. Daily token bars show the highest daily count observed in the selected range.
- **Notifications**: optional session and weekly thresholds (75%, 90%, 95% by default), custom thresholds, sound, and quota-reset alerts. macOS permission is requested when notifications are enabled. Deduplication is persisted per account and quota window; API reset dates identify new windows. Saved-log fallback data does not trigger alerts.
- **Settings**: refresh interval, login startup, history retention, read-only account status, and raw-response diagnostics. The usage menu supports ⌘R and ⌘,; settings supports ⌘W.
- **Language**: choose 简体中文 or English in App Settings → Language. Switching updates the interface, menu, notifications, dates, and token units immediately, and saves the choice for future launches. The first launch selects Simplified Chinese for a Chinese system language and English otherwise. Account/model names, exported field names, and raw diagnostic data retain their original values.

The menu bar shows Claude's session window and Codex's session window, falling back to Codex's weekly window when the API supplies only that window. Appearance → Usage Color Thresholds sets the warning and critical boundaries. Defaults are green below 50%, warning from 50%, and red from 80%. Yellow begins at the warning boundary; plain indicators retain their orange warning tint. Green updates automatically, and Restore Defaults restores 50% / 80%. The boundaries must satisfy 1 ≤ yellow < red ≤ 100. Colors always follow consumed quota in both used and remaining display modes. Color settings are independent of notification thresholds.

Today's tokens come from this Mac's local transcripts: Claude Code `~/.claude/projects/**/*.jsonl` (`message.usage`, input + output + cache creation + cache read, largest value per message id), and Codex `~/.codex/sessions/**/*.jsonl` (`token_count` events, today's growth of the per-session cumulative `total_token_usage`). Other devices are not included.

History uses the existing `~/Library/Application Support/QuotaBar/history.jsonl` format, sampled at most once per provider every 15 minutes. Retention choices are 7, 30, 90, and 365 days; pruning runs at launch.

## Build / run

```bash
make run       # build → bundle → sign → launch from ./build
make install   # same, then copy to /Applications and launch
make stop      # quit the running instance
./build/QuotaBar.app/Contents/MacOS/QuotaBar --once   # print one fetch to stdout
```

Requirements: macOS 13+ on Apple Silicon, Xcode command line tools.

## Developing on another Mac

```bash
git clone <remote> QuotaBar && cd QuotaBar
make install
```

Signing: the Makefile picks the first valid Apple Development identity in the login keychain and
falls back to ad-hoc when there is none. Pin one per machine in an untracked `local.mk`
(`SIGN_ID := <sha1>`, list identities with `security find-identity -v -p codesigning`). The Keychain
"Always Allow" for Claude Code's token is bound to that identity; with ad-hoc signing the prompt comes
back after every rebuild. First launch on a new Mac asks for Keychain access once, and needs Claude
Code and Codex to be signed in there.

## Data sources

| Provider | Credential | Endpoints |
|---|---|---|
| Claude | Keychain item `Claude Code-credentials` → `claudeAiOauth.accessToken` | `GET https://api.anthropic.com/api/oauth/usage` (windows; `limits[]` kind `weekly_scoped` carries per-model caps), `GET …/api/oauth/profile` (`account.email`, fetched once per launch). Both with `anthropic-beta: oauth-2025-04-20`. |
| Codex | `~/.codex/auth.json` → `tokens.access_token` + `tokens.account_id` | `GET https://chatgpt.com/backend-api/wham/usage` (windows, `email`, `rate_limit_reset_credits.available_count`), `GET …/wham/rate-limit-reset-credits` (credit expiries). Both with `chatgpt-account-id`. |

`./build/QuotaBar.app/Contents/MacOS/QuotaBar --once --raw` prints every response verbatim (contains the account email).

Codex fallback: when the API call fails (most often an expired token), the newest
`rate_limits` event in `~/.codex/sessions/**/*.jsonl` is shown, marked with ⓘ and its timestamp.

Polling: every 5 minutes by default (configurable), plus on popover open when data is older than 60 s. A 429 from either API
backs that provider off (10 min, doubling, max 60 min); Refresh Now ignores the backoff.

## Tokens

QuotaBar never refreshes or writes credentials. When a token expires the menu says so:

- Claude: run `claude` once, it refreshes the Keychain item.
- Codex: run `codex` once, it refreshes `auth.json`.

First launch triggers a Keychain permission dialog for `Claude Code-credentials`; choose
**Always Allow**. The app is signed with a stable Apple Development identity so the grant survives rebuilds.

## Verification and previews

```bash
swift test
make bundle
open build/QuotaBar.app --args --settings
```

A preview launch uses explicit sample data and temporary display preferences. It leaves credentials, history, login items, and notification delivery untouched:

```bash
open -n build/QuotaBar.app --args --preview --settings --preview-theme=dark --preview-page=history
open -n build/QuotaBar.app --args --preview --settings --preview-page=app --preview-language=zh-Hans
open -n build/QuotaBar.app --args --preview --preview-popover --preview-provider=codex --preview-state=fallback
```

Preview pages: `appearance`, `general`, `history`, `account`, `app`, `popover`, `diagnostics`. Preview states: `normal`, `empty`, `loading`, `expired`, `fallback`, `weekly-only`. Themes: `system`, `light`, `dark`. Languages: `en`, `zh-Hans`. Preview content is identified as sample data. Use a separate preview bundle when a production copy is already running.

Tests cover threshold crossings, reset boundaries, restart persistence, send retries, account/window isolation, fallback suppression, preference migration, preview isolation, and filtered history exports.

Localization tests check resource-key and placeholder parity, saved language choices, compatibility with older preferences, immediate format/error updates, and stable notification identities. `make bundle` packages both languages under `Contents/Resources/QuotaBar_QuotaBar.bundle`; the app resolves this bundled copy before development resources.

## Attribution

The native UI adapts layouts from Claude-Usage-Tracker. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for the source attribution and MIT license.

Color-threshold tests cover default and custom boundaries, persistence, older preferences, invalid-value recovery, renderer color modes, and independent notification settings.
