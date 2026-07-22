import 'package:flutter/foundation.dart';
import 'package:grassroots_networking/grassroots_networking.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart' show Logger, Level;
import 'src/debug/log_buffer.dart';
import 'src/trace/trace_logger.dart';
import 'src/trace/trace_config.dart';
import 'src/trace/location_sampler.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:redux/redux.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'dart:async';
import 'chat_screen.dart';
import 'chat_models.dart';
import 'settings_screen.dart';
import 'theme/grasslink_theme.dart';
import 'theme/grasslink_tokens.dart';
import 'theme/grasslink_widgets.dart';

// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Global key for navigation from notification
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final Logger _log = Logger();

// Pending chat to open from notification
String? _pendingChatPeerHex;

// Global redux store
late final Store<AppState> appStore;

// Global persistence service
late final PersistenceService persistenceService;

// Global opt-in trace logger (enabled only after the user consents).
late final TraceLogger traceLogger;

// Global libsodium handle, initialized at app startup. Used by ProtocolHandler
// for native Ed25519 sign on the main isolate; verifier worker isolates
// initialize their own Sodium handles independently.
late final SodiumSumo appSodium;

Future<GrassrootsIdentity> _initIdentity() async {
  // Spec putIdentity/getIdentity (docs/GLP_Networking_API/sections/api.tex
  // §Identity): restore the persisted identity, or generate-and-persist one on
  // first launch so the same Ed25519 key pair is reused every session.
  final existing = await IdentityStore.getIdentity();
  if (existing != null) {
    debugPrint('Identity found in secure storage.');
    debugPrint('Private Key Bytes (Seed): ${existing.privateKey.length} bytes');
    debugPrint('Public Key Bytes: ${existing.publicKey.length} bytes');
    debugPrint('Nickname: ${existing.nickname}');
    return existing;
  }

  debugPrint('No identity found, generating new one.');
  final identity = await GrassrootsIdentity.generate();
  await IdentityStore.putIdentity(identity);
  debugPrint('Private Key Bytes (Seed): ${identity.privateKey.length} bytes');
  debugPrint('Public Key Bytes: ${identity.publicKey.length} bytes');
  debugPrint('Nickname: ${identity.nickname}');
  return identity;
}

Map<String, dynamic> _serializeAppState(AppState state) {
  return {
    'bleTransportState': state.transports.bleState.name,
    'udpTransportState': state.transports.udpState.name,
    'peers': {
      'discoveredBlePeers': {
        for (final e in state.peers.discoveredBlePeers.entries)
          e.key: {
            'transportId': e.value.transportId,
            'displayName': e.value.displayName,
            'rssi': e.value.rssi,
            'isConnecting': e.value.isConnecting,
            'isConnected': e.value.isConnected,
            'lastSeen': e.value.lastSeen.toIso8601String(),
          },
      },
      'peers': {
        for (final e in state.peers.peers.entries)
          e.key: {
            'nickname': e.value.nickname,
            'connectionState': e.value.connectionState.name,
            'transport': e.value.transport.name,
            'activeTransport': e.value.activeTransport.name,
            'rssi': e.value.rssi,
            'bleDeviceId': e.value.bleDeviceId,
            'udpAddress': e.value.udpAddress,
            'isFriend': e.value.isFriend,
            'lastSeen': e.value.lastSeen?.toIso8601String(),
          },
      },
    },
    'messages': {
      'conversationCount': state.messages.conversations.length,
      'unreadCounts': state.messages.unreadCounts,
      'outgoingCount': state.messages.outgoingMessages.length,
      'incomingCount': state.messages.incomingMessages.length,
    },
    'friendships': {
      for (final e in state.friendships.friendships.entries)
        e.key: {
          'nickname': e.value.nickname,
          'status': e.value.status.name,
          'udpAddress': e.value.udpAddress,
        },
    },
    'settings': state.settings.toJson(),
  };
}

/// Set up debug log capture by intercepting debugPrint.
///
/// Adds a `[HH:MM:SS.fff]` timestamp to every console line and feeds the
/// in-memory LogBuffer that drives the Debug Logs screen.
void _setupDebugLogCapture() {
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    // Prepend a wall-clock timestamp so console output is correlatable
    // across devices. The LogBuffer entry below uses its own structured
    // timestamp; only the console line gets the prefix.
    final stamped = message == null ? null : '[${_logTimestamp()}] $message';
    originalDebugPrint(stamped, wrapWidth: wrapWidth);

    // Parse the (untimestamped) log line to extract level and feed the buffer
    if (message != null && message.isNotEmpty) {
      final entry = _parseLogLine(message);
      if (entry != null) {
        LogBuffer.instance.addEntry(entry);
      }
    }
  };
}

String _logTimestamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${three(now.millisecond)}';
}

/// Parse a logger output line to extract the level and clean message.
LogEntry? _parseLogLine(String line) {
  // Strip ANSI codes
  final clean = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '').trim();
  if (clean.isEmpty) return null;

  // Skip box-drawing borders (┌ ├ └ │ alone)
  if (RegExp(r'^[┌├└─┄]+$').hasMatch(clean)) return null;

  // Skip Flutter framework noise
  if (clean.startsWith('I/flutter') ||
      clean.startsWith('D/') ||
      clean.startsWith('W/')) {
    return null;
  }

  // Detect level from emoji markers.
  // Logger package uses: ⛔=error, ⚠️=warning, 💡=info, 🐛=debug
  // App code uses: 📨📦🤝=debug (message parsing), Persisted=debug
  Level level = Level.debug;
  String message = clean;

  if (clean.contains('⛔')) {
    level = Level.error;
  } else if (clean.contains('⚠️')) {
    level = Level.warning;
  } else if (clean.contains('💡')) {
    level = Level.info;
  } else if (clean.contains('🐛') ||
      clean.contains('📨') ||
      clean.contains('📦') ||
      clean.contains('🤝')) {
    level = Level.debug;
  }

  // Strip the box-drawing prefix (│ )
  message = message.replaceFirst(RegExp(r'^│\s*'), '');

  return LogEntry(
    level: level,
    message: message,
    timestamp: DateTime.now(),
  );
}

/// Redux middleware that handles two file-system side effects:
///
/// 1. **View-once cleanup on delivery**: when an outgoing view-once picture
///    transitions to `MessageStatus.delivered`, delete the sender's local
///    copy and dispatch `MarkPictureViewedAction` to drop the path from state.
///    The recipient's copy is deleted separately when they tap to view.
///
/// 2. **Conversation deletion cleanup**: when a `DeleteConversationAction`
///    fires, snapshot the media paths in that conversation BEFORE the reducer
///    runs (the conversation is gone after `next(action)`), then delete those
///    files asynchronously.
void _mediaCleanupMiddleware(
    Store<AppState> store, dynamic action, NextDispatcher next) {
  // Snapshot before reducing — we need the conversation's media paths before
  // it disappears.
  List<String>? pathsToDeleteOnConversationDrop;
  if (action is DeleteConversationAction) {
    final conv = store.state.messages.conversations[action.peerHex];
    if (conv != null) {
      pathsToDeleteOnConversationDrop = [
        for (final m in conv)
          if (m.mediaPath != null) m.mediaPath!,
      ];
    }
  }

  next(action);

  if (pathsToDeleteOnConversationDrop != null) {
    for (final p in pathsToDeleteOnConversationDrop) {
      unawaited(deleteMediaFile(p));
    }
    return;
  }

  if (action is MessageDeliveredAction) {
    // Find the matching outgoing chat message by messageId across all
    // conversations. Pictures are infrequent; this scan is cheap relative to
    // the actual message arrival.
    final messageId = action.messageId;
    for (final entry in store.state.messages.conversations.entries) {
      final peerHex = entry.key;
      for (final msg in entry.value) {
        if (msg.messageId == messageId &&
            msg.isOutgoing &&
            msg.viewOnce &&
            msg.mediaPath != null) {
          final pathToDelete = msg.mediaPath!;
          unawaited(deleteMediaFile(pathToDelete));
          store.dispatch(MarkPictureViewedAction(
            peerHex: peerHex,
            messageId: messageId,
          ));
          return;
        }
      }
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Capture all Flutter print output (including Logger) into the debug log buffer.
  // This feeds the Debug Logs screen in Settings.
  _setupDebugLogCapture();

  // Initialize libsodium (SUMO) once for the main isolate. SUMO is required for
  // the Ed25519↔X25519 conversion used to derive/verify Noise static keys.
  // Verifier worker isolates init their own (verify-only) handles — the native
  // binary loads once per process, but each isolate needs its own FFI handle.
  appSodium = await SodiumSumoInit.init();

  // Create persistence service and load persisted state
  persistenceService = PersistenceService();
  final friendships = await persistenceService.loadFriendships();
  final settings = await persistenceService.loadSettings();
  final (conversations, unreadCounts) =
      await persistenceService.loadConversations();

  // Initialize redux store with hydrated state
  appStore = Store<AppState>(
    appReducer,
    initialState: AppState(
      friendships: friendships,
      settings: settings,
      messages: MessagesState(
        conversations: conversations,
        unreadCounts: unreadCounts,
      ),
    ),
    middleware: [_mediaCleanupMiddleware],
  );

  // Subscribe to persist changes (debounced)
  appStore.onChange.listen((state) => persistenceService.onStateChanged(state));

  // Opt-in trace logger — enabled only while the user's consent is on. Keep
  // its enabled state in sync with the (persisted) consent flag.
  traceLogger = TraceLogger(
    platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
  );
  traceLogger.setEnabled(settings.traceLoggingConsent);
  appStore.onChange.listen(
    (state) => traceLogger.setEnabled(state.settings.traceLoggingConsent),
  );

  // Initialize notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsDarwin =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsDarwin,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      // Handle notification tap - store the peer to open chat with
      if (response.payload != null) {
        _pendingChatPeerHex = response.payload;
      }
    },
  );

  // Request notification permission (Android 13+)
  await Permission.notification.request();

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreProvider<AppState>(
      store: appStore,
      child: MaterialApp(
        title: 'grasslink',
        navigatorKey: navigatorKey,
        theme: grasslinkTheme(),
        home: const GrassrootsHome(),
      ),
    );
  }
}

class GrassrootsHome extends StatefulWidget {
  const GrassrootsHome({super.key});

  @override
  State<GrassrootsHome> createState() => _GrassrootsHomeState();
}

class _GrassrootsHomeState extends State<GrassrootsHome>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  GrassrootsIdentity? _identity;
  GrassrootsNetwork? _grassroots;
  Timer? _refreshTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  int _currentIndex = 1; // Start on "Around" tab (center)

  // Track nickname changes for animation
  final Map<String, _NicknameChange> _nicknameChanges = {};

  // Transport availability derived from Redux store
  bool get _bleAvailable => appStore.state.transports.bleState.isUsable;
  bool get _udpAvailable => appStore.state.transports.udpState.isUsable;

  /// Get our UDP address for friend communication
  String? get _myUdpAddress => _grassroots?.udpAddress;

  /// Get nearby peers from Redux store (BLE-connected peers in physical proximity).
  /// For the "Nearby" section - only peers reachable via Bluetooth.
  Map<String, PeerState> get _peers {
    final peersState = appStore.state.peers;
    return {for (var p in peersState.nearbyBlePeers) p.pubkeyHex: p};
  }

  // /// Get discovered but unconnected nearby devices
  // List<DiscoveredPeerState> get _unconnectedDevices {
  //   final peersState = appStore.state.peers;
  //   // Map of currently connected device IDs
  //   final connectedDeviceIds = peersState.peersList
  //       .where((p) => p.hasBleConnection)
  //       .expand((p) => [p.bleCentralDeviceId, p.blePeripheralDeviceId])
  //       .where((id) => id != null)
  //       .toSet();

  //   return peersState.discoveredBlePeersList
  //       .where((d) =>
  //           !connectedDeviceIds.contains(d.transportId) && !d.isConnected)
  //       .toList();
  // }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Subscribe to Redux store changes - this handles all state updates
    appStore.onChange.listen((_) {
      if (mounted) setState(() {});
    });
    // Subscribe to connectivity changes
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    unawaited(Connectivity().checkConnectivity().then((r) {
      if (mounted) _connectivity = r;
    }));
    _initialize();
    // Refresh UI every second to update "seconds ago" display
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        // Check for pending chat from notification
        _checkPendingChat();
      }
    });
    // First-frame trace prompts: one-time consent, then the once-per-day upload
    // prompt (main() has no BuildContext, so these run here).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runTracePrompts());
    });
    // Periodic trace sampler (density + buffer). Foreground-only; cheap no-op
    // when trace logging is disabled.
    _traceSampleTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(_sampleTrace()));
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    debugPrint('🌐 Connectivity changed: $results');
    _connectivity = results;
  }

  void _checkPendingChat() {
    if (_pendingChatPeerHex != null &&
        _grassroots != null &&
        _identity != null) {
      final peerHex = _pendingChatPeerHex!;
      _pendingChatPeerHex = null;

      // Find the peer
      final peer = _peers.values
          .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == peerHex)
          .firstOrNull;

      if (peer != null) {
        _openChat(peer);
      }
    }
  }

  // ===== Trace logging prompts =====

  bool _tracePromptBusy = false;

  // Contact-session bookkeeping for trace 'contact' records (pubkeyHex -> ms).
  final Map<String, int> _contactStartedAt = {};
  final Map<String, int> _lastContactEndedAt = {};
  // Periodic sampler for 'density' + 'buffer' records (foreground only).
  Timer? _traceSampleTimer;
  final LocationSampler _locationSampler = LocationSampler();
  bool _locationRequested = false;

  // Device-trace state.
  final Battery _battery = Battery();
  int? _lastBatteryLevel;
  int? _lastBatteryAt;
  List<ConnectivityResult> _connectivity = const [];
  int? _backgroundedAt; // ms when the app last left the foreground

  Future<void> _ensureLocationPermission() async {
    if (_locationRequested || !traceLogger.enabled) return;
    _locationRequested = true;
    await _locationSampler.ensurePermission();
  }

  /// Log a `contact` record when a peer's consolidated reachability drops:
  /// session duration + inter-contact gap since the previous session.
  void _logContactRecord(PeerState peer) {
    if (!traceLogger.enabled) return;
    final hex = peer.pubkeyHex;
    final startedAt = _contactStartedAt.remove(hex);
    if (startedAt == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final prevEnd = _lastContactEndedAt[hex];
    _lastContactEndedAt[hex] = now;
    unawaited(traceLogger.log({
      'type': 'contact',
      't': now,
      'peer': hex,
      'startedAt': startedAt,
      'endedAt': now,
      'durationMs': now - startedAt,
      if (prevEnd != null) 'interContactMs': startedAt - prevEnd,
      if (peer.rssi != null) 'rssi': peer.rssi,
    }));
  }

  /// Periodic coarse sample of node density + buffer occupancy. Foreground-only
  /// (the timer doesn't run while backgrounded); lat/lon land in the geo stage.
  Future<void> _sampleTrace() async {
    if (!traceLogger.enabled) return;
    await _ensureLocationPermission();

    // Coarse location fix (emits 'visit' records via onVisit when leaving a
    // cell); null when unavailable / permission denied.
    final geo = await _locationSampler.sample(
      onVisit: (v) => unawaited(traceLogger.log(v)),
    );
    if (!mounted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final peers = appStore.state.peers.peers.values;
    final reachable = peers.where((p) => p.isReachable).toList();
    final rssis = reachable.map((p) => p.rssi).whereType<int>().toList();
    unawaited(traceLogger.log({
      'type': 'density',
      't': now,
      'peersConnectedNow': reachable.length,
      'friends': appStore.state.friendships.friends.length,
      if (rssis.isNotEmpty)
        'rssi': (rssis.reduce((a, b) => a + b) / rssis.length).round(),
      ...?geo,
    }));
    final g = _grassroots;
    if (g != null) {
      unawaited(traceLogger.log({
        'type': 'buffer',
        't': now,
        'event': 'sample',
        'outboundQueued': g.outboundQueuedCount,
        'dtnBuffered': g.dtnBufferedCount,
      }));
    }

    unawaited(_sampleDevice());
  }

  /// Battery + network sample -> 'device' record. Drain rate is derived from
  /// successive level samples (mAh isn't portable across platforms).
  Future<void> _sampleDevice() async {
    if (!traceLogger.enabled) return;
    int? level;
    try {
      level = await _battery.batteryLevel;
    } catch (_) {}
    final now = DateTime.now().millisecondsSinceEpoch;
    double? drainPctPerHr;
    if (level != null && _lastBatteryLevel != null && _lastBatteryAt != null) {
      final dLevel = _lastBatteryLevel! - level; // positive = drained
      final dHours = (now - _lastBatteryAt!) / 3600000.0;
      if (dHours > 0) drainPctPerHr = dLevel / dHours;
    }
    if (level != null) {
      _lastBatteryLevel = level;
      _lastBatteryAt = now;
    }
    unawaited(traceLogger.log({
      'type': 'device',
      't': now,
      if (level != null) 'batteryPct': level,
      if (drainPctPerHr != null)
        'batteryDrainPctPerHr': double.parse(drainPctPerHr.toStringAsFixed(2)),
      'lifecycleState': 'resumed', // the sampler runs only in the foreground
      'networkType': _networkTypeString(),
    }));
  }

  String _networkTypeString() {
    if (_connectivity.contains(ConnectivityResult.wifi)) return 'wifi';
    if (_connectivity.contains(ConnectivityResult.mobile)) return 'mobile';
    if (_connectivity.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (_connectivity.isEmpty ||
        _connectivity.contains(ConnectivityResult.none)) {
      return 'none';
    }
    return _connectivity.first.name;
  }

  /// One-time consent prompt, then the upload prompt — run once per app start.
  Future<void> _runTracePrompts() async {
    await _maybeConsentPrompt();
    await _maybeTraceUploadPrompt();
  }

  /// Manual "Upload now" from settings. Uploads immediately (no prompt) and
  /// returns a short user-facing status message for the caller to surface.
  Future<String> _uploadTracesNow() async {
    if (!TraceConfig.isConfigured) return 'Trace uploads are not configured';
    if (!await traceLogger.hasUnuploaded()) return 'Nothing to upload';
    final ok = await traceLogger.uploadAll(
      url: TraceConfig.serverUrl,
      token: TraceConfig.serverToken,
    );
    return ok ? 'Traces uploaded' : 'Trace upload failed';
  }

  /// Ask once, ever, whether the user opts in to trace logging + upload.
  Future<void> _maybeConsentPrompt() async {
    // consentTimestamp is non-null once the user has answered (grant or decline).
    if (appStore.state.settings.consentTimestamp != null) return;
    if (!mounted) return;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Help improve the network?'),
        content: const Text(
          'You can opt in to collect anonymous diagnostic traces '
          '(connectivity, message timing, coarse location) on this device. '
          'Nothing is sent automatically — once a day the app will ask before '
          'uploading to your configured research server. You can turn this off '
          'any time in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No thanks'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Opt in'),
          ),
        ],
      ),
    );

    appStore.dispatch(SetTraceLoggingConsentAction(
      accepted == true,
      consentTimestamp: DateTime.now().toUtc().toIso8601String(),
    ));

    if (accepted == true) {
      // Enable + request location now (don't wait for the store listener), so
      // the OS location prompt follows the consent dialog immediately.
      traceLogger.setEnabled(true);
      _locationRequested = true;
      unawaited(_locationSampler.ensurePermission());
    }
  }

  /// On every app start, offer to upload any traces not yet uploaded since the
  /// last successful upload. Fires only when the user has opted in, a
  /// destination is baked in, and there is actually something pending.
  Future<void> _maybeTraceUploadPrompt() async {
    if (_tracePromptBusy) return;
    final settings = appStore.state.settings;
    if (!settings.traceLoggingConsent) return;

    // Destination is baked in (not user-configurable). A build shipped without
    // a token stays inert.
    if (!TraceConfig.isConfigured) return;

    if (!await traceLogger.hasUnuploaded()) return;
    if (!mounted) return;

    _tracePromptBusy = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Upload diagnostic traces?'),
          content: const Text(
            'Upload the diagnostic traces collected on this device to your '
            'research server?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Upload'),
            ),
          ],
        ),
      );

      if (accepted == true) {
        final ok = await traceLogger.uploadAll(
          url: TraceConfig.serverUrl,
          token: TraceConfig.serverToken,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok ? 'Traces uploaded' : 'Trace upload failed'),
            duration: const Duration(seconds: 2),
          ));
        }
      }
    } finally {
      _tracePromptBusy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _refreshTimer?.cancel();
    _traceSampleTimer?.cancel();
    _grassroots?.dispose();
    // Flush persistence on exit
    persistenceService.flush(appStore.state);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('[lifecycle] App state -> $state');
    final now = DateTime.now().millisecondsSinceEpoch;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= now;
    }
    if (state == AppLifecycleState.resumed) {
      final bgMs = _backgroundedAt != null ? now - _backgroundedAt! : null;
      _backgroundedAt = null;
      if (traceLogger.enabled) {
        unawaited(traceLogger.log({
          'type': 'device',
          't': now,
          'lifecycleState': 'resumed',
          if (bgMs != null) 'bgDurationMs': bgMs,
          // OS-throttle proxy: a long background gap suggests the OS suspended
          // us (true Doze / App-Standby needs native APIs we don't have).
          if (bgMs != null) 'osThrottled': bgMs > 60000,
        }));
      }
      unawaited(_grassroots?.onAppResumed() ?? Future.value());
    }
  }

  Future<void> _initialize() async {
    try {
      final identity = await _initIdentity();

      final grassroots = GrassrootsNetwork(
        identity: identity,
        store: appStore,
        sodium: appSodium,
        trace: traceLogger,
      );

      grassroots.onMessageReceived =
          (messageId, senderPubkey, payload, transport) {
        _handleIncomingMessage(messageId, senderPubkey, payload, transport);
      };

      // Trace: a contact session begins/ends (consolidated reachability edges).
      grassroots.onPeerConnected = (peer) {
        if (traceLogger.enabled) {
          _contactStartedAt[peer.pubkeyHex] =
              DateTime.now().millisecondsSinceEpoch;
        }
      };
      grassroots.onPeerDisconnected = _logContactRecord;

      // Friend presence is handled at the transport layer; no app-layer
      // callback needed for UDP initialization.

      // grassroots.onPeerConnected = (peer) {
      //   print('Peer connected: ${peer.displayName}');
      //   // PeerStore already has the peer - just track nickname changes
      // };

      // grassroots.onPeerUpdated = (peer) {
      //   print('Peer updated: ${peer.displayName}');

      //   // Check if nickname changed - use peerStore to get the previous state
      //   // Note: Since peerStore already updated, we track changes via the _nicknameChanges map
      //   // The peer object passed here is from peerStore, so we can't compare old/new directly
      //   // This callback is mainly for nickname change animations
      // };

      // grassroots.onPeerDisconnected = (peer) {
      //   print('Peer disconnected: ${peer.displayName}');
      //   // PeerStore already updated - UI will refresh via _onPeersChanged
      // };

      setState(() {
        _identity = identity;
        _grassroots = grassroots;
      });

      final success = await grassroots.initialize();
      if (!success) {
        debugPrint('Grassroots initialization failed');
        return;
      }

      // Hydrate Redux store with existing friends from FriendshipStore
      await _hydrateFriendsFromStore();
    } catch (e) {
      debugPrint('Initialization error: $e');
    }
  }

  /// Hydrate Redux store with friends from persistent FriendshipStore
  Future<void> _hydrateFriendsFromStore() async {
    for (final friendship in appStore.state.friendships.friends) {
      final pubkey = ChatMessage.hexToPubkey(friendship.peerPubkeyHex);

      // Establish friendship in Redux
      appStore.dispatch(FriendEstablishedAction(
        publicKey: pubkey,
        nickname: friendship.nickname,
      ));

      // If friend has UDP info, associate it
      if (friendship.udpAddress != null && friendship.udpAddress!.isNotEmpty) {
        appStore.dispatch(AssociateUdpAddressAction(
          publicKey: pubkey,
          address: friendship.udpAddress!,
        ));
      }
    }
  }

  // Friend presence is handled at the transport layer via unified ANNOUNCE
  // messages. BLE and UDP broadcasts include address for friends automatically.

  Future<void> _handleIncomingMessage(String messageId, Uint8List senderPubkey,
      Uint8List payload, MessageTransport transport) async {
    final senderHex = ChatMessage.pubkeyToHex(senderPubkey);
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    final block = Block.tryDeserialize(payload);

    if (block != null) {
      await _handleBlock(
          block, senderHex, myHex, messageId, senderPubkey, transport);
    } else {
      debugPrint(
          '📨 Failed to parse block (${payload.length} bytes from $senderHex) - dropping');
    }
  }

  Future<void> _handleBlock(
      Block block,
      String senderHex,
      String myHex,
      String messageId,
      Uint8List senderPubkey,
      MessageTransport transport) async {
    // Find sender name
    final peer = _peers.values
        .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == senderHex)
        .firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';
    final transportName = transport == MessageTransport.udp ? 'UDX' : 'BLE';

    switch (block.type) {
      case BlockType.say:
        final sayBlock = block as SayBlock;
        if (sayBlock is TextSayBlock) {
          debugPrint(
              '💬 [$transportName] Message from $senderName: "${sayBlock.content}"');
          await _handleTextMessage(
              senderHex, myHex, sayBlock.content, messageId, senderPubkey);
        } else if (sayBlock is PictureSayBlock) {
          debugPrint(
              '📷 [$transportName] Picture from $senderName (${sayBlock.imageBytes.length} bytes, viewOnce=${sayBlock.viewOnce})');
          await _handlePictureMessage(
              senderHex, myHex, sayBlock, messageId, senderPubkey);
        }

      case BlockType.friendshipOffer:
        debugPrint(
            'Hansdling FriendshipOfferBlock from $senderName ($senderHex)');
        final offerBlock = block as FriendshipOfferBlock;
        await _handleFriendshipOffer(senderHex, myHex, offerBlock, senderName);

      case BlockType.friendshipAccept:
        debugPrint(
            'Handling FriendshipAcceptBlock from $senderName ($senderHex)');
        final acceptBlock = block as FriendshipAcceptBlock;
        await _handleFriendshipAccept(
            senderHex, myHex, acceptBlock, senderName);

      case BlockType.friendshipRevoke:
        debugPrint(
            'Handling FriendshipRevokeBlock from $senderName ($senderHex)');
        await _handleFriendshipRevoke(senderHex);
    }
  }

  Future<void> _handleTextMessage(String senderHex, String myHex,
      String content, String messageId, Uint8List senderPubkey) async {
    // Save message to Redux store
    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      content: content,
      isOutgoing: false,
      messageId: messageId,
    ));
    // Read receipt sent when user opens the chat (see ChatScreen._sendReadReceipts)

    // Find sender name
    final peer = _peers.values
        .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == senderHex)
        .firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';

    // Show notification
    await _showMessageNotification(senderHex, senderName, content);
  }

  Future<void> _handlePictureMessage(String senderHex, String myHex,
      PictureSayBlock block, String messageId, Uint8List senderPubkey) async {
    // Persist the image bytes to disk under a SHA-256-named file. dedupes
    // identical images naturally.
    final file = await writeMediaFile(block.imageBytes, block.mime);

    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      // No caption support in v1; keep content empty so chat-list previews
      // can still render a short subtitle.
      content: '',
      isOutgoing: false,
      messageId: messageId,
      messageType: ChatMessageType.picture.index,
      mediaPath: file.path,
      mediaMime: block.mime,
      viewOnce: block.viewOnce,
    ));

    final peer = _peers.values
        .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == senderHex)
        .firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';
    await _showMessageNotification(
      senderHex,
      senderName,
      block.viewOnce ? '🔥 Sent a 1-time photo' : '📷 Sent a photo',
    );
  }

  Future<void> _handleFriendshipOffer(
    String senderHex,
    String myHex,
    FriendshipOfferBlock block,
    String senderName,
  ) async {
    // Record the friend request
    appStore.dispatch(ReceiveFriendRequestAction(
      peerPubkeyHex: senderHex,
      nickname: senderName,
      message: block.message,
    ));

    // Get the updated friendship state
    final friendship = appStore.state.friendships.getFriendship(senderHex);
    final pubkey = ChatMessage.hexToPubkey(senderHex);

    // If auto-accepted (mutual friend requests), establish friendship in Redux
    if (friendship != null && friendship.isAccepted) {
      appStore.dispatch(FriendEstablishedAction(
        publicKey: pubkey,
        nickname: senderName,
      ));
    }

    // Save as a chat message
    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      content: block.message ?? 'Wants to be friends',
      isOutgoing: false,
      messageType: ChatMessageType.friendRequestReceived.index,
    ));

    // Show notification if friendship is new
    if (friendship?.status == FriendshipStatus.received) {
      await _showFriendRequestNotification(senderHex, senderName);
    }

    // UDP connection will be established when ANNOUNCE is received
  }

  Future<void> _handleFriendshipAccept(
    String senderHex,
    String myHex,
    FriendshipAcceptBlock block,
    String senderName,
  ) async {
    debugPrint('🤝 _handleFriendshipAccept from $senderName ($senderHex)');

    // Update friendship status
    appStore.dispatch(ProcessFriendshipAcceptAction(
      peerPubkeyHex: senderHex,
      nickname: senderName,
    ));
    debugPrint('🤝 Friendship status updated');

    // Establish friendship in Redux store
    final pubkey = ChatMessage.hexToPubkey(senderHex);
    appStore.dispatch(FriendEstablishedAction(
      publicKey: pubkey,
      nickname: senderName,
    ));

    // Save as a chat message
    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      content: 'Accepted your friend request',
      isOutgoing: false,
      messageType: ChatMessageType.friendRequestAccepted.index,
    ));
    debugPrint('🤝 Chat message saved');

    // UDP connection will be established when ANNOUNCE is received
  }

  /// Handle being unfriended by someone
  Future<void> _handleFriendshipRevoke(String senderHex) async {
    // Silently remove them from our friend list (Redux handles both friendships and peers)
    appStore.dispatch(HandleUnfriendedByAction(senderHex));
    final pubkey = ChatMessage.hexToPubkey(senderHex);
    appStore.dispatch(FriendRemovedAction(pubkey));

    // We don't show any notification to the user - they will just
    // notice the person is no longer in their friends list
  }

  /// Unfriend someone - removes them from our list and notifies them
  Future<void> _unfriend(String peerHex) async {
    if (_grassroots == null) return;

    final pubkey = ChatMessage.hexToPubkey(peerHex);

    // Send the revoke message so they remove us too
    final block = FriendshipRevokeBlock();
    await _grassroots!.send(pubkey, block.serialize());

    // Remove from our friend list (Redux handles both friendships and peers)
    appStore.dispatch(RemoveFriendshipAction(peerHex));
    appStore.dispatch(FriendRemovedAction(pubkey));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Removed from friends'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _showMessageNotification(
      String senderHex, String senderName, String content) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'grassroots_messages',
      'Messages',
      channelDescription: 'New messages carried to you over the mesh',
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      senderHex.hashCode,
      'Message from $senderName',
      content.length > 50 ? '${content.substring(0, 50)}...' : content,
      notificationDetails,
      payload: senderHex,
    );
  }

  Future<void> _showFriendRequestNotification(
      String senderHex, String senderName) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'grassroots_friend_requests',
      'Friend requests',
      channelDescription: 'Friend requests from peers on the mesh',
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      'friend_$senderHex'.hashCode,
      'Friend Request from $senderName',
      '$senderName wants to be friends with you',
      notificationDetails,
      payload: senderHex,
    );
  }

  void _openChat(PeerState peer) {
    final peerHex = peer.pubkeyHex;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          peer: peer,
          grassroots: _grassroots!,
          myPubkey: _identity!.publicKey,
          store: appStore,
          onSendFriendRequest: () => _sendFriendRequest(peer),
          onAcceptFriendRequest: () => _acceptFriendRequest(peer),
          onUnfriend: () => _unfriend(peerHex),
          myUdpAddress: _myUdpAddress,
        ),
      ),
    );
  }

  Future<void> _sendFriendRequest(PeerState peer) async {
    if (_grassroots == null || _identity == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot send friend request'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final peerHex = peer.pubkeyHex;
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    // Create the friendship offer block
    final block = FriendshipOfferBlock(
      message: 'Hey, let\'s be friends!',
    );

    // Send via Grassroots
    final messageId =
        await _grassroots!.send(peer.publicKey, block.serialize());
    if (messageId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Failed to send friend request to ${peer.displayName}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Create and record the friend request in Redux
    appStore.dispatch(CreateFriendRequestAction(
      peerPubkeyHex: peerHex,
      nickname: peer.displayName,
    ));

    // Save as a chat message in Redux
    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: myHex,
      recipientPubkeyHex: peerHex,
      content: 'Sent a friend request',
      isOutgoing: true,
      messageId: messageId,
      messageType: ChatMessageType.friendRequestSent.index,
    ));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Friend request sent to ${peer.displayName}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _acceptFriendRequest(PeerState peer) async {
    if (_grassroots == null || _identity == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot accept friend request'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final peerHex = peer.pubkeyHex;
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    // Accept the friend request in Redux
    appStore.dispatch(AcceptFriendRequestAction(peerHex));

    // Establish friendship in Redux
    appStore.dispatch(FriendEstablishedAction(
      publicKey: peer.publicKey,
      nickname: peer.displayName,
    ));

    // Create the friendship accept block
    final block = FriendshipAcceptBlock();

    // Send via Grassroots (works over BLE)
    final messageId =
        await _grassroots!.send(peer.publicKey, block.serialize());
    if (messageId == null) {
      debugPrint('⚠️ Failed to send friendship accept to ${peer.displayName}');
    }

    // Save as a chat message in Redux
    appStore.dispatch(SaveChatMessageAction(
      senderPubkeyHex: myHex,
      recipientPubkeyHex: peerHex,
      content: 'You accepted the friend request',
      isOutgoing: true,
      messageType: ChatMessageType.friendRequestAcceptedByUs.index,
    ));

    // UDP connection will be established when ANNOUNCE is received
  }

  Future<void> _declineFriendRequest(String peerHex) async {
    appStore.dispatch(DeclineFriendRequestAction(peerHex));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request declined'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatSecondsAgo(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) {
      return '${seconds}s ago';
    } else if (seconds < 3600) {
      return '${seconds ~/ 60}m ago';
    } else {
      return '${seconds ~/ 3600}h ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _buildChatsTab(),
            _buildAroundTab(),
            _buildProfileTab(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: const BoxDecoration(
        color: GlColors.surfaceCard,
        border: Border(top: BorderSide(color: GlColors.borderSubtle)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: GlSpace.s4, vertical: GlSpace.s2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(
                icon: Icons.forum_outlined,
                label: 'Threads',
                index: 0,
                badge: _getTotalUnreadCount(),
              ),
              _buildNavItem(
                icon: Icons.cell_tower_rounded,
                label: 'Nearby',
                index: 1,
              ),
              _buildNavItem(
                icon: Icons.person_outline_rounded,
                label: 'You',
                index: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
    int badge = 0,
  }) {
    final isSelected = _currentIndex == index;
    final color = isSelected ? GlColors.primaryOnSoft : GlColors.textSubtle;

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: GlMotion.normal,
        curve: GlMotion.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? GlSpace.s4 : GlSpace.s3,
          vertical: GlSpace.s2,
        ),
        decoration: BoxDecoration(
          color: isSelected ? GlColors.primarySoft : Colors.transparent,
          borderRadius: GlRadius.rPill,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: color, size: 24),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(GlSpace.s1),
                      decoration: const BoxDecoration(
                        color: GlColors.accent,
                        shape: BoxShape.circle,
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        badge > 99 ? '99+' : badge.toString(),
                        style: const TextStyle(
                          color: GlColors.textOnPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: GlSpace.s1),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: GlType.textXs,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _getTotalUnreadCount() {
    return appStore.state.messages.totalUnreadCount;
  }

  // ===== CHATS TAB =====
  Widget _buildChatsTab() {
    final chatsWithMessages = _getChatsWithMessages();
    final pendingRequests = appStore.state.friendships.pendingIncoming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(GlSpace.s4),
          child: Text('Threads', style: GlType.displayStyle(GlType.text2xl)),
        ),
        // Pending friend requests section
        if (pendingRequests.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: GlSpace.s4),
            child: Row(
              children: [
                const Icon(Icons.person_add_alt_rounded,
                    size: 16, color: GlColors.accent),
                const SizedBox(width: GlSpace.s2),
                EyebrowLabel(
                  'Friend requests · ${pendingRequests.length}',
                  color: GlColors.accentOnSoft,
                ),
              ],
            ),
          ),
          const SizedBox(height: GlSpace.s2),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: GlSpace.s3),
              itemCount: pendingRequests.length,
              itemBuilder: (context, index) {
                final request = pendingRequests[index];
                return _buildFriendRequestCard(request);
              },
            ),
          ),
          const Divider(height: GlSpace.s5),
        ],
        Expanded(
          child: chatsWithMessages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SignalDot(size: 20),
                      const SizedBox(height: GlSpace.s5),
                      Text(
                        'No threads yet',
                        style: GlType.displayStyle(GlType.textLg,
                            weight: FontWeight.w700),
                      ),
                      const SizedBox(height: GlSpace.s2),
                      const Text(
                        'Say hello to someone nearby —\nyour neighbours will carry it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GlColors.textMuted),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: chatsWithMessages.length,
                  itemBuilder: (context, index) {
                    final chat = chatsWithMessages[index];
                    return _buildChatListItem(chat);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFriendRequestCard(FriendshipState request) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: GlSpace.s1),
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(GlSpace.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PeerAvatar(name: request.displayName, size: 32),
                const SizedBox(width: GlSpace.s2),
                Expanded(
                  child: Text(
                    request.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: GlColors.textStrong),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => _declineFriendRequest(request.peerPubkeyHex),
                  style: TextButton.styleFrom(
                    foregroundColor: GlColors.textMuted,
                    padding: const EdgeInsets.symmetric(horizontal: GlSpace.s2),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Decline'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    // Find peer to accept
                    var peer = _peers.values
                        .where((p) =>
                            ChatMessage.pubkeyToHex(p.publicKey) ==
                            request.peerPubkeyHex)
                        .firstOrNull;

                    if (peer != null) {
                      await _acceptFriendRequest(peer);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GlColors.accent,
                    padding:
                        const EdgeInsets.symmetric(horizontal: GlSpace.s3),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<_ChatPreview> _getChatsWithMessages() {
    final chats = <_ChatPreview>[];

    // Walk every conversation that has messages — friends, BT peers, UDP-only
    // peers, or any peer we've ever exchanged a message with. The keys are
    // Ed25519 pubkey hexes, so a peer who is BOTH a friend and a BT peer
    // appears once.
    final messagesState = appStore.state.messages;
    final peersMap = appStore.state.peers.peers;
    final friendshipsState = appStore.state.friendships;

    for (final peerHex in messagesState.conversationPeers) {
      final messages = messagesState.getConversation(peerHex);
      if (messages.isEmpty) continue;

      final lastMessage = messages.last;
      // Prefer the full peer record (carries connection state + nickname),
      // fall back to the friendship record for offline friends so the chat
      // list shows the right name even when the peer isn't currently seen.
      final peer = peersMap[peerHex];
      final friendship = friendshipsState.getFriendship(peerHex);

      chats.add(_ChatPreview(
        peerHex: peerHex,
        peer: peer,
        friendship: friendship,
        lastMessage: lastMessage,
        unreadCount: messagesState.getUnreadCount(peerHex),
      ));
    }

    // Sort by last message time (newest first)
    chats.sort(
        (a, b) => b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp));
    return chats;
  }

  Widget _buildChatListItem(_ChatPreview chat) {
    final displayName = chat.displayName;
    final isFriend = chat.isFriend;
    final isOnline = chat.peer?.isReachable ?? false;

    return Dismissible(
      key: ValueKey('chat-${chat.peerHex}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: GlColors.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: GlSpace.s5),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline_rounded, color: GlColors.textOnPrimary),
            SizedBox(width: GlSpace.s2),
            Text(
              'Delete',
              style: TextStyle(
                  color: GlColors.textOnPrimary, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmDeleteChat(chat),
      onDismissed: (_) {
        appStore.dispatch(DeleteConversationAction(chat.peerHex));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted chat with $displayName'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      child: ListTile(
        leading: PeerAvatar(
          name: displayName,
          size: 44,
          presence: isOnline ? PeerPresence.online : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(displayName, overflow: TextOverflow.ellipsis),
                  ),
                  if (isFriend) ...[
                    const SizedBox(width: GlSpace.s1),
                    const Icon(Icons.spa_rounded,
                        size: 14, color: GlColors.primary),
                  ],
                ],
              ),
            ),
            if (chat.unreadCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: GlSpace.s2, vertical: 2),
                decoration: const BoxDecoration(
                  color: GlColors.accent,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  chat.unreadCount.toString(),
                  style: const TextStyle(
                      color: GlColors.textOnPrimary,
                      fontSize: GlType.textXs,
                      fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
        subtitle: Text(
          _chatPreviewText(chat.lastMessage),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: chat.unreadCount > 0
                ? GlColors.textStrong
                : GlColors.textMuted,
            fontWeight:
                chat.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        trailing: Text(
          _formatMessageTime(chat.lastMessage.timestamp),
          style: const TextStyle(
              color: GlColors.textSubtle, fontSize: GlType.textXs),
        ),
        onTap: () {
          // Live peer wins; otherwise synthesize a stub from the friendship so
          // the chat opens for offline friends. ChatScreen + grassroots.send
          // only need the pubkey + nickname; if no transport is live, the send
          // path queues messages until a connection resumes.
          final peer = chat.peer ?? _stubPeerFromChatPreview(chat);
          if (peer != null) {
            _openChat(peer);
          }
        },
      ),
    );
  }

  /// Confirm chat deletion. Returns true if the user accepted; the dispatch
  /// happens in `onDismissed` so the snackbar fires after the list animates.
  Future<bool> _confirmDeleteChat(_ChatPreview chat) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete this thread?'),
        content: Text(
          'Delete the whole thread with ${chat.displayName}? '
          'Messages and any photos in it will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: GlColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  /// Build a synthetic [PeerState] for opening a chat from the chat list when
  /// no live peer record exists (e.g. an offline friend on app startup).
  /// Returns null only when neither a peer record nor a friendship is on file
  /// — in that case there's nothing to talk to.
  PeerState? _stubPeerFromChatPreview(_ChatPreview chat) {
    final friendship = chat.friendship;
    if (friendship == null) return null;
    return PeerState(
      publicKey: _hexStringToBytes(chat.peerHex),
      nickname: friendship.nickname ?? '',
      isFriend: friendship.isAccepted,
      udpAddress: friendship.udpAddress,
    );
  }

  /// One-line preview text for the chat list. Substitutes a short label for
  /// picture messages instead of trying to show the empty `content` field.
  String _chatPreviewText(ChatMessageState m) {
    if (m.messageType == ChatMessageType.picture) {
      if (m.viewOnce) return 'One-time photo';
      return 'Photo';
    }
    return m.content;
  }

  /// Decode a 64-char hex pubkey into 32 bytes.
  Uint8List _hexStringToBytes(String hex) {
    return Uint8List.fromList(
      List.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }

  String _formatMessageTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.day}/${time.month}';
  }

  // ===== AROUND TAB =====
  Widget _buildAroundTab() {
    final onlineFriends = appStore.state.peers.onlineFriends;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(GlSpace.s4),
          child: Row(
            children: [
              const GrasslinkWordmark(size: GlType.text2xl),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.search_rounded),
                onPressed: _showPeerLookupDialog,
                tooltip: 'Find a peer by public key',
              ),
            ],
          ),
        ),
        // Mesh status pill — projection of transport health from Redux.
        StoreConnector<AppState, AppState>(
          converter: (store) => store.state,
          builder: (context, state) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: GlSpace.s4),
              padding: const EdgeInsets.symmetric(
                  horizontal: GlSpace.s3, vertical: GlSpace.s2),
              decoration: BoxDecoration(
                color: state.isHealthy
                    ? GlColors.successSoft
                    : GlColors.warningSoft,
                borderRadius: GlRadius.rPill,
              ),
              child: Row(
                children: [
                  SignalMeter(strength: state.isHealthy ? 4 : 1),
                  const SizedBox(width: GlSpace.s2),
                  Text(
                    state.statusDisplayString,
                    style: TextStyle(
                      fontSize: GlType.textSm,
                      fontWeight: FontWeight.w600,
                      color: state.isHealthy
                          ? GlColors.moss700
                          : GlColors.amber500,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_peers.length} nearby · ${onlineFriends.length} friends',
                    style: const TextStyle(
                        fontSize: GlType.textXs, color: GlColors.textMuted),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: GlSpace.s4),

        // Online friends section
        if (onlineFriends.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: GlSpace.s4),
            child: EyebrowLabel('Friends online'),
          ),
          const SizedBox(height: GlSpace.s2),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: GlSpace.s3),
              itemCount: onlineFriends.length,
              itemBuilder: (context, index) {
                final friend = onlineFriends[index];
                return _buildOnlineFriendChip(friend);
              },
            ),
          ),
          const Divider(height: GlSpace.s5),
        ],

        // Nearby peers section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: GlSpace.s4),
          child: EyebrowLabel('Nearby · ${_peers.length}'),
        ),
        const SizedBox(height: GlSpace.s2),

        Expanded(
          child: (_peers.isEmpty)
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SignalDot(size: 20),
                      const SizedBox(height: GlSpace.s5),
                      Text(
                        'No one nearby yet',
                        style: GlType.displayStyle(GlType.textLg,
                            weight: FontWeight.w700),
                      ),
                      const SizedBox(height: GlSpace.s2),
                      const Text(
                        'Keep Bluetooth on — peers appear\nas they come into range.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GlColors.textMuted),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    if (_peers.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: GlSpace.s4, vertical: GlSpace.s2),
                        child: EyebrowLabel('In range'),
                      ),
                      ...(_peers.values.toList()
                            ..sort((a, b) =>
                                (b.rssi ?? -100).compareTo(a.rssi ?? -100)))
                          .map((peer) => _buildPeerListItem(peer)),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildOnlineFriendChip(PeerState friend) {
    return GestureDetector(
      onTap: () {
        _openChat(friend);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: GlSpace.s1),
        padding: const EdgeInsets.all(GlSpace.s3),
        decoration: BoxDecoration(
          color: GlColors.surfaceCard,
          borderRadius: GlRadius.rLg,
          border: Border.all(color: GlColors.borderSubtle),
          boxShadow: GlShadows.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PeerAvatar(
              name: friend.displayName,
              size: 40,
              presence: PeerPresence.online,
            ),
            const SizedBox(height: GlSpace.s1),
            Text(
              friend.displayName,
              style: const TextStyle(
                  fontSize: GlType.textXs, color: GlColors.textBody),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerListItem(PeerState peer) {
    final peerHex = peer.pubkeyHex;
    final unreadCount = appStore.state.messages.getUnreadCount(peerHex);
    final friendship = appStore.state.friendships.getFriendship(peerHex);
    final isFriend = friendship?.isAccepted ?? false;
    final hasPendingRequest =
        appStore.state.friendships.hasPendingRequest(peerHex);

    // RSSI is unavailable for some peripheral-role BLE links because the OS
    // does not expose remote signal strength to the GATT server side.
    final rssiDbm = peer.rssi;

    // Check if this peer has a recent nickname change
    final nicknameChange = _nicknameChanges[peerHex];
    final isChanging = nicknameChange != null;

    return Card(
      child: AnimatedContainer(
        duration: GlMotion.slow,
        curve: GlMotion.easeOut,
        decoration: BoxDecoration(
          borderRadius: GlRadius.rLg,
          border: isChanging
              ? Border.all(color: GlColors.focusRing, width: 2)
              : null,
        ),
        child: ListTile(
          leading: Stack(
            children: [
              PeerAvatar(
                name: peer.displayName,
                size: 44,
                presence: isFriend ? PeerPresence.online : null,
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: GlColors.accent,
                      shape: BoxShape.circle,
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      unreadCount > 99 ? '99+' : unreadCount.toString(),
                      style: const TextStyle(
                          color: GlColors.textOnPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: GlMotion.slow,
                  switchInCurve: GlMotion.easeOut,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Row(
                    key: ValueKey(peer.displayName),
                    children: [
                      Flexible(
                        child: Text(
                          peer.displayName,
                          style: TextStyle(
                            color: isChanging ? GlColors.accent : null,
                            fontWeight: isChanging
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isFriend) ...[
                        const SizedBox(width: GlSpace.s1),
                        const Icon(Icons.spa_rounded,
                            size: 14, color: GlColors.primary),
                      ],
                    ],
                  ),
                ),
              ),
              peer.activeTransport.icon,
            ],
          ),
          subtitle: Text(
            peer.lastBleSeen != null
                ? 'Heard ${_formatSecondsAgo(peer.lastBleSeen!)}'
                : 'Reaching out…',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SignalMeter.fromRssi(rssiDbm),
                  Text(
                    rssiDbm == null ? '-- dBm' : '$rssiDbm dBm',
                    style: GlType.monoStyle(10, color: GlColors.textSubtle),
                  ),
                ],
              ),
              const SizedBox(width: GlSpace.s2),
              // Friend request / Chat button
              if (!isFriend && !hasPendingRequest)
                IconButton(
                  icon: const Icon(Icons.person_add_alt_rounded),
                  color: GlColors.accent,
                  tooltip: 'Send a friend request',
                  onPressed: () => _sendFriendRequest(peer),
                )
              else if (hasPendingRequest)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.hourglass_empty_rounded,
                      color: GlColors.textSubtle, size: 20),
                ),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                color: GlColors.primary,
                onPressed: () => _openChat(peer),
              ),
            ],
          ),
          onTap: () => _openChat(peer),
        ),
      ),
    );
  }

  void _showPeerLookupDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Find a peer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste a public key to see whether the mesh can reach them:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: GlSpace.s4),
            TextField(
              controller: controller,
              style: GlType.monoStyle(GlType.textSm),
              decoration: const InputDecoration(
                hintText: 'Public key (64 hex chars)',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _lookupPeer(controller.text.trim());
            },
            child: const Text('Look up'),
          ),
        ],
      ),
    );
  }

  void _lookupPeer(String hexPubkey) {
    if (hexPubkey.isEmpty || _grassroots == null) return;

    try {
      // Convert hex to bytes
      final pubkeyBytes = Uint8List.fromList(
        List.generate(
          hexPubkey.length ~/ 2,
          (i) => int.parse(hexPubkey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );

      final isReachable = _grassroots!.isPeerReachable(pubkeyBytes);
      final peer = _grassroots!.getPeer(pubkeyBytes);

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(
                isReachable
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                color: isReachable ? GlColors.success : GlColors.danger,
              ),
              const SizedBox(width: GlSpace.s2),
              Expanded(
                child: Text(isReachable
                    ? 'The mesh can reach them'
                    : 'Out of reach right now'),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (peer != null) ...[
                Text('Name: ${peer.displayName}'),
                Text('Status: ${peer.connectionState.name}'),
                if (peer.rssi != null) Text('Signal: ${peer.rssi} dBm'),
                if (peer.lastSeen != null)
                  Text('Heard ${_formatSecondsAgo(peer.lastSeen!)}'),
              ] else
                const Text('No one by that key has been seen yet.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
            if (peer != null)
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openChat(peer);
                },
                child: const Text('Open thread'),
              ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid public key format: $e')),
      );
    }
  }

  // ===== YOU TAB =====
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(GlSpace.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('You', style: GlType.displayStyle(GlType.text2xl)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettings,
                tooltip: 'Settings',
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s5),

          // Avatar
          Center(
            child: PeerAvatar(name: _identity?.nickname ?? '', size: 100),
          ),
          const SizedBox(height: GlSpace.s4),

          // Nickname with edit button
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _identity?.nickname ?? 'Loading…',
                  style: GlType.displayStyle(GlType.textXl),
                ),
                const SizedBox(width: GlSpace.s2),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: _showEditNicknameDialog,
                  tooltip: 'Change your name',
                ),
              ],
            ),
          ),
          const SizedBox(height: GlSpace.s6),

          // Info cards
          _buildInfoCard(
            title: 'Fingerprint',
            value: _identity?.shortFingerprint ?? '…',
            icon: Icons.fingerprint_rounded,
            onCopy: () => _copyToClipboard(_identity?.shortFingerprint ?? ''),
          ),
          const SizedBox(height: GlSpace.s3),

          _buildInfoCard(
            title: 'Service UUID',
            value: _identity?.bleServiceUuid ?? '…',
            icon: Icons.bluetooth_rounded,
            onCopy: () => _copyToClipboard(_identity?.bleServiceUuid ?? ''),
          ),
          const SizedBox(height: GlSpace.s3),

          _buildInfoCard(
            title: 'Public key',
            value: _identity != null
                ? ChatMessage.pubkeyToHex(_identity!.publicKey)
                : '…',
            icon: Icons.key_rounded,
            onCopy: () => _copyToClipboard(_identity != null
                ? ChatMessage.pubkeyToHex(_identity!.publicKey)
                : ''),
            maxLines: 2,
          ),
          const SizedBox(height: GlSpace.s3),

          // Regenerate identity (dev/testing affordance).
          // Re-rolls the Ed25519 keypair so peers treat this install as a new
          // device without requiring uninstall + reinstall.
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Regenerate identity'),
            style: OutlinedButton.styleFrom(
              foregroundColor: GlColors.danger,
              side: const BorderSide(color: GlColors.danger, width: 1.5),
              minimumSize: const Size.fromHeight(44),
            ),
            onPressed: _identity == null ? null : _regenerateIdentity,
          ),
          const SizedBox(height: GlSpace.s3),

          // Transport status card
          _buildTransportStatusCard(),
          const SizedBox(height: 12),

          // Invite / cold-bootstrap card
          _buildInviteCard(),
          const SizedBox(height: 12),

          // Settings shortcut card
          _buildSettingsCard(),
        ],
      ),
    );
  }

  Widget _buildInviteCard() {
    final canInvite = _grassroots?.canCreateInvite ?? false;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(GlSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                SignalDot(size: 12),
                SizedBox(width: GlSpace.s2),
                Text(
                  'Invites',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: GlColors.textStrong),
                ),
              ],
            ),
            const SizedBox(height: GlSpace.s2),
            Text(
              canInvite
                  ? 'Bring someone new onto the mesh — a willing well-connected '
                      'friend passes the first hello along.'
                  : 'To invite someone new, you need a well-connected friend '
                      'online who has offered to introduce newcomers.',
              style: const TextStyle(
                  color: GlColors.textMuted, fontSize: GlType.textSm),
            ),
            const SizedBox(height: GlSpace.s3),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                    label: const Text('Create invite'),
                    onPressed: canInvite ? _createInviteLink : null,
                  ),
                ),
                const SizedBox(width: GlSpace.s3),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: const Text('Redeem'),
                    onPressed:
                        _grassroots == null ? null : _showRedeemInviteDialog,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _createInviteLink() {
    final grassroots = _grassroots;
    if (grassroots == null) return;
    final candidates = grassroots.invitableIntroducers;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No willing well-connected friend is online to introduce you'),
        ),
      );
      return;
    }
    // Pick which willing friends to name as introducers (default: all).
    final selected = {for (final p in candidates) p.pubkeyHex};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Who can introduce you?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These well-connected friends have offered to help newcomers '
                'reach you. Pick who can pass this invite along.',
                style: TextStyle(
                    color: GlColors.textMuted, fontSize: GlType.textSm),
              ),
              const SizedBox(height: GlSpace.s2),
              ...candidates.map((p) => CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: selected.contains(p.pubkeyHex),
                    onChanged: (v) => setDialogState(() {
                      if (v == true) {
                        selected.add(p.pubkeyHex);
                      } else {
                        selected.remove(p.pubkeyHex);
                      }
                    }),
                    secondary: PeerAvatar(name: p.displayName, size: 36),
                    title: Text(p.displayName),
                  )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _generateAndShowInvite(introducerHexes: selected);
                    },
              child: const Text('Create link'),
            ),
          ],
        ),
      ),
    );
  }

  void _generateAndShowInvite({required Set<String> introducerHexes}) {
    final link = _grassroots?.createInvite(introducerPubkeyHexes: introducerHexes);
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No willing introducer is available'),
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share this invite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send this link to someone new. It works for 24 hours and can '
              'be redeemed once.',
            ),
            const SizedBox(height: GlSpace.s3),
            Container(
              padding: const EdgeInsets.all(GlSpace.s3),
              decoration: BoxDecoration(
                color: GlColors.bgSunken,
                borderRadius: GlRadius.rSm,
              ),
              child: SelectableText(
                link,
                style: GlType.monoStyle(GlType.textXs),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy link'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite link copied')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showRedeemInviteDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Redeem an invite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste an invite link a friend sent you. A well-connected '
              'neighbour will help you reach them.',
            ),
            const SizedBox(height: GlSpace.s3),
            TextField(
              controller: controller,
              minLines: 2,
              maxLines: 4,
              style: GlType.monoStyle(GlType.textXs),
              decoration: const InputDecoration(
                hintText: 'grassroots://invite?d=…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final link = controller.text.trim();
              Navigator.pop(ctx);
              if (link.isNotEmpty) _redeemInviteLink(link);
            },
            child: const Text('Reach out'),
          ),
        ],
      ),
    );
  }

  Future<void> _redeemInviteLink(String link) async {
    final grassroots = _grassroots;
    if (grassroots == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Reaching out through the mesh…')),
    );
    final result = await grassroots.redeemInvite(link);
    if (!mounted) return;
    if (result.ok) {
      final peer = result.inviter == null
          ? null
          : grassroots.getPeer(result.inviter!);
      messenger.showSnackBar(
        SnackBar(
          content: Text(peer != null
              ? 'Connected to ${peer.displayName}'
              : 'Connected — say hello!'),
        ),
      );
      if (peer != null) _openChat(peer);
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'Could not redeem the invite')),
      );
    }
  }

  Widget _buildTransportStatusCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(GlSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StoreConnector<AppState, bool>(
                  converter: (store) => store.state.isHealthy,
                  builder: (context, isHealthy) => SignalMeter(
                    strength: isHealthy ? 4 : 1,
                  ),
                ),
                const SizedBox(width: GlSpace.s2),
                const Text(
                  'Your links',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: GlColors.textStrong),
                ),
              ],
            ),
            const SizedBox(height: GlSpace.s3),

            // BLE status
            _buildTransportStatusRow(
              icon: Icons.bluetooth_rounded,
              name: 'Bluetooth',
              enabled: appStore.state.settings.bluetoothEnabled,
              available: _bleAvailable,
            ),
            const SizedBox(height: GlSpace.s2),

            // UDP status
            _buildTransportStatusRow(
              icon: Icons.public_rounded,
              name: 'Internet',
              enabled: appStore.state.settings.udpEnabled,
              available: _udpAvailable,
            ),

            const Divider(height: GlSpace.s5),

            Text(
              '${_peers.length} peers in reach',
              style: const TextStyle(color: GlColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransportStatusRow({
    required IconData icon,
    required String name,
    required bool enabled,
    required bool available,
  }) {
    final isActive = enabled && available;
    final badgeColor = isActive
        ? GlColors.success
        : (enabled ? GlColors.warning : GlColors.textSubtle);
    final badgeBg = isActive
        ? GlColors.successSoft
        : (enabled ? GlColors.warningSoft : GlColors.bgSunken);

    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: isActive ? GlColors.primary : GlColors.textSubtle,
        ),
        const SizedBox(width: GlSpace.s2),
        Expanded(
          child: Text(
            name,
            style: TextStyle(
              color: isActive ? GlColors.textBody : GlColors.textMuted,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: GlSpace.s2, vertical: 2),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: GlRadius.rPill,
          ),
          child: Text(
            isActive ? 'Carrying' : (enabled ? 'Out of reach' : 'Off'),
            style: TextStyle(
              fontSize: GlType.text2xs,
              fontWeight: FontWeight.w600,
              color: badgeColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.settings_outlined, color: GlColors.accent),
        title: const Text('Settings'),
        subtitle: const Text('Bluetooth, Internet, and how you lend your link'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _openSettings,
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          store: appStore,
          onSettingsChanged: () {
            setState(() {});
          },
          onBleRoleModeChanged: _grassroots == null
              ? null
              : (mode) => _grassroots!.setBleRoleMode(mode),
          onRetryPublicAddressDiscovery: _grassroots == null
              ? null
              : () => _grassroots!.retryPublicAddressDiscovery(),
          onUploadTracesNow: _uploadTracesNow,
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String value,
    required IconData icon,
    VoidCallback? onCopy,
    int maxLines = 1,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(GlSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: GlColors.textMuted),
                const SizedBox(width: GlSpace.s2),
                EyebrowLabel(title),
                const Spacer(),
                if (onCopy != null)
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: onCopy,
                    tooltip: 'Copy',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: GlSpace.s1),
            Text(
              value,
              style: GlType.monoStyle(GlType.textSm),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  void _showEditNicknameDialog() {
    if (_identity == null) return;

    final controller = TextEditingController(text: _identity!.nickname);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change your name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'What should neighbours call you?',
          ),
          autofocus: true,
          maxLength: 30,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newNickname = controller.text.trim();
              if (newNickname.isNotEmpty && _grassroots != null) {
                Navigator.pop(context);
                await _updateNickname(newNickname);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateNickname(String newNickname) async {
    if (_grassroots == null || _identity == null) return;

    // Update nickname via Grassroots (broadcasts ANNOUNCE)
    await _grassroots!.updateNickname(newNickname);

    // Persist to secure storage
    await IdentityStore.putIdentity(_identity!);

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nickname updated!')),
    );
  }

  /// Generate a brand-new Ed25519 keypair and restart Grassroots under the new
  /// identity. Useful for testing discovery and identity reset behavior
  /// without an uninstall+reinstall cycle.
  Future<void> _regenerateIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate Identity?'),
        content: const Text(
          'This generates a fresh Ed25519 keypair and rebuilds the Grassroots '
          'transport under the new identity. Your peers will see you as a '
          'new device — existing friendships, discovered peers and BLE '
          'connection state are dropped.\n\n'
          'Useful for testing identity reset behavior without uninstall + '
          'reinstall.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: GlColors.danger,
              foregroundColor: GlColors.textOnPrimary,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // Tear down the current Grassroots instance before swapping identities.
    // dispose() stops advertising, closes GATT, cancels timers, and flushes
    // streams — without this we'd run two transports concurrently with
    // overlapping characteristic UUIDs, which gets confusing fast.
    final oldGrassroots = _grassroots;
    setState(() {
      _grassroots = null;
      _identity = null;
    });
    await oldGrassroots?.dispose();

    // Fresh keypair (same shape as _initIdentity for a clean install).
    final newIdentity = await GrassrootsIdentity.generate();

    // Persist immediately so a crash mid-restart doesn't leave us with a
    // stored identity that doesn't match anything in memory.
    await IdentityStore.putIdentity(newIdentity);

    // Rebuild the transport with the new identity (mirrors _initialize).
    final newGrassroots = GrassrootsNetwork(
      identity: newIdentity,
      store: appStore,
      sodium: appSodium,
      trace: traceLogger,
    );
    newGrassroots.onMessageReceived =
        (messageId, senderPubkey, payload, transport) {
      _handleIncomingMessage(messageId, senderPubkey, payload, transport);
    };

    if (!mounted) return;
    setState(() {
      _identity = newIdentity;
      _grassroots = newGrassroots;
    });

    final ok = await newGrassroots.initialize();
    if (!ok) {
      debugPrint('Grassroots re-initialization failed after identity regen');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Identity regenerated, but the mesh failed to start'),
            backgroundColor: GlColors.danger,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('New identity: ${newIdentity.nickname} '
            '(${newIdentity.shortFingerprint})'),
      ),
    );
  }

  void _showNicknameChangeAnimation(
      String oldName, String newName, String peerId) {
    // Store the nickname change for UI animation
    _nicknameChanges[peerId] = _NicknameChange(
      oldName: oldName,
      newName: newName,
      timestamp: DateTime.now(),
    );

    // Show a snackbar notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.person_rounded, color: GlColors.textInverse),
            const SizedBox(width: GlSpace.s3),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontFamily: GlType.sans, color: GlColors.textInverse),
                  children: [
                    TextSpan(
                      text: oldName.isEmpty ? 'Unknown' : oldName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.lineThrough,
                        color: GlColors.textInverse.withValues(alpha: 0.7),
                      ),
                    ),
                    const TextSpan(text: ' → '),
                    TextSpan(
                      text: newName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );

    // Clear the animation after a delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _nicknameChanges.remove(peerId);
        });
      }
    });
  }
}

/// Helper class for tracking nickname changes
class _NicknameChange {
  final String oldName;
  final String newName;
  final DateTime timestamp;

  _NicknameChange({
    required this.oldName,
    required this.newName,
    required this.timestamp,
  });
}

/// Helper class for chat list preview
class _ChatPreview {
  final String peerHex;

  /// Full peer record, when one exists. Null for an offline friend whose
  /// `PeerState` hasn't been re-hydrated yet (e.g. fresh app start, no live
  /// connection, but the conversation history is loaded from disk).
  final PeerState? peer;

  /// Friendship record, when this peer is on our friends list. Used as the
  /// nickname source when [peer] is null.
  final FriendshipState? friendship;

  final ChatMessageState lastMessage;
  final int unreadCount;

  _ChatPreview({
    required this.peerHex,
    required this.peer,
    required this.friendship,
    required this.lastMessage,
    required this.unreadCount,
  });

  /// Display name from peer (live), then friendship (offline friend),
  /// then a truncated pubkey as last resort.
  String get displayName {
    if (peer != null && peer!.displayName.isNotEmpty) return peer!.displayName;
    final fNick = friendship?.nickname;
    if (fNick != null && fNick.isNotEmpty) return fNick;
    return 'Peer ${peerHex.substring(0, 8)}...';
  }

  bool get isFriend => friendship?.isAccepted ?? false;
}
