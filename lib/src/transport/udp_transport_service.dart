import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:redux/redux.dart';
import 'package:dart_udx/dart_udx.dart';

import '../transport/transport_service.dart';
import '../transport/address_utils.dart';
import '../models/identity.dart';
import '../protocol/protocol_handler.dart';
import '../store/store.dart';

/// Display info for UDP transport
const _defaultUdpDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'Direct UDP peer-to-peer transport',
  color: Colors.green,
);

/// UDP transport service using dart_udx for reliable streams over UDP.
///
/// Uses Bitchat's Ed25519 identity directly. Addressing uses simple
/// ip:port strings.
///
/// ## Lifecycle
///
/// Two-phase initialization to support hole-punching:
///
/// 1. [initialize] — Binds a `RawDatagramSocket`. At this point the raw socket
///    is available for hole-punch packets via [rawSocket].
///
/// 2. [startMultiplexer] — Creates `UDXMultiplexer` on the same socket.
///    After this, all incoming UDP reads go through UDX. Stray non-UDX packets
///    (e.g. residual punch packets) are silently dropped.
///
/// For well-connected peers (no hole-punch needed), both phases happen immediately.
/// For NATed peers, phase 2 happens after hole-punch succeeds.
///
/// ## Connection Identity
///
/// The first message on any new UDX stream MUST be a BitchatPacket of type ANNOUNCE.
/// This allows the receiver to map the UDX connection to a Bitchat public key.
/// (Future: Noise XX handshake will replace this.)
///
/// ## No Store-and-Forward
///
/// Messages to unreachable peers fail immediately. No caching, no relaying.
class UdpTransportService extends TransportService {
  /// Our Bitchat identity (Ed25519 keypair)
  final BitchatIdentity identity;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol handler for encoding/decoding
  final ProtocolHandler protocolHandler;

  // --- Socket and UDX state ---

  /// The raw UDP socket. We own it — UDX wraps it but doesn't create it.
  RawDatagramSocket? _rawSocket;

  /// UDX factory instance
  UDX? _udx;

  /// Multiplexer: routes incoming UDP packets to UDX connections by Connection ID.
  /// Created in [startMultiplexer], null until then.
  UDXMultiplexer? _multiplexer;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Our bound local port (available after [initialize])
  int? _localPort;

  // --- Peer connections ---

  /// Active UDX connections per peer, keyed by pubkey hex.
  final Map<String, _PeerConnection> _peerConnections = {};

  // Stream IDs: each UDPSocket (connection) has its own ID space.
  // We use stream ID 1 for our outgoing stream on every connection.
  // The remote peer also uses stream ID 1 for theirs.
  // Since stream IDs are scoped to a UDPSocket, there's no collision.
  static const int _outgoingStreamId = 1;
  static const int _expectedIncomingStreamId = 1;

  // --- Stream controllers ---

  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // --- Subscriptions ---

  StreamSubscription? _multiplexerConnectionsSub;

  // --- Public callbacks ---

  /// Called when data is received from a UDP peer.
  /// The coordinator deserializes as BitchatPacket and routes via MessageRouter.
  void Function(String pubkeyHex, Uint8List data)? onUdpDataReceived;

  UdpTransportService({
    required this.identity,
    required this.store,
    required this.protocolHandler,
  });

  // ===== Public Getters =====

  /// The raw UDP socket — exposed for hole-punch service to send punch packets.
  /// Only use for raw sends; DO NOT read from this after [startMultiplexer].
  RawDatagramSocket? get rawSocket => _rawSocket;

  /// Our bound port (available after [initialize])
  int? get localPort => _localPort;

  /// Our local address as ip:port string, or null if not bound.
  String? get localAddress {
    if (_rawSocket == null) return null;
    return _localAddress;
  }

  /// Cached local LAN address (ip:port). Resolved once at initialization.
  String? _localAddress;

  /// Whether the UDX multiplexer is active (accepting streams)
  bool get isMultiplexerActive => _multiplexer != null;

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.udp;
  @override
  TransportDisplayInfo get displayInfo => _defaultUdpDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => _peerConnections.length;

  @override
  bool get isActive => _state == TransportState.active;

  // ===== Lifecycle =====

  /// Phase 1: Bind the raw UDP socket.
  ///
  /// After this call:
  /// - [rawSocket] is available for sending hole-punch packets
  /// - [localPort] is known
  /// - The multiplexer is NOT yet created (call [startMultiplexer] for that)
  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      debugPrint('UDP transport already initialized');
      return _state.isUsable;
    }

    _setState(TransportState.initializing);
    debugPrint('Initializing UDP transport');

    try {
      // Bind to all IPv6 interfaces, random port.
      // Bitchat only advertises and dials IPv6 UDP addresses.
      _rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
      _localPort = _rawSocket!.port;
      _udx = UDX();

      // Resolve actual LAN IP so we share a routable address, not [::].
      _localAddress = await _resolveLocalAddress(_localPort!);

      _setState(TransportState.ready);
      debugPrint(
          'UDP transport bound on port $_localPort (local: $_localAddress)');
      return true;
    } catch (e) {
      debugPrint('Failed to bind UDP socket: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  /// Phase 2: Create UDX multiplexer on the bound socket.
  ///
  /// After this call:
  /// - All incoming UDP reads go through UDX
  /// - DO NOT read from [rawSocket] directly (multiplexer owns reads)
  /// - You CAN still send raw bytes via [rawSocket.send()] (for punch packets)
  /// - Incoming non-UDX packets are silently dropped
  ///
  /// Call this:
  /// - Immediately after [initialize] if well-connected (no NAT)
  /// - After hole-punch succeeds if behind NAT
  void startMultiplexer() {
    if (_multiplexer != null) {
      debugPrint('Multiplexer already started');
      return;
    }
    if (_rawSocket == null) {
      debugPrint(
          'Cannot start multiplexer: socket not bound. Call initialize() first.');
      return;
    }

    _multiplexer = UDXMultiplexer(_rawSocket!);

    // Handle non-UDX packets (raw UDP fallback for when UDX handshake fails)
    _multiplexer!.onRawPacket = _handleRawPacket;

    // Listen for incoming connections from remote peers
    _multiplexerConnectionsSub =
        _multiplexer!.connections.listen(_handleIncomingConnection);

    _setState(TransportState.active);
    debugPrint('UDX multiplexer started on port $_localPort');
  }

  @override
  Future<void> start() async {
    // For compatibility with TransportService interface.
    // If multiplexer isn't started yet, start it now.
    if (_multiplexer == null && _rawSocket != null) {
      startMultiplexer();
    } else if (_state == TransportState.ready) {
      _setState(TransportState.active);
    }
  }

  @override
  Future<void> stop() async {
    debugPrint('Stopping UDP transport');

    // Close all peer connections (copy keys to avoid concurrent modification)
    final peerKeys = _peerConnections.keys.toList();
    for (final key in peerKeys) {
      final conn = _peerConnections.remove(key);
      try {
        await conn?.stream?.close();
      } catch (e) {
        debugPrint('Error closing stream for $key: $e');
      }
    }

    // Cancel multiplexer subscription
    await _multiplexerConnectionsSub?.cancel();
    _multiplexerConnectionsSub = null;

    // Clear connection tracking maps
    _tempKeyToPubkey.clear();
    _addressToPubkey.clear();
    _pendingIncoming.clear();

    // We don't close the raw socket here — it might be reused.
    // The multiplexer is discarded; a new one can be created.
    _multiplexer = null;

    if (_state == TransportState.active) {
      _setState(TransportState.ready);
    }
    debugPrint('UDP transport stopped');
  }

  @override
  Future<void> dispose() async {
    debugPrint('Disposing UDP transport');
    await stop();

    // Close the raw socket
    _rawSocket?.close();
    _rawSocket = null;
    _udx = null;
    _localPort = null;
    _localAddress = null;

    _state = TransportState.disposed;

    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
  }

  // ===== Connections =====

  /// Connect to a peer at a known ip:port.
  ///
  /// Creates a UDX connection (UDPSocket) and stream to the peer.
  /// The first message sent MUST be an ANNOUNCE packet (caller's responsibility).
  ///
  /// Returns true if the connection was established.
  /// Timeout for UDX handshake completion.
  static const Duration _handshakeTimeout = Duration(seconds: 10);

  Future<bool> connectToPeer(
      String pubkeyHex, InternetAddress addr, int port) async {
    if (_multiplexer == null) {
      debugPrint(
          'Cannot connect: multiplexer not started. Call startMultiplexer() first.');
      return false;
    }

    if (_peerConnections.containsKey(pubkeyHex)) {
      debugPrint('Already connected to $pubkeyHex');
      return true;
    }

    UDPSocket? udpSocket;
    try {
      final remoteHost = addr.address;

      // Store address → pubkey mapping so incoming connections from this
      // address can be immediately associated with the correct peer.
      _addressToPubkey['$remoteHost:$port'] = pubkeyHex;

      // Create UDX connection to the peer
      udpSocket = _multiplexer!.createSocket(_udx!, remoteHost, port);

      // Create outgoing stream. Stream IDs are scoped per UDPSocket (connection),
      // so we always use ID 1. Remote peer also uses ID 1 for their stream.
      final stream = await UDXStream.createOutgoing(
        _udx!,
        udpSocket,
        _outgoingStreamId,
        _expectedIncomingStreamId,
        remoteHost,
        port,
      );

      // Wait for UDX handshake to complete, with timeout.
      // Without this timeout, the await hangs forever if the remote is
      // unreachable (firewall, wrong address), leaking UDX sockets and
      // preventing the auto-connect from ever succeeding.
      await udpSocket.handshakeComplete.timeout(
        _handshakeTimeout,
        onTimeout: () {
          throw TimeoutException(
            'UDX handshake timed out after ${_handshakeTimeout.inSeconds}s',
          );
        },
      );

      // Store the connection
      _peerConnections[pubkeyHex] = _PeerConnection(
        pubkeyHex: pubkeyHex,
        udpSocket: udpSocket,
        stream: stream,
        addr: addr,
        port: port,
      );

      // Listen for data on the outgoing stream (receives paired incoming data)
      _listenToStream(pubkeyHex, stream);

      // Also listen for additional incoming streams on this UDPSocket.
      // In a simultaneous open, the remote peer might send data on our
      // connection rather than creating their own.
      udpSocket.on('stream').listen((UDXEvent event) {
        final incomingStream = event.data as UDXStream;
        if (incomingStream != stream) {
          debugPrint(
              'Incoming stream ${incomingStream.id} on outgoing connection to $pubkeyHex');
          _listenToStream(pubkeyHex, incomingStream);
        }
      });
      udpSocket.flushStreamBuffer();

      debugPrint('Connected to peer $pubkeyHex at $remoteHost:$port');

      _connectionController.add(TransportConnectionEvent(
        peerId: pubkeyHex,
        transport: TransportType.udp,
        connected: true,
      ));

      return true;
    } catch (e) {
      debugPrint('Failed to connect to peer $pubkeyHex: $e');

      // Clean up the UDX socket on failure to prevent resource leaks.
      // Without this, each failed attempt leaves a dangling socket in the
      // multiplexer that never gets garbage collected.
      if (udpSocket != null) {
        try {
          await udpSocket.close();
        } catch (_) {}
      }
      // Remove stale address mapping
      _addressToPubkey.remove('${addr.address}:$port');

      return false;
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    final conn = _peerConnections[peerId];
    if (conn == null || conn.stream == null) {
      debugPrint('Cannot send to $peerId: not connected');
      return false;
    }

    try {
      await conn.stream!.add(data);
      debugPrint('Sent ${data.length} bytes to peer $peerId');
      return true;
    } catch (e) {
      debugPrint('Failed to send to peer $peerId: $e');
      return false;
    }
  }

  // ===== Raw UDP fallback (bypasses UDX) =====

  /// Peers we communicate with via raw UDP (when UDX handshake fails).
  /// Key: pubkeyHex, Value: target address info.
  final Map<String, AddressInfo> _rawPeerAddresses = {};

  /// Send data via raw UDP to a peer, bypassing UDX entirely.
  ///
  /// Use this when UDX connectToPeer fails (e.g. hairpin routing on same LAN).
  /// No reliability — packets may be lost, duplicated, or reordered.
  /// The application layer handles retries via ACKs.
  bool sendRawTo(
      String pubkeyHex, InternetAddress ip, int port, Uint8List data) {
    if (_rawSocket == null) return false;
    try {
      final sent = _rawSocket!.send(data, ip, port);
      if (sent > 0) {
        // Track this as a raw peer so broadcast can include them
        _rawPeerAddresses[pubkeyHex] = AddressInfo(ip, port);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Raw UDP send failed to $pubkeyHex: $e');
      return false;
    }
  }

  /// Check if a peer has a raw UDP address (fallback mode).
  AddressInfo? getRawPeerAddress(String pubkeyHex) =>
      _rawPeerAddresses[pubkeyHex];

  @override
  Future<void> broadcast(Uint8List data, {Set<String>? excludePeerIds}) async {
    // Send via UDX connections
    for (final entry in _peerConnections.entries) {
      if (excludePeerIds != null && excludePeerIds.contains(entry.key)) {
        continue;
      }
      await sendToPeer(entry.key, data);
    }
    // Also send via raw UDP to peers where UDX failed
    for (final entry in _rawPeerAddresses.entries) {
      if (excludePeerIds != null && excludePeerIds.contains(entry.key)) {
        continue;
      }
      if (_peerConnections.containsKey(entry.key)) {
        continue; // Already sent via UDX
      }
      sendRawTo(entry.key, entry.value.ip, entry.value.port, data);
    }
  }

  /// Disconnect from a specific peer.
  Future<void> disconnectFromPeer(String pubkeyHex) async {
    final conn = _peerConnections.remove(pubkeyHex);
    if (conn == null) return;

    // Clean up address mapping
    _addressToPubkey.removeWhere((_, v) => v == pubkeyHex);
    // Clean up tempKey mapping
    _tempKeyToPubkey.removeWhere((_, v) => v == pubkeyHex);

    try {
      await conn.stream?.close();
    } catch (e) {
      debugPrint('Error closing stream for $pubkeyHex: $e');
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: pubkeyHex,
      transport: TransportType.udp,
      connected: false,
      reason: 'Disconnected by request',
    ));

    debugPrint('Disconnected from peer $pubkeyHex');
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // Peer connections are already keyed by pubkey hex.
    // This is used for incoming connections where we learn the pubkey from ANNOUNCE.
    debugPrint('associatePeerWithPubkey: $peerId (managed via ANNOUNCE)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    final hex = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return _peerConnections.containsKey(hex) ? hex : null;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    final conn = _peerConnections[peerId];
    if (conn == null) return null;
    // peerId IS the pubkeyHex in our case
    final bytes = <int>[];
    for (var i = 0; i < peerId.length; i += 2) {
      bytes.add(int.parse(peerId.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  /// Get the observed remote address for a connected peer.
  ///
  /// Returns the (ip, port) as seen on the UDX connection — this is the
  /// peer's NAT-translated public address. Used by the signaling service
  /// to reflect the peer's true external address back to them.
  ///
  /// Returns null if the peer is not connected.
  ({InternetAddress ip, int port})? getRemoteAddress(String pubkeyHex) {
    final conn = _peerConnections[pubkeyHex];
    if (conn == null) return null;
    return (ip: conn.addr, port: conn.port);
  }

  // ===== Incoming Connection Handling =====

  /// Handle a new incoming UDX connection (remote peer connected to us).
  void _handleIncomingConnection(UDPSocket socket) {
    // Normalize address string to match the format stored by connectToPeer.
    final addrStr = socket.remoteAddress.address;
    final remoteAddr = '$addrStr:${socket.remotePort}';
    debugPrint('Incoming UDX connection from $remoteAddr');

    // Check if we already know who this peer is (from a prior connectToPeer call).
    // If so, bypass the tempKey indirection and set up the listener with the
    // correct pubkey immediately. This avoids the timing race where data
    // arrives before ANNOUNCE processing can map the tempKey.
    final knownPubkey = _addressToPubkey[remoteAddr];
    if (knownPubkey != null) {
      debugPrint(
          'Known peer $knownPubkey at $remoteAddr, using direct stream listener');
      socket.on('stream').listen((UDXEvent event) {
        final stream = event.data as UDXStream;
        _listenToStream(knownPubkey, stream);
      });
      socket.flushStreamBuffer();
      return;
    }

    // Unknown peer — use tempKey-based handling until ANNOUNCE reveals pubkey
    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      _handleIncomingStream(socket, stream);
    });

    // Flush any buffered streams (race condition fix from dart_udx)
    socket.flushStreamBuffer();
  }

  /// Handle an incoming stream on a connection.
  ///
  /// Any verified BitchatPacket identifies the sender via its header pubkey.
  /// The coordinator maps the connection after verifying the first packet.
  void _handleIncomingStream(UDPSocket socket, UDXStream stream) {
    debugPrint('Incoming UDX stream ${stream.id}');

    // Listen for data on this stream.
    // We don't know the pubkey yet, so we use a temporary key and let the
    // coordinator re-map after processing the first verified packet.
    final tempKey = '${socket.remoteAddress}:${socket.remotePort}:${stream.id}';

    // Store as pending until ANNOUNCE reveals the pubkey
    _pendingIncoming[tempKey] = _PeerConnection(
      pubkeyHex: '', // unknown yet
      udpSocket: socket,
      stream: stream,
      addr: socket.remoteAddress,
      port: socket.remotePort,
    );

    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;

        // Use mapped pubkey hex if ANNOUNCE has been processed, otherwise tempKey.
        // This ensures ACKs and subsequent messages use the correct peer ID
        // that matches _peerConnections.
        final effectiveId = _tempKeyToPubkey[tempKey] ?? tempKey;

        debugPrint(
            'Received ${data.length} bytes from ${socket.remoteAddress}:${socket.remotePort} (id: $effectiveId)');

        // Emit on data stream
        _dataController.add(TransportDataEvent(
          peerId: effectiveId,
          transport: TransportType.udp,
          data: data,
        ));

        // Forward to coordinator for deserialization and routing.
        // The coordinator will call back with the pubkey after ANNOUNCE processing,
        // and we'll remap the connection.
        onUdpDataReceived?.call(effectiveId, data);
      },
      onError: (e) {
        debugPrint('⚠️ UDX stream error from $tempKey: $e');
      },
      onDone: () {
        debugPrint('⚠️ UDX stream closed from $tempKey');
        // If we have a peer mapped to this temp key, clean up
        final pubkeyHex = _tempKeyToPubkey.remove(tempKey);
        if (pubkeyHex != null) {
          _peerConnections.remove(pubkeyHex);
          _connectionController.add(TransportConnectionEvent(
            peerId: pubkeyHex,
            transport: TransportType.udp,
            connected: false,
            reason: 'Stream closed',
          ));
        }
      },
    );
  }

  /// Reverse map: temp connection key → pubkey hex.
  /// Populated when ANNOUNCE is processed and we learn who connected to us.
  final Map<String, String> _tempKeyToPubkey = {};

  /// Reverse map: "remoteAddress:remotePort" → pubkey hex.
  /// Populated by [connectToPeer] so incoming connections from known addresses
  /// can be immediately associated with the correct pubkey, bypassing the
  /// tempKey indirection and avoiding the timing race where data arrives
  /// before ANNOUNCE processing completes.
  final Map<String, String> _addressToPubkey = {};

  /// Pending incoming connections not yet mapped to a pubkey.
  /// Keyed by tempKey, contains the UDPSocket + UDXStream.
  final Map<String, _PeerConnection> _pendingIncoming = {};

  /// Called by the coordinator after verifying a packet from an incoming connection.
  ///
  /// Maps the temporary connection key to the peer's pubkey hex.
  /// The coordinator calls this with the tempKey it received via [onUdpDataReceived]
  /// and the pubkey extracted from the verified packet's header.
  void mapIncomingConnectionToPubkey(String tempKey, String pubkeyHex) {
    _tempKeyToPubkey[tempKey] = pubkeyHex;

    // Move from pending to established connections
    final pending = _pendingIncoming.remove(tempKey);
    if (pending != null && !_peerConnections.containsKey(pubkeyHex)) {
      _peerConnections[pubkeyHex] = _PeerConnection(
        pubkeyHex: pubkeyHex,
        udpSocket: pending.udpSocket,
        stream: pending.stream,
        addr: pending.addr,
        port: pending.port,
      );

      _connectionController.add(TransportConnectionEvent(
        peerId: pubkeyHex,
        transport: TransportType.udp,
        connected: true,
      ));

      debugPrint('Mapped incoming connection $tempKey → $pubkeyHex');
    }
  }

  // ===== Raw UDP Fallback Receive =====

  /// Handle a non-UDX packet received on the multiplexer socket.
  ///
  /// This fires for packets that don't parse as valid UDX (e.g. BitchatPackets
  /// sent via [sendRawTo] from a peer where UDX handshake failed).
  /// Skip hole-punch packets (36 bytes with BCPU magic).
  void _handleRawPacket(Uint8List data, InternetAddress address, int port) {
    // Skip punch packets (36 bytes, magic "BCPU")
    if (data.length == 36 &&
        data[0] == 0x42 &&
        data[1] == 0x43 &&
        data[2] == 0x50 &&
        data[3] == 0x55) {
      return;
    }

    // Skip tiny packets that aren't meaningful
    if (data.length < 50) return;

    final addrStr = '${address.address}:$port';
    debugPrint('Raw UDP packet: ${data.length} bytes from $addrStr');

    // Try to identify the sender from _rawPeerAddresses (reverse lookup)
    String? senderPubkeyHex;
    for (final entry in _rawPeerAddresses.entries) {
      if (entry.value.ip.address == address.address &&
          entry.value.port == port) {
        senderPubkeyHex = entry.key;
        break;
      }
    }

    // Forward to coordinator for deserialization — use the pubkeyHex if known,
    // otherwise use the address string as a temporary ID.
    final effectiveId = senderPubkeyHex ?? addrStr;
    onUdpDataReceived?.call(effectiveId, data);
  }

  // ===== Stream Listening =====

  /// Listen for data on an outgoing stream (peer we connected to).
  void _listenToStream(String pubkeyHex, UDXStream stream) {
    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;

        debugPrint('Received ${data.length} bytes from peer $pubkeyHex');

        _dataController.add(TransportDataEvent(
          peerId: pubkeyHex,
          transport: TransportType.udp,
          data: data,
        ));

        onUdpDataReceived?.call(pubkeyHex, data);
      },
      onError: (e) {
        debugPrint('⚠️ UDX stream error from $pubkeyHex: $e');
      },
      onDone: () {
        debugPrint('⚠️ UDX stream closed from $pubkeyHex');
        _peerConnections.remove(pubkeyHex);

        if (!_connectionController.isClosed) {
          _connectionController.add(TransportConnectionEvent(
            peerId: pubkeyHex,
            transport: TransportType.udp,
            connected: false,
            reason: 'Stream closed',
          ));
        }
      },
    );
  }

  // ===== Internal =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      store.dispatch(UdpTransportStateChangedAction(newState));
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }

  /// Resolve the device's actual LAN IP address for the given port.
  ///
  /// Enumerates network interfaces to find a usable non-link-local IPv6
  /// address. Returns null if no suitable IPv6 interface is found.
  Future<String?> _resolveLocalAddress(int port) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLoopback: false,
      );

      InternetAddress? bestV6;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          if (addr.type == InternetAddressType.IPv6 && !addr.isLinkLocal) {
            bestV6 ??= addr;
          }
        }
      }
      if (bestV6 == null) {
        debugPrint('No usable IPv6 network interface found for local address');
        return null;
      }
      return AddressInfo(bestV6, port).toAddressString();
    } catch (e) {
      debugPrint('Failed to enumerate network interfaces: $e');
      return null;
    }
  }
}

/// Internal connection state for a single peer.
class _PeerConnection {
  final String pubkeyHex;
  final UDPSocket udpSocket;
  final UDXStream? stream;
  final InternetAddress addr;
  final int port;

  _PeerConnection({
    required this.pubkeyHex,
    required this.udpSocket,
    this.stream,
    required this.addr,
    required this.port,
  });
}
