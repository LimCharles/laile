# Build from the repo root so the shared LaileCore package is in the context:
#   docker build -f Server/Dockerfile -t laile-server .
FROM swift:6.1-noble AS build
WORKDIR /build
COPY Packages/LaileCore Packages/LaileCore
COPY Server/Package.swift Server/Package.resolved Server/
RUN cd Server && swift package resolve
COPY Server Server
RUN cd Server && swift build -c release --static-swift-stdlib \
    && mkdir /staging \
    && cp "$(swift build -c release --show-bin-path)/LaileServer" /staging/ \
    && cp -R Public Resources /staging/

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --user-group --create-home --home-dir /app vapor
WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
USER vapor
ENV SQLITE_PATH=/app/data/laile.sqlite \
    VOICE_CACHE_DIR=/app/data/voice-cache
RUN mkdir -p /app/data
EXPOSE 8080
ENTRYPOINT ["./LaileServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
