# ===========================================
# Vibegram Backend — Elixir + Python sidecar
# ===========================================

FROM hexpm/elixir:1.15.7-erlang-26.2.1-alpine-3.18.4 AS elixir-build

# Install build dependencies
RUN apk add --no-cache build-base git

WORKDIR /app

# Install hex + rebar
RUN for i in 1 2 3 4 5; do \
  mix local.hex --force && mix local.rebar --force && break || sleep 5; \
  done

ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy compile-time config
COPY config/ config/

# Compile source
COPY lib/ lib/
COPY priv/ priv/

RUN mix compile

# Runtime config
COPY config/runtime.exs config/

# Build release
RUN mix release

# ===========================================
# Runtime stage
# ===========================================
FROM alpine:3.18

# Runtime dependencies + yt-dlp (SoundCloud/YouTube) + Python doc renderer stack
RUN apk add --no-cache libstdc++ openssl ncurses-libs python3 py3-pip ffmpeg curl \
  pango cairo gdk-pixbuf font-noto font-noto-arabic font-noto-extra \
  && pip3 install --break-system-packages \
       "yt-dlp>=2024.1.0" \
       flask==3.1.* \
       waitress==3.0.* \
       weasyprint==63.* \
       openpyxl==3.1.* \
       pypdfium2==4.* \
  && YT_BIN=$(command -v yt-dlp || true) \
  && if [ -z "$YT_BIN" ]; then YT_BIN=$(python3 -c "import shutil; print(shutil.which('yt-dlp') or '')"); fi \
  && if [ -n "$YT_BIN" ]; then ln -sf "$YT_BIN" /usr/local/bin/yt-dlp; fi \
  && ln -sf /usr/bin/python3 /usr/local/bin/python3 \
  && /usr/local/bin/yt-dlp --version \
  && python3 -m yt_dlp --version

WORKDIR /app
RUN chown nobody /app && mkdir -p /tmp/.cache && chown nobody /tmp/.cache

ENV MIX_ENV="prod"
ENV FONTCONFIG_PATH=/etc/fonts
ENV XDG_CACHE_HOME=/tmp/.cache
ENV PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"
ENV YTDLP_PATH="/usr/local/bin/yt-dlp"

# Copy the Elixir release
COPY --from=elixir-build --chown=nobody:root /app/_build/prod/rel/vibe ./

# Copy Python doc renderer
COPY --chown=nobody:root priv/python/ /app/python/

# Copy startup script
COPY --chmod=755 start.sh /app/start.sh

USER nobody

EXPOSE 4000

CMD ["/app/start.sh"]
