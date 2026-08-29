# Build Docker. ONE image, TWO entrypoints: /bin/continuous-control (the game server,
# which makes every decision including the LLM call) and /bin/continuous-control-player
# (the thin seat registrar). The whole policy set is env-switched inside this
# same image (PLAYER_PROMPT vs PLAYER_SCRIPTED=trotter|plodder), which is what
# keeps a champion and a scripted filler byte-identical apart from their
# environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/cc
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/continuous_control.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/continuous-control-nimcache \
  --out:continuous-control \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/continuous-control-player-nimcache \
  --out:continuous-control-player \
  src/continuous_control_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/cc
COPY --from=build /workspace/cc/continuous-control /bin/continuous-control
COPY --from=build /workspace/cc/continuous-control-player /bin/continuous-control-player
COPY --from=build /workspace/cc/*.json ./
COPY --from=build /workspace/cc/data ./data
COPY --from=build /workspace/cc/client ./client

CMD ["/bin/continuous-control"]
