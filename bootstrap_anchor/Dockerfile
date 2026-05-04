# Build stage
FROM dart:stable AS build

WORKDIR /app

# Build context is the repo root (bitchat_transport/), so dart-udx is a
# sibling of bootstrap_anchor/ inside the context.

# Copy dart_udx dependency first (for caching)
COPY dart-udx /app/dart-udx

# Copy pubspec and get dependencies
COPY bootstrap_anchor/pubspec.yaml .
# Fix dart_udx path for Docker context
RUN sed -i 's|path: ../dart-udx|path: /app/dart-udx|' pubspec.yaml
RUN dart pub get

# Copy source
COPY bootstrap_anchor/lib/ lib/
COPY bootstrap_anchor/bin/ bin/

# Compile to native executable
RUN dart compile exe bin/server.dart -o bin/rendezvous_server

# Runtime stage — minimal image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/bin/rendezvous_server /app/rendezvous_server

# Identity file persisted via volume mount
VOLUME /app/data

EXPOSE 9514/udp
EXPOSE 9516/udp

ENTRYPOINT ["/app/rendezvous_server"]
CMD ["--identity", "/app/data/identity.json", "--ipv6-port", "9516"]
