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

# Runtime dependencies + yt-dlp for music extraction
RUN apk add --no-cache libstdc++ openssl ncurses-libs python3 py3-pip ffmpeg curl \
  && pip3 install --break-system-packages yt-dlp \
  && yt-dlp --version

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy the Elixir release
COPY --from=elixir-build --chown=nobody:root /app/_build/prod/rel/vibe ./

# Copy startup script
COPY --chmod=755 start.sh /app/start.sh

USER nobody

# Expose port (Railway sets PORT env var)
EXPOSE 4000

CMD ["/app/start.sh"]
