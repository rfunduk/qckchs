FROM docker.io/debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl ca-certificates make gcc clang libc6-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Odin compiler
ARG ODIN_VERSION=dev-2026-03
RUN curl -sL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
    | tar -xzf - -C /opt --strip-components=1 && \
    ln -s /opt/odin /usr/local/bin/odin

WORKDIR /qckchs

# Vendor deps layer — only rebuilds when setup script or lib bindings change
COPY bin/codegen bin/codegen
COPY bin/build bin/build
COPY bin/setup bin/setup
RUN bin/setup

# Data files needed at build time (#load in Odin) and runtime
COPY mimir.nnue mimir.nnue
COPY egtb/ egtb/

# Source + build
COPY lib/ lib/
COPY src/ src/
COPY templates/ templates/
COPY static/ static/
RUN bin/build release --static


# ---------------------------------------------------------------------------
FROM scratch

ENV TMPDIR=/app
WORKDIR /app

COPY --from=build /qckchs/build/release/qckchs       /app/qckchs
COPY --from=build /qckchs/build/release/static/      /app/static/
COPY --from=build /qckchs/build/release/mimir.nnue   /app/mimir.nnue
COPY --from=build /qckchs/build/release/egtb/        /app/egtb/

CMD ["./qckchs"]
