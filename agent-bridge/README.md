# @vibegram/agent-bridge

Run `@claude` / `@codex` on **your own computer**, driven from the Vibe app.

The bridge dials *out* to the Vibe server (no inbound ports). When you mention
`@claude` or `@codex` in Vibe, the task runs here, on your machine, using your own
Claude/Codex subscription — and the result streams back into the chat.

## Use

In the Vibe app, open **Claude** or **Codex**, tap **Connect**, and copy the
command shown. On your computer, inside the project you want the agent to work in:

```bash
npx @vibegram/agent-bridge --code <PAIRING_CODE> --server https://your-vibe-server
```

After the first pairing the token is cached in `~/.vibe/bridge.json`, so later you
can just run:

```bash
npx @vibegram/agent-bridge --server https://your-vibe-server
```

> Until the package is published to npm, run the daemon from this repo instead:
> `node bin/vibe-bridge.js --code <PAIRING_CODE> --server https://your-vibe-server`

`--logout` removes the cached token. `--cwd <path>` overrides the working
directory (defaults to where you launched it).

## Safety

Defaults to **read-only** execution:

- `claude --permission-mode plan`
- `codex --sandbox read-only`

Escalate explicitly with env vars (only on machines you control):

| Env | Default | Notes |
|---|---|---|
| `VIBE_CLAUDE_PERMISSION_MODE` | `plan` | `acceptEdits` / `bypassPermissions` allow writes/exec |
| `VIBE_CODEX_SANDBOX` | `read-only` | `workspace-write` / `danger-full-access` |
| `VIBE_CLAUDE_MODEL`, `VIBE_CODEX_MODEL` | — | model override |
| `VIBE_CLAUDE_COMMAND`, `VIBE_CODEX_COMMAND` | `claude` / `codex` | binary path override |

## Dev

```bash
cd agent-bridge && npm install
node bin/vibe-bridge.js --help
```
