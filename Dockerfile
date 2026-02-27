# ===========================================
# Multi-stage build for Vibe (Elixir Backend + React Client)
# ===========================================

# Stage 2: Build Elixir Release
FROM hexpm/elixir:1.15.7-erlang-26.2.1-alpine-3.18.4 AS elixir-build

# Install build dependencies
RUN apk add --no-cache build-base git

WORKDIR /app

# Install hex + rebar (with retry for transient failures)
RUN for i in 1 2 3 4 5; do \
  mix local.hex --force && mix local.rebar --force && break || sleep 5; \
  done

# Set build ENV
ENV MIX_ENV="prod"

# Install mix dependencies
COPY server/mix.exs ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy compile-time config files
COPY server/config/ config/

# Compile the release
COPY server/lib/ lib/
COPY server/priv/ priv/

# Compile the project
RUN mix compile

# Copy runtime config
COPY server/config/runtime.exs config/

# Build release
RUN mix release

# Stage 3: Runtime
FROM alpine:3.18

# Runtime dependencies + yt-dlp for music extraction + doc renderer
RUN apk add --no-cache libstdc++ openssl ncurses-libs python3 py3-pip ffmpeg curl \
  pango cairo gdk-pixbuf font-noto font-noto-arabic font-noto-extra \
  && pip3 install --break-system-packages yt-dlp flask==3.1.* waitress==3.0.* weasyprint==63.* openpyxl==3.1.* \
  && yt-dlp --version

WORKDIR /app
RUN chown nobody /app && mkdir -p /tmp/.cache && chown nobody /tmp/.cache

# Set runner ENV
ENV MIX_ENV="prod"
ENV FONTCONFIG_PATH=/etc/fonts
ENV XDG_CACHE_HOME=/tmp/.cache

# Copy the Elixir release
COPY --from=elixir-build --chown=nobody:root /app/_build/prod/rel/vibe ./

# Copy Python doc renderer
COPY --chown=nobody:root server/priv/python/ /app/python/

# Copy startup script
COPY --chmod=755 start.sh /app/start.sh

USER nobody

# Expose port (Railway sets PORT env var)
EXPOSE 4000

CMD ["/app/start.sh"]
