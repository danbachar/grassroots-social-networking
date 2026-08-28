FROM dart:3.5 AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY bin ./bin
RUN dart pub get --offline && dart compile exe bin/responder.dart -o /app/responder

FROM debian:bookworm-slim
COPY --from=build /app/responder /usr/local/bin/responder
ENTRYPOINT ["/usr/local/bin/responder"]
