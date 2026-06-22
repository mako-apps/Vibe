#!/bin/sh
set -euo pipefail

# Start Python doc renderer in background on port 5050
python3 /app/python/doc_renderer.py 5050 &
DOC_RENDERER_PID=$!
echo "[start.sh] Doc renderer started (PID $DOC_RENDERER_PID)"

# Enable Phoenix server
export PHX_SERVER=true

# Run database migrations before serving (idempotent; already-applied
# migrations are skipped). Aborting here on failure is safer than booting the
# app against a schema that is missing newly-added columns.
echo "[start.sh] Running migrations..."
/app/bin/vibe eval "Vibe.Release.migrate()"
echo "[start.sh] Migrations complete"

# Start Elixir release (foreground)
exec /app/bin/vibe start
