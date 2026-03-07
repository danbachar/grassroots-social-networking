import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../models/identity.dart';
import '../protocol/protocol_handler.dart';
import '../store/store.dart';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_udx/dart_udx.dart';
import 'package:http/http.dart' as http;

/// Default display info for LibP2P transport
const _defaultLibP2PDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'LibP2P peer-to-peer transport',
  color: Colors.green,
);

/// LibP2P configuration for the transport service
class LibP2PConfig {
  /// Listen addresses for the libp2p host
  final List<String> listenAddresses;

  /// Bootstrap peers to connect to initially
  final List<String> bootstrapPeers;

  /// Enable mDNS discovery for local network peers
  final bool enableMdns;

  /// Enable DHT for peer routing and discovery
  final bool enableDht;

  /// Enable relay for NAT traversal
  final bool enableRelay;

  const LibP2PConfig({
    this.listenAddresses = const ['/ip4/0.0.0.0/tcp/0'],
    this.bootstrapPeers = const [],
    this.enableMdns = true,
    this.enableDht = false,
    this.enableRelay = false,
  });
}

/// LibP2P-based transport service with embedded routing logic.
///
/// This is a direct peer-to-peer transport - NO forwarding/relaying of messages
/// for other peers. All messages go directly from sender to recipient.
///
/// Routing logic (ANNOUNCE handling, peer management) is embedded directly
/// in this service class, not in a separate router.
class LibP2PTransportService extends TransportService {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// LibP2P configuration
  final LibP2PConfig config;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol handler for encoding/decoding
  final ProtocolHandler protocolHandler;

  /// LibP2P host instance
  Host? _host;

  /// Get the host ID (PeerId) as string - null if host not initialized
  String? get hostId => _host?.id.toString();

  /// Get the host addresses (list of multiaddrs) - empty if host not initialized
  List<String> get hostAddrs =>
      _host?.addrs.map((a) => a.toString()).toList() ?? [];

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====

  /// Called when libp2p data is received and ready for routing.
  /// The coordinator deserializes as BitchatPacket and routes via MessageRouter.processPacket().
  void Function(String peerId, Uint8List data)? onLibp2pDataReceived;

  LibP2PTransportService({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    this.config = const LibP2PConfig(),
  });

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.libp2p;

  @override
  TransportDisplayInfo get displayInfo => _defaultLibP2PDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => store.state.peers.libp2pPeers.length;

  @override
  bool get isActive => _state == TransportState.active;

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('LibP2P transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing LibP2P transport service');

    try {
      _host = await createHost();
      _log.i('Host: ${_host!.id} ${_host!.addrs}');

      _setState(TransportState.ready);
      _log.i('LibP2P transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize LibP2P transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start LibP2P transport in state: $_state');
      return;
    }

    _log.i('Starting LibP2P transport');

    try {
      // Host is already started in createHost(), just update state
      _setState(TransportState.active);
      _log.i('LibP2P transport started');
    } catch (e) {
      _log.e('Failed to start LibP2P transport: $e');
      _setState(TransportState.error);
    }
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping LibP2P transport');

    try {
      // TODO: Implement host stop (currently host has no stop method in dart_libp2p)
      if (_state == TransportState.active) {
        _setState(TransportState.ready);
      }
      _log.i('LibP2P transport stopped');
    } catch (e) {
      _log.e('Failed to stop LibP2P transport: $e');
    }
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    _log.d('Connecting to peer: $peerId');
    try {
      // TODO: Implement connectToPeer using dart_libp2p (connectToHost is used instead)
      return true;
    } catch (e) {
      _log.e('Failed to connect to peer $peerId: $e');
      return false;
    }
  }

  /// Connect to a peer using their host info (ID and addresses)
  /// This is used when accepting a friend request or receiving acceptance
  /// Returns the successful address on success, null on failure
  Future<String?> connectToHost(
      {required String hostId, required List<String> hostAddrs}) async {
    if (_host == null) {
      _log.w('Cannot connect: host not initialized');
      return null;
    }

    _log.i('Connecting to host: $hostId with addresses: $hostAddrs');

    // Separate IPv4 and IPv6 addresses - try IPv4 first (more common/reliable)
    final ipv4Addrs =
        hostAddrs.where((addr) => addr.startsWith('/ip4/')).toList();
    final ipv6Addrs =
        hostAddrs.where((addr) => addr.startsWith('/ip6/')).toList();

    // Try IPv4 first, then IPv6
    final orderedAddrs = [...ipv4Addrs, ...ipv6Addrs];

    if (orderedAddrs.isEmpty) {
      _log.w('No valid addresses found for host $hostId');
      return null;
    }

    _log.d(
        'Trying ${ipv4Addrs.length} IPv4 and ${ipv6Addrs.length} IPv6 addresses');

    for (final addr in orderedAddrs) {
      try {
        _log.i('Connecting to host: $hostId with address: $addr');
        final peerId = PeerId.fromString(hostId);
        final address = MultiAddr(addr);
        final addrs = [address];
        final addrInfo = AddrInfo(peerId, addrs);
        await _host!.connect(addrInfo);
        _log.i('Successfully connected to host: $hostId with address: $addr');
        return addr;
      } catch (e) {
        _log.e('Failed to connect to host $hostId with address: $addr: $e');
      }
    }

    return null;
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');
    try {
      // TODO: Implement disconnect using dart_libp2p
      _connectionController.add(TransportConnectionEvent(
        peerId: peerId,
        transport: TransportType.libp2p,
        connected: false,
        reason: 'Disconnected by request',
      ));
    } catch (e) {
      _log.e('Failed to disconnect from peer $peerId: $e');
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    try {
      const duration = Duration(seconds: 10);
      final ctx = Context(timeout: duration);
      P2PStream myStream = await _host!
          .newStream(PeerId.fromString(peerId), ['/gever/1.0.0'], ctx);
      await myStream.write(data);
      await myStream.close();

      _log.d('Sent ${data.length} bytes to peer $peerId');
      return true;
    } catch (e) {
      _log.e('Failed to send to peer $peerId: $e');
      return false;
    }
  }

  @override
  Future<void> broadcast(Uint8List data, {String? excludePeerId}) async {
    for (final peer in store.state.peers.libp2pPeers) {
      final hostId = peer.libp2pHostId;
      if (hostId != null && hostId != excludePeerId) {
        await sendToPeer(hostId, data);
      }
    }
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // No-op: Redux store is the source of truth for peer associations
    // The association is made via PeerAnnounceReceivedAction or FriendEstablishedAction
    _log.d('associatePeerWithPubkey called (no-op, using Redux store)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // Look up in Redux store
    final peer = store.state.peers.getPeerByPubkey(pubkey);
    return peer?.libp2pHostId;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // Look up in Redux store - find peer with matching libp2pHostId
    for (final peer in store.state.peers.peersList) {
      if (peer.libp2pHostId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing LibP2P transport');
    await stop();
    _host = null;
    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    _setState(TransportState.disposed);
  }

  // ===== Peerstore Management =====

  /// Ensure peer addresses are in the libp2p peerstore
  Future<void> ensureAddressesInPeerstore(
      String hostId, List<String> hostAddrs) async {
    if (_host == null) return;

    try {
      final peerId = PeerId.fromString(hostId);
      final multiAddrs = hostAddrs
          .map((addr) {
            try {
              return MultiAddr(addr);
            } catch (e) {
              _log.w('Invalid multiaddr: $addr');
              return null;
            }
          })
          .whereType<MultiAddr>()
          .toList();

      if (multiAddrs.isNotEmpty) {
        await _host!.peerStore.addrBook
            .addAddrs(peerId, multiAddrs, const Duration(hours: 1));
        _log.d('Added ${multiAddrs.length} addresses to peerstore for $hostId');
      }
    } catch (e) {
      _log.w('Failed to add addresses to peerstore: $e');
    }
  }

  // ===== Packet Processing =====

  /// Process incoming data from a peer.
  ///
  /// Forwards raw bytes to the coordinator via [onLibp2pDataReceived].
  /// The coordinator deserializes as BitchatPacket and routes to MessageRouter.
  void onDataReceived(String peerId, Uint8List data, {int rssi = 0}) {
    _log.d('Data received from peer $peerId: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      data: data,
    ));

    if (data.isEmpty) {
      _log.w('Received empty data from peer');
      return;
    }

    // Forward to coordinator for deserialization and routing
    onLibp2pDataReceived?.call(peerId, data);
  }

  /// Called when a peer connects at the transport level
  void onPeerTransportConnected(String peerId) {
    _log.d('Transport peer connected: $peerId');

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: true,
    ));
  }

  /// Called when a peer disconnects at the transport level
  void onPeerTransportDisconnected(String peerId) {
    final pubkey = getPubkeyForPeerId(peerId);
    if (pubkey != null) {
      final peerState = store.state.peers.getPeerByPubkey(pubkey);
      if (peerState != null) {
        store.dispatch(PeerLibp2pDisconnectedAction(pubkey));
        _log.i('Peer disconnected: ${peerState.displayName}');
      }
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: false,
    ));
  }

  // ===== Internal =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  Future<String> _getIPv6Address() async {
    // final response = await http.get(Uri.parse('https://api64.ipify.org/?format=text'));
    final response = await http.get(Uri.parse('https://ipv6.icanhazip.com/'));

    if (response.statusCode == 200) {
      return response.body.trim();
    } else {
      _log.w(
          'Failed to get IPv6 address from api64.ipify.org, status code: ${response.statusCode}');
      return '::1'; // Fallback to loopback
    }
  }

  Future<Host> createHost() async {
    final keyPair = await crypto_ed25519.generateEd25519KeyPair();
    final udx = UDX();
    final connMgr = p2p_conn_manager.ConnectionManager();

    String ipv6 = await _getIPv6Address();
    _log.i('Public IPv6 address: $ipv6');

    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      p2p_config.Libp2p.transport(
          UDXTransport(connManager: connMgr, udxInstance: udx)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      // Listen on both IPv4 and IPv6 for maximum connectivity
      p2p_config.Libp2p.listenAddrs([
        // MultiAddr('/ip4/0.0.0.0/udp/0/udx'),
        MultiAddr('/ip6/::/udp/0/udx'),
      ]),
    ];

    final host = await p2p_config.Libp2p.new_(options);
    host.setStreamHandler('/gever/1.0.0', _handleGeverRequest);
    await host.start();

    _log.i("Host has ${host.addrs.length} addresses");
    for (var addr in host.addrs) {
      _log.i('Listening on address: $addr');
    }
    return host;
  }

  // Helper function to truncate peer IDs for display
  String _truncatePeerId(PeerId peerId) {
    final peerIdStr = peerId.toBase58();
    final strLen = peerIdStr.length;
    return peerIdStr.substring(strLen - 8, strLen);
  }

  Future<void> _handleGeverRequest(P2PStream stream, PeerId remotePeer) async {
    try {
      // Read the message from the stream
      final data = await stream.read();
      if (data.isNotEmpty) {
        _log.d('Received ${data.length} bytes from peer ${_truncatePeerId(remotePeer)}');

        // Pass to onDataReceived which handles envelope parsing
        onDataReceived(remotePeer.toBase58(), Uint8List.fromList(data));
      }
    } catch (e) {
      _log.e('Error reading from libp2p stream: $e');
    } finally {
      await stream.close();
    }
  }
}
