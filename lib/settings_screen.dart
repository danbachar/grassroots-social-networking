import 'package:flutter/material.dart';
import 'package:redux/redux.dart';
import 'debug_log_screen.dart';
import 'src/store/app_state.dart';
import 'src/store/settings_actions.dart';
import 'src/transport/transport_service.dart';

/// Settings screen for configuring transport protocols
class SettingsScreen extends StatefulWidget {
  final Store<AppState> store;

  /// Callback when settings are changed
  final VoidCallback? onSettingsChanged;

  const SettingsScreen({
    super.key,
    required this.store,
    this.onSettingsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _bluetoothEnabled;
  late bool _udpEnabled;

  late final TextEditingController _anchorAddressController;

  @override
  void initState() {
    super.initState();
    _bluetoothEnabled = widget.store.state.settings.bluetoothEnabled;
    _udpEnabled = widget.store.state.settings.udpEnabled;

    final settings = widget.store.state.settings;
    _anchorAddressController =
        TextEditingController(text: settings.anchorAddress ?? '');
  }

  @override
  void dispose() {
    _anchorAddressController.dispose();
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
            available: widget.store.state.transports.bleState != TransportState.error,
            onChanged: _onBluetoothChanged,
            priority: 1,
          ),

          // UDP Toggle
          _buildTransportTile(
            icon: Icons.public,
            iconColor: Colors.green,
            title: 'Internet',
            subtitle: 'Connect to peers over the Internet',
            value: _udpEnabled,
            available: widget.store.state.transports.udpState != TransportState.error,
            onChanged: _onUdpChanged,
            priority: 2,
          ),

          // Internet connection status
          if (_udpEnabled && widget.store.state.transports.udpState.isUsable)
            _buildConnectionStatusBadge(),

          const Divider(height: 32),

          // Anchor Server Section
          _buildAnchorServerSection(),

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
          !available
              ? 'Not available on this device'
              : subtitle,
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

  Widget _buildConnectionStatusBadge() {
    final transports = widget.store.state.transports;
    final isWellConnected = transports.isWellConnected;
    final publicAddress = transports.publicAddress;
    final publicIp = transports.publicIp;

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
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
            text: 'When both are available, Bluetooth is preferred for faster communication',
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

  Widget _buildAnchorServerSection() {
    final hasAnchor = widget.store.state.settings.hasAnchor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.cloud_outlined, color: Color(0xFFE8A33C)),
              const SizedBox(width: 8),
              const Text(
                'Anchor Server',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE8A33C),
                ),
              ),
              if (hasAnchor) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Configured',
                    style: TextStyle(fontSize: 10, color: Colors.green),
                  ),
                ),
              ],
            ],
          ),
        ),

        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'A personal cloud server that helps your friends find each other '
            'when you\'re not nearby. The server\'s identity is derived from '
            'your key — just enter its address.',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),

        const SizedBox(height: 12),

        // Address field
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _anchorAddressController,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Server address',
              hintText: '[2600:1234::1]:9514',
              hintStyle: TextStyle(
                color: Colors.grey[700],
                fontFamily: 'monospace',
                fontSize: 14,
              ),
              prefixIcon: const Icon(Icons.dns_outlined, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Save / Clear buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _onSaveAnchor,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B3D2F),
                    foregroundColor: const Color(0xFFE8A33C),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              if (hasAnchor) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _onClearAnchor,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _onSaveAnchor() {
    final address = _anchorAddressController.text.trim();

    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server address is required')),
      );
      return;
    }

    widget.store.dispatch(SetAnchorServerAction(anchorAddress: address));
    widget.onSettingsChanged?.call();

    setState(() {}); // refresh the "Configured" badge

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Anchor server saved')),
    );
  }

  void _onClearAnchor() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Anchor Server?'),
        content: const Text(
          'Your device will stop syncing its friend list to this server. '
          'Friends will lose the signaling relay until you configure a new one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _anchorAddressController.clear();
              widget.store.dispatch(SetAnchorServerAction(anchorAddress: null));
              widget.onSettingsChanged?.call();
              setState(() {});
            },
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
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
