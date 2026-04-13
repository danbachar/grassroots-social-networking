import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

/// Result of permission request
enum PermissionResult {
  /// All required permissions granted
  granted,
  
  /// Some permissions denied
  denied,
  
  /// Permissions permanently denied (need to go to settings)
  permanentlyDenied,
}

/// Handles permission requests for BLE functionality.
/// 
/// Required permissions:
/// - Android 12+: BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
/// - Android <12: BLUETOOTH, BLUETOOTH_ADMIN, ACCESS_FINE_LOCATION
/// - iOS: Bluetooth (handled automatically), Location for background
class PermissionHandler {
  
  /// Check if all required permissions are granted
  Future<bool> hasRequiredPermissions() async {
    if (Platform.isAndroid) {
      return await _checkAndroidPermissions();
    } else if (Platform.isIOS) {
      return await _checkIOSPermissions();
    }
    return false;
  }
  
  /// Request all required permissions
  /// 
  /// Returns [PermissionResult] indicating success/failure
  Future<PermissionResult> requestPermissions() async {
    debugPrint('Requesting BLE permissions');
    
    if (Platform.isAndroid) {
      return await _requestAndroidPermissions();
    } else if (Platform.isIOS) {
      return await _requestIOSPermissions();
    }
    
    return PermissionResult.denied;
  }
  
  // ===== Android =====
  
  Future<bool> _checkAndroidPermissions() async {
    // Android 12+ (API 31+) uses new Bluetooth permissions
    final bluetoothScan = await Permission.bluetoothScan.isGranted;
    final bluetoothConnect = await Permission.bluetoothConnect.isGranted;
    final bluetoothAdvertise = await Permission.bluetoothAdvertise.isGranted;
    
    // Location still needed for scanning in some cases
    final location = await Permission.locationWhenInUse.isGranted;
    
    return bluetoothScan && bluetoothConnect && bluetoothAdvertise && location;
  }
  
  Future<PermissionResult> _requestAndroidPermissions() async {
    // Request Bluetooth permissions first
    final bluetoothStatuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();
    
    // Check results
    var anyDenied = false;
    var anyPermanentlyDenied = false;
    
    for (final status in bluetoothStatuses.values) {
      if (status.isDenied) anyDenied = true;
      if (status.isPermanentlyDenied) anyPermanentlyDenied = true;
    }
    
    if (anyPermanentlyDenied) {
      debugPrint('Bluetooth permissions permanently denied');
      return PermissionResult.permanentlyDenied;
    }
    
    if (anyDenied) {
      debugPrint('Bluetooth permissions denied');
      return PermissionResult.denied;
    }
    
    // Request location permission
    final locationStatus = await Permission.locationWhenInUse.request();
    
    if (locationStatus.isPermanentlyDenied) {
      debugPrint('Location permission permanently denied');
      return PermissionResult.permanentlyDenied;
    }
    
    if (locationStatus.isDenied) {
      debugPrint('Location permission denied');
      return PermissionResult.denied;
    }
    
    debugPrint('All permissions granted');
    return PermissionResult.granted;
  }
  
  // ===== iOS =====
  
  Future<bool> _checkIOSPermissions() async {
    // iOS handles Bluetooth permissions automatically via Info.plist
    // since iOS 13+. No need to check bluetooth permission explicitly.
    // Just return true as Bluetooth will be granted automatically when used
    debugPrint('iOS: Bluetooth permissions handled by Info.plist');
    return true;
  }
  
  Future<PermissionResult> _requestIOSPermissions() async {
    // iOS 13+ handles Bluetooth automatically via Info.plist
    // No explicit permission request needed for Bluetooth
    debugPrint('iOS: Bluetooth permissions granted automatically via Info.plist');
    return PermissionResult.granted;
  }
  
  /// Open app settings for manual permission grant
  Future<bool> openSettings() async {
    return await openAppSettings();
  }
}
