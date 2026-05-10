# Build from within the bootstrap_anchor directory; dart-udx must be copied
# into the build context first because it normally lives one directory up.
# See build.sh and deploy.sh for the full flow.

FROM dart:stable AS build

WORKDIR /app

COPY dart-udx/ /app/dart-udx/
COPY pubspec.yaml .
RUN sed -i 's|path: ../dart-udx|path: /app/dart-udx|' pubspec.yaml
RUN dart pub get

COPY lib/ lib/
COPY bin/ bin/

RUN dart compile exe bin/server.dart -o bin/rendezvous_server

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/rendezvous_server /app/rendezvous_server

VOLUME /app/data
EXPOSE 9514/udp
EXPOSE 9516/udp

ENTRYPOINT ["/app/rendezvous_server"]
CMD ["--identity", "/app/data/identity.json", "--ipv6-port", "9516"]
