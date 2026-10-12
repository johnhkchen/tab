# Tab's extraction service: one pinned BAML Language binary plus baml_src/.
# Keep BAML_VERSION in step with mise.toml.

FROM debian:trixie-slim AS fetch
ARG BAML_VERSION=0.21.0
ARG TARGETARCH
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /baml
RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) triple=x86_64-unknown-linux-gnu ;; \
    arm64) triple=aarch64-unknown-linux-gnu ;; \
    *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  base="https://github.com/BoundaryML/baml/releases/download/baml-language-${BAML_VERSION}"; \
  file="baml-language-${BAML_VERSION}-${triple}.tar.gz"; \
  curl -fsSLO "$base/$file"; \
  curl -fsSL "$base/$file.sha256" | awk '{print $1"  '"$file"'"}' | sha256sum -c -; \
  tar -xzf "$file" && rm "$file"

FROM debian:trixie-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /baml /opt/baml
ENV PATH="/opt/baml/bin:${PATH}" \
    BAML_CLI_ALLOW_DIRECT=1 \
    BAML_AGENT_SKILL_CHECK=off \
    DO_NOT_TRACK=1 \
    BAML_TELEMETRY=off \
    PORT=4100
WORKDIR /app
COPY baml.toml ./
COPY baml_src baml_src
USER nobody
EXPOSE 4100
CMD ["baml-cli", "run", "main"]
