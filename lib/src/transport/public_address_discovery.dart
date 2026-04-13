import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'address_utils.dart';

/// Discovers our public-facing IPv6 address and combines it with the local
/// UDP port to form the address we advertise to friends.
///
/// Only IPv6 is supported. The UDP transport binds to an IPv6 socket and
/// cannot send to IPv4 destinations. If the device has no globally routable
/// IPv6 address, Internet transport is unavailable — the device can still
/// communicate via BLE.
///
/// The discovered address is included in ANNOUNCE messages so friends know
/// where to send hole-punch packets and establish UDX connections.
class PublicAddressDiscovery {
  final Logger _log = Logger();

  /// Cached public IP (refreshed periodically)
  InternetAddress? _cachedPublicIp;

  /// When the cache was last refreshed
  DateTime? _cacheTime;

  /// Cache duration (public IP doesn't change often)
  static const Duration cacheDuration = Duration(minutes: 5);

  /// The best public IP we know of (IPv6 preferred over IPv4).
  /// Set even when the address isn't globally routable for UDP — useful
  /// for display purposes on NAT'd devices.
  InternetAddress? _bestPublicIp;

  /// The best public IP discovered so far (IPv6 > IPv4).
  /// Available even when the device is behind NAT and has no open port.
  InternetAddress? get bestPublicIp => _bestPublicIp;

  /// Discover our public IPv6 address.
  ///
  /// Returns a globally routable IPv6 address, or null if unavailable.
  /// IPv4 is not supported — the UDP transport binds to an IPv6 socket
  /// and cannot send to IPv4 destinations. A device without IPv6 has no
  /// Internet transport; it can still communicate via BLE.
  ///
  /// Result is cached for [cacheDuration] to avoid excessive lookups.
  Future<InternetAddress?> discoverPublicIp() async {
    // Return cached value if fresh
    if (_cachedPublicIp != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < cacheDuration) {
      return _cachedPublicIp;
    }

    final ipv6 = await _fetchPublicIp('https://ipv6.seeip.org');
    if (ipv6 != null && ipv6.type == InternetAddressType.IPv6) {
      _cachedPublicIp = ipv6;
      _cacheTime = DateTime.now();
      _bestPublicIp = ipv6;
      debugPrint('Discovered public IPv6: ${ipv6.address}');
      return ipv6;
    }

    // No IPv6 — try IPv4 for display purposes (transport still won't work
    // without IPv6, but we can show the user their public IP).
    final ipv4 = await _fetchPublicIp('https://api.seeip.org');
    if (ipv4 != null) {
      _bestPublicIp = ipv4;
      debugPrint('No public IPv6 — discovered public IPv4: ${ipv4.address}');
    } else {
      debugPrint('No public IPv6 address available — Internet transport unavailable');
    }

    return null;
  }

  /// Fetch our public IP from the given URL.
  Future<InternetAddress?> _fetchPublicIp(String url) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final ip = body.trim();

        if (ip.isEmpty) {
          debugPrint('Empty response from $url');
          return null;
        }

        final parsed = InternetAddress.tryParse(ip);
        if (parsed == null) {
          debugPrint('Failed to parse IP from $url: $ip');
          return null;
        }

        return parsed;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('IP discovery from $url failed: $e');
      return null;
    }
  }

  /// Get our public address string (public_ip:local_port).
  ///
  /// Combines the discovered public IPv6 with the given local port.
  /// Returns null if no public IPv6 is available.
  Future<String?> getPublicAddress(int localPort) async {
    final ip = await discoverPublicIp();
    if (ip == null) return null;
    return AddressInfo(ip, localPort).toAddressString();
  }

  /// Discover our link-local IPv6 address from network interfaces.
  ///
  /// Link-local addresses (fe80::) work on the same L2 segment and can
  /// bypass WiFi AP client isolation that blocks global IPv6 traffic.
  /// Returns the address as `[fe80::...%iface]:port` ready for use, or
  /// null if no link-local IPv6 interface is found.
  Future<String?> getLinkLocalAddress(int localPort) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLinkLocal) {
            // Link-local addresses need a scope/zone ID for socket ops.
            // Dart's InternetAddress.address includes it (e.g. fe80::1%wlan0).
            final llAddr = AddressInfo(addr, localPort).toAddressString();
            debugPrint('Discovered link-local IPv6: ${addr.address} on ${iface.name}');
            return llAddr;
          }
        }
      }
    } catch (e) {
      debugPrint('Link-local discovery failed: $e');
    }
    return null;
  }

  /// Invalidate the cached public IP (e.g. on network change).
  void invalidateCache() {
    _cachedPublicIp = null;
    _cacheTime = null;
    _bestPublicIp = null;
  }
}
