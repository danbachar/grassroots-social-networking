import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redux/redux.dart';
import 'debug_log_screen.dart';
import 'src/store/app_state.dart';
import 'src/store/settings_actions.dart';
import 'src/store/settings_state.dart';
import 'src/store/transports_state.dart';
import 'src/transport/transport_service.dart';

/// Settings screen for configuring transport protocols
class SettingsScreen extends StatefulWidget {
  final Store<AppState> store;

  /// Callback when settings are changed
  final VoidCallback? onSettingsChanged;

  /// Debug-only: switch which BLE roles the local device runs.
  final Future<void> Function(BleRoleMode mode)? onBleRoleModeChanged;

  /// Re-run public-address (seeip) discovery, invoked by the "Retry" button
  /// shown when discovery has failed and no IP is known.
  final Future<void> Function()? onRetryPublicAddressDiscovery;

  /// Upload not-yet-uploaded diagnostic traces on demand ("Upload now").
  /// Returns a short user-facing status message to surface in a snackbar.
  final Future<String> Function()? onUploadTracesNow;

  const SettingsScreen({
    super.key,
    required this.store,
    this.onSettingsChanged,
    this.onBleRoleModeChanged,
    this.onRetryPublicAddressDiscovery,
    this.onUploadTracesNow,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _bluetoothEnabled;
  late bool _udpEnabled;
  bool _isRetryingPublicAddressDiscovery = false;
  StreamSubscription<AppState>? _storeSubscription;

  /// True while a manual "Upload now" is in flight (disables the button).
  bool _uploadingTraces = false;

  @override
  void initState() {
    super.initState();
    _bluetoothEnabled = widget.store.state.settings.bluetoothEnabled;
    _udpEnabled = widget.store.state.settings.udpEnabled;

    _storeSubscription = widget.store.onChange.listen((state) {
      final settings = state.settings;
      if (_bluetoothEnabled != settings.bluetoothEnabled) {
        _bluetoothEnabled = settings.bluetoothEnabled;
      }
      if (_udpEnabled != settings.udpEnabled) {
        _udpEnabled = settings.udpEnabled;
      }
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _storeSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF1B3D2F),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),

          // Transport Section Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.swap_horiz, color: Color(0xFFE8A33C)),
                const SizedBox(width: 8),
                const Text(
                  'Transport Protocols',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE8A33C),
                  ),
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Choose which protocols to use for peer communication. '
              'Bluetooth is preferred when peers are nearby.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),

          const SizedBox(height: 8),

          // Bluetooth Toggle
          _buildTransportTile(
            icon: Icons.bluetooth,
            iconColor: Colors.blue,
            title: 'Bluetooth',
            subtitle: 'Connect to nearby peers via BLE',
            value: _bluetoothEnabled,
            available:
                widget.store.state.transports.bleState != TransportState.error,
            onChanged: _onBluetoothChanged,
            priority: 1,
          ),

          // Debug: BLE role mode (auto / central-only / peripheral-only).
          if (_bluetoothEnabled && widget.onBleRoleModeChanged != null)
            _buildBleRoleModeSelector(),

          if (_bluetoothEnabled) _buildColdCallTrustSelector(),

          // UDP Toggle
          _buildTransportTile(
            icon: Icons.public,
            iconColor: Colors.green,
            title: 'Internet',
            subtitle: 'Connect to peers over the Internet',
            value: _udpEnabled,
            available:
                widget.store.state.transports.udpState != TransportState.error,
            onChanged: _onUdpChanged,
            priority: 2,
          ),

          // Internet connection status
          if (_udpEnabled && widget.store.state.transports.udpState.isUsable)
            _buildConnectionStatusBadge(),

          const Divider(height: 32),

          // Diagnostic traces (opt-in research telemetry)
          _buildTraceLoggingSection(),

          const Divider(height: 32),

          // Warning if no transport enabled
          if (!_bluetoothEnabled && !_udpEnabled)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'No transport enabled',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'You won\'t be able to communicate with other peers. '
                          'Enable at least one transport protocol.',
                          style: TextStyle(color: Colors.red, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Info Section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildInfoCard(),
          ),

          const Divider(height: 32),

          // Debug Logs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.bug_report, color: Colors.purple),
              ),
              title: const Text(
                'Debug Logs',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'View live transport logs',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DebugLogScreen(),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildTransportTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required bool available,
    required ValueChanged<bool> onChanged,
    required int priority,
  }) {
    final isEnabled = value && available;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: isEnabled ? const Color(0xFF1B3D2F) : null,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(isEnabled ? 0.2 : 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: isEnabled ? iconColor : Colors.grey,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isEnabled ? Colors.white : Colors.grey,
                ),
              ),
            ),
            if (!available)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Unavailable',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.orange,
                  ),
                ),
              ),
            if (available && isEnabled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Priority $priority',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.green,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          !available ? 'Not available on this device' : subtitle,
          style: TextStyle(
            color: isEnabled ? Colors.grey[400] : Colors.grey,
            fontSize: 13,
          ),
        ),
        trailing: Switch(
          value: value,
          onChanged: available ? onChanged : null,
          activeColor: const Color(0xFFE8A33C),
        ),
        onTap: available ? () => onChanged(!value) : null,
      ),
    );
  }

  Widget _buildBleRoleModeSelector() {
    final mode = widget.store.state.settings.bleRoleMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_outlined,
                  size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              Text(
                'BLE role (debug)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange[700],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            switch (mode) {
              BleRoleMode.auto =>
                'Scan + advertise. Paths form as each BLE stack allows.',
              BleRoleMode.centralOnly =>
                'Scan only — peers cannot dial us; we only get central paths.',
              BleRoleMode.peripheralOnly =>
                'Advertise only — we never dial; peers reach us as peripheral.',
            },
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          SegmentedButton<BleRoleMode>(
            segments: const [
              ButtonSegment(
                value: BleRoleMode.auto,
                label: Text('Auto'),
                icon: Icon(Icons.swap_horiz),
              ),
              ButtonSegment(
                value: BleRoleMode.centralOnly,
                label: Text('Central'),
                icon: Icon(Icons.arrow_outward),
              ),
              ButtonSegment(
                value: BleRoleMode.peripheralOnly,
                label: Text('Peripheral'),
                icon: Icon(Icons.arrow_downward),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selection) async {
              if (selection.isEmpty) return;
              final next = selection.first;
              await widget.onBleRoleModeChanged?.call(next);
              widget.onSettingsChanged?.call();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTraceLoggingSection() {
    final settings = widget.store.state.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.insights, color: Color(0xFFE8A33C)),
              SizedBox(width: 8),
              Text(
                'Diagnostic Traces',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE8A33C),
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Opt in to collect anonymous diagnostic traces on this device. '
            'The app asks on every start before uploading, or upload manually '
            'below.',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        SwitchListTile(
          value: settings.traceLoggingConsent,
          activeColor: const Color(0xFFE8A33C),
          title: const Text('Collect diagnostic traces'),
          subtitle: Text(settings.traceLoggingConsent ? 'On' : 'Off'),
          onChanged: (value) => widget.store.dispatch(
            SetTraceLoggingConsentAction(
              value,
              consentTimestamp: DateTime.now().toUtc().toIso8601String(),
            ),
          ),
        ),
        if (settings.traceLoggingConsent && widget.onUploadTracesNow != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                onPressed: _uploadingTraces ? null : _handleUploadNow,
                icon: _uploadingTraces
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload),
                label: Text(_uploadingTraces ? 'Uploading…' : 'Upload now'),
              ),
            ),
          ),
      ],
    );
  }

  /// Run the manual trace upload and surface its status in a snackbar.
  Future<void> _handleUploadNow() async {
    final upload = widget.onUploadTracesNow;
    if (upload == null) return;
    setState(() => _uploadingTraces = true);
    String message;
    try {
      message = await upload();
    } catch (_) {
      message = 'Trace upload failed';
    }
    if (!mounted) return;
    setState(() => _uploadingTraces = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
  }

  Widget _buildColdCallTrustSelector() {
    final level = widget.store.state.settings.coldCallTrustLevel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  size: 16, color: Color(0xFF1B3D2F)),
              const SizedBox(width: 6),
              Text(
                'Cold calls',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.green[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'A "cold call" is an unsolicited BLE first-contact attempt from a '
            'nearby peer you have not friended yet. This setting controls '
            'whether you reply.\n\n'
            '• Open — anyone in range can complete the signed ANNOUNCE '
            'handshake, so you can discover and meet new peers. Strangers '
            'learn your public key and nickname, but never your address '
            'or any friend-only metadata.\n'
            '• Closed — first contact from non-friends is refused. Nearby '
            'devices still see your service advertisement, but ANNOUNCE is '
            'not sent and incoming ANNOUNCEs from strangers are dropped, '
            'so unknown peers cannot learn your nickname over BLE.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          Text(
            switch (level) {
              ColdCallTrustLevel.open =>
                'Currently open: nearby unknown peers can complete first '
                    'contact.',
              ColdCallTrustLevel.closed =>
                'Currently closed: only accepted friends complete BLE first '
                    'contact.',
            },
            style: TextStyle(
              fontSize: 12,
              color: Colors.green[800],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ColdCallTrustLevel>(
            segments: const [
              ButtonSegment(
                value: ColdCallTrustLevel.open,
                label: Text('Open'),
                icon: Icon(Icons.sensors),
              ),
              ButtonSegment(
                value: ColdCallTrustLevel.closed,
                label: Text('Closed'),
                icon: Icon(Icons.lock_outline),
              ),
            ],
            selected: {level},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              widget.store
                  .dispatch(SetColdCallTrustLevelAction(selection.first));
              widget.onSettingsChanged?.call();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatusBadge() {
    final transports = widget.store.state.transports;
    final isWellConnected = transports.isWellConnected;
    final publicAddress = transports.publicAddress;
    final publicIp = transports.publicIp;
    final connectionType = transports.networkConnectionType;
    final showDiscoveryFailedWarning =
        transports.publicAddressDiscoveryFailed &&
            publicAddress == null &&
            publicIp == null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isWellConnected
          ? Colors.green.withOpacity(0.1)
          : Colors.grey.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isWellConnected ? Icons.language : Icons.shield_outlined,
              color: isWellConnected ? Colors.green : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isWellConnected ? 'Well-connected' : 'Standard connection',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: isWellConnected ? Colors.green : Colors.grey[400],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isWellConnected
                        ? 'Your device has a globally routable address and can help friends connect'
                        : 'Your device is behind NAT — connections to friends may require hole-punching',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        _networkTypeIcon(connectionType),
                        size: 14,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Connection type: ${connectionType.displayName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                  if (publicIp != null || publicAddress != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      publicAddress ?? publicIp!,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.grey[400],
                      ),
                    ),
                  ] else if (showDiscoveryFailedWarning) ...[
                    const SizedBox(height: 6),
                    _buildNoPublicAddressWarning(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoPublicAddressWarning() {
    return Row(
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: 14,
          color: Colors.orange[700],
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'No public IP address available',
            style: TextStyle(
              fontSize: 11,
              color: Colors.orange[700],
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          height: 24,
          child: TextButton.icon(
            onPressed: _isRetryingPublicAddressDiscovery ||
                    widget.onRetryPublicAddressDiscovery == null
                ? null
                : _handleRetryPublicAddressDiscovery,
            icon: _isRetryingPublicAddressDiscovery
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh, size: 14),
            label: const Text('Retry', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleRetryPublicAddressDiscovery() async {
    final callback = widget.onRetryPublicAddressDiscovery;
    if (callback == null) return;
    setState(() {
      _isRetryingPublicAddressDiscovery = true;
    });
    try {
      await callback();
    } finally {
      if (mounted) {
        setState(() {
          _isRetryingPublicAddressDiscovery = false;
        });
      }
    }
  }

  IconData _networkTypeIcon(NetworkConnectionType connectionType) {
    switch (connectionType) {
      case NetworkConnectionType.wifi:
        return Icons.wifi;
      case NetworkConnectionType.cellular:
        return Icons.signal_cellular_alt;
      case NetworkConnectionType.ethernet:
        return Icons.settings_ethernet;
      case NetworkConnectionType.vpn:
        return Icons.lock_outline;
      case NetworkConnectionType.other:
        return Icons.device_hub_outlined;
      case NetworkConnectionType.offline:
        return Icons.portable_wifi_off;
    }
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.info_outline, color: Colors.blue, size: 20),
              SizedBox(width: 8),
              Text(
                'How it works',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInfoRow(
            icon: Icons.bluetooth,
            iconColor: Colors.blue,
            text: 'Bluetooth connects you to nearby peers without Internet',
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            icon: Icons.public,
            iconColor: Colors.green,
            text: 'Internet connects you to peers anywhere in the world',
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            icon: Icons.priority_high,
            iconColor: const Color(0xFFE8A33C),
            text:
                'When both are available, Bluetooth is preferred for faster communication',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required Color iconColor,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  void _onBluetoothChanged(bool value) {
    // Prevent disabling both transports
    if (!value && !_udpEnabled) {
      _showCannotDisableDialog();
      return;
    }

    setState(() {
      _bluetoothEnabled = value;
    });

    widget.store.dispatch(SetBluetoothEnabledAction(value));
    widget.onSettingsChanged?.call();
  }

  void _onUdpChanged(bool value) {
    // Prevent disabling both transports
    if (!value && !_bluetoothEnabled) {
      _showCannotDisableDialog();
      return;
    }

    setState(() {
      _udpEnabled = value;
    });

    widget.store.dispatch(SetUdpEnabledAction(value));
    widget.onSettingsChanged?.call();
  }

  void _showCannotDisableDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cannot Disable'),
        content: const Text(
          'At least one transport protocol must be enabled to communicate with peers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
