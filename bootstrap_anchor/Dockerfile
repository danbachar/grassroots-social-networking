# Build stage
FROM dart:stable AS build

WORKDIR /app

# Copy dart_udx dependency first (for caching)
COPY ../dart-udx /app/dart-udx

# Copy pubspec and get dependencies
COPY pubspec.yaml .
# Fix dart_udx path for Docker context
RUN sed -i 's|path: ../dart-udx|path: /app/dart-udx|' pubspec.yaml
RUN dart pub get

# Copy source
COPY lib/ lib/
COPY bin/ bin/

# Compile to native executable
RUN dart compile exe bin/server.dart -o bin/bootstrap_anchor

# Runtime stage — minimal image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/bin/bootstrap_anchor /app/bootstrap_anchor

# Friends list persisted via volume mount (restart recovery only)
VOLUME /app/data

EXPOSE 9514/udp

ENTRYPOINT ["/app/bootstrap_anchor"]
# Replace ANCHOR_SEED_HEX and OWNER_PUBKEY_HEX at deploy time.
# The seed is derived from the owner's key: SHA-256(ownerSeed || "bitchat-anchor")
CMD ["--port", "9514", "--nickname", "anchor", "--seed", "ANCHOR_SEED_HEX", "--friends", "/app/data/friends.json", "--owner", "OWNER_PUBKEY_HEX"]
