# QuotaBar

macOS menu bar monitor for Claude Code and Codex quotas. Menu bar only: no window, no Dock icon.

```
C: 64% | X: 96%
   │         └ Codex: 5h session %, or the weekly % when the API reports no session window
   └────────── Claude: 5h session %
```

Numbers are tinted by used quota: 0–50 green, 50–80 yellow, 80+ red.

Click the item for the full picture: per provider a header (plan · signed-in email), Session / Weekly
rows plus Claude's per-model weekly caps (e.g. Fable) as colour chips with the reset time, Codex's banked
"full reset" credits (count + earliest expiry), a Today row with the tokens consumed today, then a
Used ⇄ Remaining switch (colours always follow used %), Refresh Now with the last update time, and Quit.
Weekday and duration wording follows the system language.

Today's tokens come from this Mac's local transcripts, since neither usage API reports token counts:
Claude Code `~/.claude/projects/**/*.jsonl` (`message.usage`, input + output + cache creation + cache
read, largest value per message id), Codex `~/.codex/sessions/**/*.jsonl` (`token_count` events,
today's growth of the per-session cumulative `total_token_usage`). Other devices are not included.

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

Polling: every 5 minutes, plus on menu open when data is older than 60 s. A 429 from either API
backs that provider off (10 min, doubling, max 60 min); Refresh Now ignores the backoff.

## Tokens

QuotaBar never refreshes or writes credentials. When a token expires the menu says so:

- Claude: run `claude` once, it refreshes the Keychain item.
- Codex: run `codex` once, it refreshes `auth.json`.

First launch triggers a Keychain permission dialog for `Claude Code-credentials`; choose
**Always Allow**. The app is signed with a stable Apple Development identity so the grant survives rebuilds.
