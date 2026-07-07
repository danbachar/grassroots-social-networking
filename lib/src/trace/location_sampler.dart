import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Opt-in coarse location sampling for diagnostic traces.
///
/// Fixes are rounded to a coarse geohash cell for privacy. Visit history is
/// tracked on-device against the real geocell; only derived metrics are logged —
/// a `visit` record (visiting time, return time, visit frequency) is emitted
/// when the device leaves a cell. Never throws.
class LocationSampler {
  /// Geohash precision — 6 chars ≈ 1.2 km × 0.6 km cells (coarse zone tags).
  final int geohashPrecision;

  LocationSampler({this.geohashPrecision = 6});

  bool _permissionOk = false;

  String? _currentCell;
  int? _cellArrivedAt;
  final Map<String, int> _lastLeftCell = {}; // cell -> ms of last departure
  final Map<String, int> _cellVisitCount = {};

  /// Ensure location permission (call after consent). Returns whether granted.
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return _permissionOk = false;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      _permissionOk = perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
      return _permissionOk;
    } catch (e) {
      debugPrint('[trace] location permission failed: $e');
      return _permissionOk = false;
    }
  }

  /// A coarse fix `{lat, lon, geocell}` (rounded) for enriching a density
  /// record, or null if unavailable. Also drives visit tracking: [onVisit] is
  /// invoked with a completed `visit` record when the device leaves a cell.
  Future<Map<String, dynamic>?> sample({
    void Function(Map<String, dynamic> visit)? onVisit,
  }) async {
    if (!_permissionOk) return null;
    final Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (e) {
      debugPrint('[trace] location sample failed: $e');
      return null;
    }

    final cell = _geohash(pos.latitude, pos.longitude, geohashPrecision);
    final now = DateTime.now().millisecondsSinceEpoch;
    _updateVisit(cell, now, onVisit);

    return {
      // Rounded to ~city-block resolution for the uploaded density record.
      'lat': double.parse(pos.latitude.toStringAsFixed(3)),
      'lon': double.parse(pos.longitude.toStringAsFixed(3)),
      'geocell': cell,
    };
  }

  void _updateVisit(
    String cell,
    int now,
    void Function(Map<String, dynamic>)? onVisit,
  ) {
    if (_currentCell == cell) return; // still in the same cell

    // Leaving the previous cell → emit a completed visit.
    if (_currentCell != null && _cellArrivedAt != null) {
      final prev = _currentCell!;
      final lastLeft = _lastLeftCell[prev];
      _lastLeftCell[prev] = now;
      onVisit?.call({
        'type': 'visit',
        't': now,
        'placeId': prev,
        'arrivedAt': _cellArrivedAt,
        'leftAt': now,
        'visitMs': now - _cellArrivedAt!,
        if (lastLeft != null) 'returnTimeMs': _cellArrivedAt! - lastLeft,
        'visitCount': _cellVisitCount[prev] ?? 1,
      });
    }

    // Entering the new cell.
    _currentCell = cell;
    _cellArrivedAt = now;
    _cellVisitCount[cell] = (_cellVisitCount[cell] ?? 0) + 1;
  }

  // Standard base32 geohash encoder.
  static const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  String _geohash(double lat, double lon, int precision) {
    final latRange = [-90.0, 90.0];
    final lonRange = [-180.0, 180.0];
    final buf = StringBuffer();
    var isLon = true;
    var bit = 0;
    var ch = 0;
    while (buf.length < precision) {
      if (isLon) {
        final mid = (lonRange[0] + lonRange[1]) / 2;
        if (lon >= mid) {
          ch = (ch << 1) | 1;
          lonRange[0] = mid;
        } else {
          ch = ch << 1;
          lonRange[1] = mid;
        }
      } else {
        final mid = (latRange[0] + latRange[1]) / 2;
        if (lat >= mid) {
          ch = (ch << 1) | 1;
          latRange[0] = mid;
        } else {
          ch = ch << 1;
          latRange[1] = mid;
        }
      }
      isLon = !isLon;
      if (++bit == 5) {
        buf.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }
    return buf.toString();
  }
}
