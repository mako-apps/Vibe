# @vibegram/agent-bridge

Run `@claude` / `@codex` / `@grok` / `@agy` on **your own computer**, driven from the Vibe app.

The bridge dials *out* to the Vibe server (no inbound ports). When you mention
`@claude` or `@codex` in Vibe, the task runs here, on your machine, using your own
Claude/Codex/Grok subscription — and the result streams back into the chat.

## Use

In the Vibe app, open **Claude**, **Codex**, or **Grok**, tap **Connect**, and copy the
command shown. On your computer:

```bash
npx @vibegram/agent-bridge --code <PAIRING_CODE> --server https://your-vibe-server
```

The first run pairs the computer, asks which project(s) to link, then installs the
macOS background service so the bridge survives closed terminals and restarts at
login. After the first pairing the token and project pick are cached in
`~/.vibe/bridge.json`, so later you can restart/update the background service with:

```bash
npx @vibegram/agent-bridge --server https://your-vibe-server
```

> Until the package is published to npm, run the daemon from this repo instead:
> `node bin/vibe-bridge.js --code <PAIRING_CODE> --server https://your-vibe-server`

`--pick` opens the terminal project selector again. `--foreground` runs in the
current terminal instead of the background service. `--logout` removes the cached
token. `--cwd <path>` overrides the working directory.

## Safety

Default mobile sends use **safe auto** execution:

- `claude --permission-mode auto`
- `codex --sandbox workspace-write -c approval_policy="never"`
- `grok -p … --output-format streaming-json --permission-mode auto --always-approve`

Escalate explicitly with env vars (only on machines you control):

| Env | Default | Notes |
|---|---|---|
| `VIBE_CLAUDE_PERMISSION_MODE` | per task | `plan`, `auto`, `acceptEdits`, `dontAsk`, or `bypassPermissions` |
| `VIBE_CODEX_SANDBOX` | `read-only` | `workspace-write` / `danger-full-access` |
| `VIBE_CODEX_APPROVAL_POLICY` | per task | `untrusted`, `on-request`, or `never` |
| `VIBE_CLAUDE_MODEL`, `VIBE_CODEX_MODEL`, `VIBE_GROK_MODEL` | — | executor model override |
| `VIBE_CLAUDE_ADVISOR`, `VIBE_CLAUDE_ADVISOR_MODEL` | `fable` for installed service | Claude advisor model override |
| `VIBE_FABLE_MCP` | enabled | Exposes `mcp__vibeask__ask_fable` so Claude can explicitly ask Fable with mid-run context |
| `VIBE_FABLE_MODEL` | `fable` | Model used by the explicit Fable MCP advisor tool |
| `VIBE_FABLE_MCP_CONTEXT_CHARS` | `24000` | Max packaged prompt chars for Fable (raise only when needed) |
| `VIBE_FABLE_MCP_TIMEOUT_MS` | `240000` | Timeout for the one-shot Fable `claude -p` spawn |
| `VIBE_CLAUDE_COMMAND`, `VIBE_CODEX_COMMAND`, `VIBE_GROK_COMMAND` | `claude` / `codex` / `grok` | binary path override |
| `VIBE_GROK_MODEL` | — | Grok model override |
| `VIBE_GROK_PERMISSION_MODE` | per task | Grok `--permission-mode` |

Mobile work modes map to CLI safety settings:

- `plan`: Claude `plan`; Codex `read-only` + `untrusted`.
- `read_only`: Claude `manual` with write/shell tools denied; Codex `read-only` + `untrusted`.
- `ask`: Claude `manual` with phone approvals; Codex `read-only` + `on-request`.
- `ask_auto`: Claude `auto`; Codex `workspace-write` + `never`.
- `allow_edits`: Claude `acceptEdits`; Codex `workspace-write` + `never`.
- `full_access`: Claude `bypassPermissions`; Codex `danger-full-access` + `never`.

## Dev

```bash
cd agent-bridge && npm install
node bin/vibe-bridge.js --help
```
