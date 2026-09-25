# Downshift

`dshift` runs Claude Code and Codex behind a small local proxy. Each new prompt goes to Jev,
which picks the cheapest model that can handle it, so easy turns downshift to a smaller model
and hard ones stay on the strong one.

- **Claude Code and Codex**, as a CLI (`dshift claude`, `dshift codex`) or through the desktop
  apps (`dshift apps enable`).
- **Starts where you would have started:** your `--model`, saved model or `config.toml` model.
  Routing only moves from there.
- **Fails open:** if Jev is slow, down or unconfigured, the turn stays on its current model.
- **Private by default:** the proxy listens on 127.0.0.1 only. Prompts and replies are never
  logged or written to disk; the usage ledger holds token counts and model ids.
- **One Swift binary**, macOS 14 or later. No Node.

## Install

Homebrew:

```sh
brew install prince2k3/tap/dshift
```

Mint:

```sh
mint install Prince2k3/downshift
```

From source (Xcode 16 or later):

```sh
swift build -c release
cp .build/release/dshift /usr/local/bin/
```

## Set up a Jev host

Jev can be reached through several hosts; Cloudflare is the default.

```sh
dshift setup
```

It asks for the host and its credentials, tests them with a fixed probe prompt, and saves them
in your login keychain, never in a file. Run it again to add a failover host.

| Host | Credentials |
|---|---|
| `cloudflare` (default) | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` |
| `typesafe` | `DSHIFT_API_KEY` |
| `vercel` | `AI_GATEWAY_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

`dshift hosts list` shows every host and which one is used; `dshift hosts test` makes one routing
call through each. Without a terminal:

```sh
printf %s "$TOKEN" | dshift setup --host cloudflare --set CLOUDFLARE_ACCOUNT_ID=<id> --key-stdin
```

## Use it

```sh
dshift claude                      # interactive Claude Code session
dshift claude -p "fix the tests"   # print mode
dshift codex                       # interactive Codex session
dshift codex exec "fix the tests"
```

dshift's own options go before the agent's; everything after is passed through unchanged.
`--no-route` keeps the proxy but never changes the model, and `--host none` turns routing off.

In Claude Code, the status line shows each decision. Choosing a model in `/model` pins it; pick
**Dynamic (Downshift)** to route again.

### Desktop apps

Apps are started from the Dock, so dshift can't wrap them. Instead it runs a background proxy
and points the apps' config files at it:

```sh
dshift serve install    # LaunchAgent on 127.0.0.1:47821, starts at login
dshift apps enable      # edits ~/.claude/settings.json and ~/.codex/config.toml
dshift status
dshift apps disable     # restores both files byte for byte
```

Each file is backed up before it is edited.

## Savings

```sh
dshift savings --since 7d
```

Every reply's tokens are priced twice: at the model that answered, and at the model the
conversation started on. Jev's own calls are subtracted. On a Claude or ChatGPT subscription
the figure is an API-equivalent cost, not money off your bill. Prices are built in and dated;
override or add models in `~/.config/downshift/prices.json`:

```json
{"models": {"my-model": {"input": 1, "output": 4, "cache_read": 0.1}}}
```

## Configuration

Settings come from, in order: the environment, the keychain, `./.env` and `~/.downshift.env`.

| Variable | Effect |
|---|---|
| `DSHIFT_HOST` | Host, or a comma-separated failover list; `none` turns routing off |
| `DSHIFT_MODEL` | Model the Jev host routes with |
| `DSHIFT_DEBUG=1` | Log each routing decision (never prompt text) |
| `DSHIFT_NO_STATUSLINE=1` | Don't add the Claude Code status line |
| `DSHIFT_CODEX_FAST_MODEL`, `_BALANCED_`, `_STRONG_` | Codex model for each tier |

`dshift doctor` checks the agents, the host, the proxy and the app config.

## Development

```sh
swift build
swift test
```

`DSHIFT_LIVE=1 swift test` also calls the real hosts, and `DSHIFT_KEYCHAIN_TEST=1` round-trips
a throwaway login keychain item. Captured traffic under `Tests/Fixtures` holds private prompts
and is never committed.

## License

MIT. See [LICENSE](LICENSE).
