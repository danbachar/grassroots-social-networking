/// Baked-in trace-upload destination.
///
/// The diagnostic trace uploader posts to this endpoint with a bearer token
/// whenever the user has opted in to trace logging. The destination is NOT
/// user-facing and NOT modifiable at runtime — it is fixed per build.
///
/// The token is a **secret** and is injected at build time via `--dart-define`,
/// never committed to source. The URL is not secret and carries a sensible
/// default that a build may override the same way:
///
///   flutter build apk --release \
///     --dart-define=TRACE_TOKEN=<token> \
///     --dart-define=TRACE_URL=https://trace-upload.example.com
///
/// Uploads are gated on [isConfigured]: while [serverToken] is empty the app
/// never attempts a POST, so a build shipped without the token define stays
/// inert.
class TraceConfig {
  TraceConfig._();

  /// Base URL of the trace-upload server. Overridable with
  /// `--dart-define=TRACE_URL=...`.
  static const String serverUrl = String.fromEnvironment(
    'TRACE_URL',
    defaultValue: 'https://trace-upload.bachar.co',
  );

  /// Bearer token, injected with `--dart-define=TRACE_TOKEN=...`. Empty by
  /// default and never committed — a build without the define stays inert.
  static const String serverToken = String.fromEnvironment('TRACE_TOKEN');

  /// Whether a real destination is baked in. Uploads are skipped unless this is
  /// true, so a token-less build never posts to the server.
  static bool get isConfigured => serverUrl.isNotEmpty && serverToken.isNotEmpty;
}
