import 'dart:async';

import 'package:flutter/material.dart';
import 'package:redux/redux.dart';
import 'debug_log_screen.dart';
import 'testbed_screen.dart';
import 'theme/grasslink_tokens.dart';
import 'theme/grasslink_widgets.dart';
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

  /// Debug/testbed hooks, forwarded to [TestbedScreen]. Null when the network
  /// is not up. [myPubkeyHex] is this device's hex identity.
  final String? myPubkeyHex;
  final Future<void> Function()? onStartWorkload;
  final VoidCallback? onStopWorkload;
  final WorkloadStatus Function()? workloadStatus;

  const SettingsScreen({
    super.key,
    required this.store,
    this.onSettingsChanged,
    this.onBleRoleModeChanged,
    this.onRetryPublicAddressDiscovery,
    this.onUploadTracesNow,
    this.myPubkeyHex,
    this.onStartWorkload,
    this.onStopWorkload,
    this.workloadStatus,
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
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),

          // Transport Section Header
          const Padding(
            padding: EdgeInsets.symmetric(
                horizontal: GlSpace.s4, vertical: GlSpace.s2),
            child: EyebrowLabel('Your links', color: GlColors.accentOnSoft),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: GlSpace.s4),
            child: Text(
              'Choose how you reach your peers. Bluetooth carries messages '
              'when neighbours are nearby.',
              style:
                  TextStyle(color: GlColors.textMuted, fontSize: GlType.textSm),
            ),
          ),

          const SizedBox(height: 8),

          // Bluetooth Toggle
          _buildTransportTile(
            icon: Icons.bluetooth_rounded,
            iconColor: GlColors.primary,
            title: 'Bluetooth',
            subtitle: 'Reach neighbours nearby, no Internet needed',
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
            icon: Icons.public_rounded,
            iconColor: GlColors.info,
            title: 'Internet',
            subtitle: 'Reach peers anywhere in the world',
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

          // Introduce strangers (invite facilitation)
          _buildFacilitateInvitesSection(),

          const Divider(height: 32),

          // Diagnostic traces (opt-in research telemetry)
          _buildTraceLoggingSection(),

          const Divider(height: 32),

          // Warning if no transport enabled
          if (!_bluetoothEnabled && !_udpEnabled)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: GlSpace.s4),
              padding: const EdgeInsets.all(GlSpace.s4),
              decoration: BoxDecoration(
                color: GlColors.dangerSoft,
                borderRadius: GlRadius.rMd,
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: GlColors.danger),
                  SizedBox(width: GlSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'No link is on',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: GlColors.danger,
                          ),
                        ),
                        SizedBox(height: GlSpace.s1),
                        Text(
                          'You can\'t reach anyone right now. '
                          'Turn on at least one link.',
                          style: TextStyle(
                              color: GlColors.danger, fontSize: GlType.textSm),
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
                padding: const EdgeInsets.all(GlSpace.s2),
                decoration: BoxDecoration(
                  color: GlColors.infoSoft,
                  borderRadius: GlRadius.rSm,
                ),
                child: const Icon(Icons.bug_report_outlined,
                    color: GlColors.info),
              ),
              title: const Text(
                'Debug logs',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Live transport logs',
                style: TextStyle(
                    color: GlColors.textMuted, fontSize: GlType.textSm),
              ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: GlColors.textSubtle),
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

          // Testbed (debug harnesses)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(GlSpace.s2),
                decoration: BoxDecoration(
                  color: GlColors.infoSoft,
                  borderRadius: GlRadius.rSm,
                ),
                child: const Icon(Icons.science_outlined, color: GlColors.info),
              ),
              title: const Text(
                'Testbed',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Neighbour allowlist + workload driver',
                style: TextStyle(
                    color: GlColors.textMuted, fontSize: GlType.textSm),
              ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: GlColors.textSubtle),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => TestbedScreen(
                      store: widget.store,
                      myPubkeyHex: widget.myPubkeyHex,
                      onStartWorkload: widget.onStartWorkload,
                      onStopWorkload: widget.onStopWorkload,
                      workloadStatus: widget.workloadStatus,
                    ),
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
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(GlSpace.s2),
          decoration: BoxDecoration(
            color: isEnabled ? GlColors.primarySoft : GlColors.bgSunken,
            borderRadius: GlRadius.rSm,
          ),
          child: Icon(
            icon,
            color: isEnabled ? iconColor : GlColors.textSubtle,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color:
                      isEnabled ? GlColors.textStrong : GlColors.textMuted,
                ),
              ),
            ),
            if (!available)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: GlSpace.s2, vertical: 2),
                decoration: BoxDecoration(
                  color: GlColors.warningSoft,
                  borderRadius: GlRadius.rPill,
                ),
                child: const Text(
                  'Out of reach',
                  style: TextStyle(
                    fontSize: GlType.text2xs,
                    fontWeight: FontWeight.w600,
                    color: GlColors.warning,
                  ),
                ),
              ),
            if (available && isEnabled)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: GlSpace.s2, vertical: 2),
                decoration: BoxDecoration(
                  color: GlColors.successSoft,
                  borderRadius: GlRadius.rPill,
                ),
                child: Text(
                  'Priority $priority',
                  style: const TextStyle(
                    fontSize: GlType.text2xs,
                    fontWeight: FontWeight.w600,
                    color: GlColors.success,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          !available ? 'Not available on this device' : subtitle,
          style: TextStyle(
            color: isEnabled ? GlColors.textMuted : GlColors.textSubtle,
            fontSize: GlType.textSm,
          ),
        ),
        trailing: Switch(
          value: value,
          onChanged: available ? onChanged : null,
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
          const Row(
            children: [
              Icon(Icons.bug_report_outlined,
                  size: 16, color: GlColors.warning),
              SizedBox(width: 6),
              Text(
                'BLE role (debug)',
                style: TextStyle(
                  fontSize: GlType.textSm,
                  fontWeight: FontWeight.w600,
                  color: GlColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s1),
          Text(
            switch (mode) {
              BleRoleMode.auto =>
                'Scan + advertise. Paths form as each BLE stack allows.',
              BleRoleMode.centralOnly =>
                'Scan only — peers cannot dial us; we only get central paths.',
              BleRoleMode.peripheralOnly =>
                'Advertise only — we never dial; peers reach us as peripheral.',
            },
            style: const TextStyle(
                fontSize: GlType.textXs, color: GlColors.textMuted),
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

  Widget _buildFacilitateInvitesSection() {
    final settings = widget.store.state.settings;
    final coldCallOpen = settings.coldCallTrustLevel == ColdCallTrustLevel.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: GlSpace.s4, vertical: GlSpace.s2),
          child: EyebrowLabel('Introductions', color: GlColors.accentOnSoft),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: GlSpace.s4),
          child: Text(
            'Lend a hand so a friend can reach someone new: help connect a '
            'stranger who is redeeming an invite one of your friends sent. '
            'You never learn their messages — only pass along a first hello.',
            style:
                TextStyle(color: GlColors.textMuted, fontSize: GlType.textSm),
          ),
        ),
        SwitchListTile(
          value: settings.facilitateInvites && coldCallOpen,
          onChanged: coldCallOpen
              ? (v) => widget.store.dispatch(SetFacilitateInvitesAction(v))
              : null,
          title: const Text('Help introduce newcomers'),
          subtitle: Text(
            coldCallOpen
                ? (settings.facilitateInvites ? 'On' : 'Off')
                : 'Turn on “meeting new peers” first',
            style: TextStyle(
              color: coldCallOpen ? GlColors.textMuted : GlColors.textSubtle,
              fontSize: GlType.textSm,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTraceLoggingSection() {
    final settings = widget.store.state.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: GlSpace.s4, vertical: GlSpace.s2),
          child:
              EyebrowLabel('Diagnostic traces', color: GlColors.accentOnSoft),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: GlSpace.s4),
          child: Text(
            'Opt in to collect anonymous diagnostic traces on this device. '
            'The app asks on every start before uploading, or upload manually '
            'below.',
            style:
                TextStyle(color: GlColors.textMuted, fontSize: GlType.textSm),
          ),
        ),
        SwitchListTile(
          value: settings.traceLoggingConsent,
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
          const Row(
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 16, color: GlColors.primary),
              SizedBox(width: 6),
              Text(
                'Meeting new peers',
                style: TextStyle(
                  fontSize: GlType.textSm,
                  fontWeight: FontWeight.w600,
                  color: GlColors.primaryOnSoft,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s1),
          const Text(
            'Controls whether you reply when a nearby peer you have not '
            'friended yet says hello over Bluetooth.\n\n'
            '• Open — anyone in range can introduce themselves, so you can '
            'meet new peers. Strangers learn your public key and nickname, '
            'but never your address or any friend-only details.\n'
            '• Closed — introductions from non-friends are refused. Nearby '
            'devices still see your advertisement, but strangers cannot '
            'learn your nickname over Bluetooth.',
            style: TextStyle(
                fontSize: GlType.textXs, color: GlColors.textMuted),
          ),
          const SizedBox(height: GlSpace.s2),
          Text(
            switch (level) {
              ColdCallTrustLevel.open =>
                'Currently open: nearby unknown peers can introduce '
                    'themselves.',
              ColdCallTrustLevel.closed =>
                'Currently closed: only accepted friends can say hello over '
                    'Bluetooth.',
            },
            style: const TextStyle(
              fontSize: GlType.textXs,
              color: GlColors.primaryOnSoft,
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
      color: isWellConnected ? GlColors.successSoft : GlColors.bgSunken,
      child: Padding(
        padding: const EdgeInsets.all(GlSpace.s3),
        child: Row(
          children: [
            Icon(
              isWellConnected ? Icons.language_rounded : Icons.shield_outlined,
              color: isWellConnected ? GlColors.success : GlColors.textSubtle,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isWellConnected
                        ? 'Well-connected'
                        : 'Standard connection',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: GlType.textSm,
                      color: isWellConnected
                          ? GlColors.moss700
                          : GlColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isWellConnected
                        ? 'Anyone can reach you directly — you can lend your link to help friends connect'
                        : 'You are behind NAT — a well-connected friend helps your connections find their way',
                    style: const TextStyle(
                      fontSize: GlType.text2xs,
                      color: GlColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        _networkTypeIcon(connectionType),
                        size: 14,
                        color: GlColors.textSubtle,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Connection type: ${connectionType.displayName}',
                        style: const TextStyle(
                          fontSize: GlType.text2xs,
                          color: GlColors.textSubtle,
                        ),
                      ),
                    ],
                  ),
                  if (publicIp != null || publicAddress != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      publicAddress ?? publicIp!,
                      style: GlType.monoStyle(GlType.text2xs,
                          color: GlColors.textSubtle),
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
        const Icon(
          Icons.warning_amber_rounded,
          size: 14,
          color: GlColors.warning,
        ),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            'No public IP address available',
            style: TextStyle(
              fontSize: GlType.text2xs,
              color: GlColors.warning,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: GlSpace.s1),
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
                : const Icon(Icons.refresh_rounded, size: 14),
            label: const Text(
              'Retry',
              style: TextStyle(fontSize: GlType.text2xs),
            ),
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
      padding: const EdgeInsets.all(GlSpace.s4),
      decoration: BoxDecoration(
        color: GlColors.primarySoft,
        borderRadius: GlRadius.rLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SignalDot(size: 12),
              SizedBox(width: GlSpace.s2),
              Text(
                'How the mesh works',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: GlColors.primaryOnSoft,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s3),
          _buildInfoRow(
            icon: Icons.bluetooth_rounded,
            iconColor: GlColors.primaryOnSoft,
            text: 'Bluetooth reaches neighbours nearby — no Internet needed',
          ),
          const SizedBox(height: GlSpace.s2),
          _buildInfoRow(
            icon: Icons.public_rounded,
            iconColor: GlColors.primaryOnSoft,
            text: 'Internet reaches peers anywhere in the world',
          ),
          const SizedBox(height: GlSpace.s2),
          _buildInfoRow(
            icon: Icons.route_rounded,
            iconColor: GlColors.primaryOnSoft,
            text: 'When both are on, messages take the nearest path first',
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
        title: const Text('Keep one link on'),
        content: const Text(
          'You need at least one way to reach your peers — Bluetooth or '
          'Internet.',
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
