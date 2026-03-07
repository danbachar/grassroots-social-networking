import 'package:flutter/material.dart';
import 'package:redux/redux.dart';
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
  late bool _libp2pEnabled;

  @override
  void initState() {
    super.initState();
    _bluetoothEnabled = widget.store.state.settings.bluetoothEnabled;
    _libp2pEnabled = widget.store.state.settings.libp2pEnabled;
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

          // libp2p Toggle
          _buildTransportTile(
            icon: Icons.public,
            iconColor: Colors.green,
            title: 'Internet (libp2p)',
            subtitle: 'Connect to peers over the Internet',
            value: _libp2pEnabled,
            available: widget.store.state.transports.libp2pState != TransportState.error,
            onChanged: _onLibp2pChanged,
            priority: 2,
          ),

          const Divider(height: 32),

          // Warning if no transport enabled
          if (!_bluetoothEnabled && !_libp2pEnabled)
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
            text: 'Internet (libp2p) connects you to peers anywhere in the world',
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

  void _onBluetoothChanged(bool value) {
    // Prevent disabling both transports
    if (!value && !_libp2pEnabled) {
      _showCannotDisableDialog();
      return;
    }

    setState(() {
      _bluetoothEnabled = value;
    });

    widget.store.dispatch(SetBluetoothEnabledAction(value));
    widget.onSettingsChanged?.call();
  }

  void _onLibp2pChanged(bool value) {
    // Prevent disabling both transports
    if (!value && !_bluetoothEnabled) {
      _showCannotDisableDialog();
      return;
    }

    setState(() {
      _libp2pEnabled = value;
    });

    widget.store.dispatch(SetLibp2pEnabledAction(value));
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
