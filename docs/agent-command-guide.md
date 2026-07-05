# Agent command guide — run without triggering approvals

The Vibe approval hook (`~/.vibe/vibe-approve-hook.js`) auto-allows read-only /
search / inspect commands and only asks a human for commands that **mutate state**
or run **arbitrary code**. Prefer the auto-allowed forms so a run flows without
stopping for approval. Only reach for a "asks" command when the task genuinely
needs it — e.g. **don't `cp` a file just to read or compare it**.

## Runs without asking (read / search / inspect)

- **Read & list:** `ls`, `cat`, `head`, `tail`, `wc`, `file`, `stat`, `du`, `df`,
  `tree`, `realpath`, `basename`, `dirname`
- **Search:** `grep`/`rg`/`ag`/`ack`, `find`/`fd`, `which`, `type`, `locate`, `mdfind`
- **Text (read-only):** `sed -n …`, `awk`, `cut`, `sort`, `uniq`, `tr`, `nl`,
  `column`, `comm`, `paste`, `rev`, `xxd`, `od`, `strings`, `base64`, `jq`, `yq`
- **Diff (no write):** `diff`, `cmp`, `colordiff`
- **Git (read-only):** `git status|diff|log|show|branch|blame|rev-parse|rev-list|`
  `ls-files|ls-tree|cat-file|reflog|stash list|tag -l|for-each-ref|show-ref|`
  `merge-base|config --get|grep`
- **Version/inspect:** `node -v`, `npm ls|why|outdated|view|run test|run lint`,
  `python3 --version`, `cargo check|vet|clippy`, `go vet|check`, `ps`, `lsof`,
  `pgrep`, `sysctl -n`
- **Build/query (free):** `xcodebuild … build`, `xcodebuild -list|-showBuildSettings`,
  `swift build`, `xcrun simctl list`, `xcrun --find`
- **Install to device (free):** `xcrun devicectl device install app …` — copies the
  built .app onto the phone, no observable effect until it's run. **Launching it**
  (`xcrun devicectl device process launch …`) is the consequential step and still
  asks — see [docs/run-on-device.md](run-on-device.md).
- **Build/test tools (free):** `make <target>` (build/test/check/lint/all only —
  bare `make` with no target still asks, since the default target is unknown),
  `cargo build|test|run`, `go build|test|run`, `tsc`, `vite`/`webpack`/`rollup`/
  `esbuild`/`parcel`, `gradle(w) build|test|assemble|check`, `mvn compile|test|`
  `package|verify`, `swift test`, and `npm|yarn|pnpm|bun run build|dev|start|test|`
  `typecheck|lint` — running/building/testing the project's own code never installs
  a dependency or touches git, so it's free.
- **Read-only network fetch (free):** `curl`/`wget` with no `-o`/`-O`/`--output`/
  `--upload-file`/`-X POST|PUT|PATCH|DELETE` — a plain GET that prints to stdout.
  Writing the response to a file, or piping into a shell, still asks.
- **Pipelines are fine:** each segment is checked independently, so
  `grep foo src | head`, `cat f | sort | uniq -c`, `find . | wc -l` all run.
  Quotes are respected — `grep -E 'a|b'` is not split on the `|`.

## Asks a human (mutating / sensitive)

Use only when the task needs the side effect:

- **Filesystem writes:** `cp`, `mv`, `rm`, `mkdir`, `touch`, `ln`, `chmod`,
  `sed -i`, `tee`, and any `>`/`>>` redirect to a file
- **Git writes:** `git add|commit|checkout|reset|rebase|merge|pull|fetch|apply|restore`
- **Package installs:** `npm install`, `pip install`, `gem/cargo/go install`
- **Arbitrary code / substitution:** `python3 -c …`, `node -e …`,
  `$(…)`, backticks, `<(…)`

## Prefer the tools over Bash for edits

The **Edit / Write** tools are auto-allowed — editing a file is free. So change a
file with Edit/Write instead of `sed -i` / `tee` / redirects, and read a file with
the **Read** tool or `cat` instead of copying it. Reserve `cp`/`mv`/`rm` for when
you actually need to move or delete something.

## Always blocked (even in `full`)

`rm -rf`, `sudo`, `git push`, `git reset --hard`, `git clean`, `dd`, `mkfs`,
`curl|sh`, `wget|sh`, `npm publish`, `shutdown`/`reboot`/`killall`, `chmod -R 777`.
These are denied in every remote mode — don't attempt them; ask the user to run
them manually if truly required.
