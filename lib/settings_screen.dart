import 'dart:async';
import 'dart:typed_data';

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
import 'src/trace/experiment_recorder.dart';
import 'src/transport/transport_service.dart';

/// Settings screen for configuring transport protocols
class SettingsScreen extends StatefulWidget {
  final Store<AppState> store;

  /// Callback when settings are changed
  final VoidCallback? onSettingsChanged;

  /// Debug-only: switch which BLE roles the local device runs.
  final Future<void> Function(BleRoleMode mode)? onBleRoleModeChanged;

  /// Apply an open ⇄ closed trust change. Routed through the network rather
  /// than dispatched here, because closing has to re-filter the BLE scanner
  /// at once — a store dispatch alone would leave the node meeting strangers
  /// until the scan watchdog next fires.
  final Future<void> Function(ColdCallTrustLevel level)? onColdCallTrustChanged;

  /// Re-run public-address (seeip) discovery, invoked by the "Retry" button
  /// shown when discovery has failed and no IP is known.
  final Future<void> Function()? onRetryPublicAddressDiscovery;

  /// Debug/testbed hooks, forwarded to [TestbedScreen]. Null when the network
  /// is not up. [myPubkeyHex] is this device's hex identity.
  final String? myPubkeyHex;

  /// This device's ANNOUNCE nickname, forwarded to the testbed so a field
  /// run can derive its join order from it.
  final String? myNickname;
  final ExperimentRecorder? experimentRecorder;
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId})? sendMessage;
  /// Drop EVERY Noise session. Forwarded to the testbed, and also driven by
  /// the session table's "Clear all" — behind a confirmation in both places,
  /// because a purge is unrecoverable mid-run (see [onResetSessionWith]).
  final VoidCallback? onResetSessions;

  /// Drop the Noise session with exactly this peer.
  ///
  /// Routed as a callback rather than by reaching into `GrassrootsNetwork`
  /// from the widget, for the same reason every other hook here is: the
  /// screen renders store state and reports intent, and the coordinator is
  /// the only thing allowed to touch the session manager — it is what
  /// guarantees the manager forgets the peer BEFORE the store is told.
  ///
  /// Destructive in a way that is easy to underestimate. A packet may not
  /// exist before a session with its target does, and the send path refuses
  /// rather than establishes, so a purged session is not a round trip the
  /// next message pays — it is every message to that peer failing at
  /// creation until the two devices are in radio range and have handshaked
  /// again. Under the ring-radius gate a non-neighbour can never re-handshake
  /// at all, so a purge mid-run kills that peer for the rest of the run.
  /// Hence the confirmation on every path that reaches it.
  final void Function(Uint8List peer)? onResetSessionWith;
  final VoidCallback? onResetDtnBuffer;

  /// DEBUG/TESTBED. Arm or disarm the ring-radius link gate.
  final Future<void> Function(List<String> rosterHex, int? radius)?
      onSetRingGate;

  /// DEBUG/TESTBED. Ignore a phone in the room that is not part of the
  /// experiment (see [SettingsState.ignoredPeerHexes]).
  final void Function(Uint8List peer)? onIgnorePeer;

  /// DEBUG/TESTBED. Lift [onIgnorePeer] for the phone with this pubkey hex.
  final void Function(String pubkeyHex)? onUnignorePeer;

  /// DEBUG/TESTBED. Sever every GATT link, keeping sessions and DTN state.
  final Future<void> Function()? onSeverLinks;
  final Future<Map<String, dynamic>> Function()? onCryptoBench;
  final bool Function()? bleUsable;
  final bool Function()? bleUndiscoverable;

  /// BLE legs held ready now, for the runner screen's readout.
  final int Function()? legsReady;
  final Stream<bool>? bleUsableChanges;
  final int Function()? sessionPeerCount;

  /// Distinct peers holding a ready link, stamped on every step marker
  /// as `links` beside `sessions`.
  final int Function()? linkPeerCount;

  /// Applies [FieldPlan.dtnMaxBytes] when a plan starts.
  final void Function(int bytes)? onSetDtnMaxBytes;

  /// Sessions in the Noise table, forwarded to the testbed.
  final int Function()? sessionTableCount;

  /// Who those sessions are with — the ring plan's roster source when
  /// [FieldPlan.ringRosterFromSessions] is set. Passed straight through to
  /// the testbed screen; the settings UI itself does not read it.
  final Iterable<String> Function()? sessionPeerHexes;
  final Future<void> Function(bool on)? onSetBle;
  final Future<void> Function(int? darkSec,
      {Future<void> Function()? whileDark, int? untilMs})?
      onResetLinks;

  final bool Function(Uint8List peer)? linkSettled;

  /// Whether a Noise session exists with this peer — what a send is gated on.
  final bool Function(Uint8List peer)? sessionUp;
  final bool? Function()? systemBtOn;
  final Future<void> Function()? refreshSystemBt;
  final Stream<Uint8List>? sessionEvents;
  final Stream<Uint8List>? linkSettledEvents;

  /// Message ids whose end-to-end ACK came home, for the throughput runner.
  final Stream<String>? ackEvents;

  /// Dial-grid hooks (see FieldRunner.onSetDialParallelism).
  final void Function({int? maxParallel, int? popN})? onSetDialParallelism;

  /// Record every advertisement sighting (see
  /// FieldPlan.traceEveryAdvertisement).
  final void Function(bool every)? onSetTraceEveryAdvertisement;

  /// Raise or drop the BLE connection interval (see FieldRunner).
  final void Function(bool high)? onSetConnectionPriority;

  /// Set the fragment spacing for a step (null restores production).
  final void Function(int? ms)? onSetFragmentDelay;

  /// Deliver without acknowledging, for a one-directional run.
  final void Function(bool on)? onSetSuppressAcks;

  /// Silence everything that is not payload for the run.
  final Future<void> Function(bool on)? onSetQuietLink;

  /// Suspend eviction of quiet peers for the whole run.
  final void Function(bool on)? onSetStaleSweepSuspended;
  final int Function()? establishmentCount;
  final VoidCallback? onResetEstablishmentCount;


  const SettingsScreen({
    super.key,
    required this.store,
    this.onSettingsChanged,
    this.onBleRoleModeChanged,
    this.onColdCallTrustChanged,
    this.onRetryPublicAddressDiscovery,
    this.myPubkeyHex,
    this.myNickname,
    this.experimentRecorder,
    this.sendMessage,
    this.onResetSessions,
    this.onResetSessionWith,
    this.onResetDtnBuffer,
    this.onSetRingGate,
    this.onIgnorePeer,
    this.onUnignorePeer,
    this.onSeverLinks,
    this.onCryptoBench,
    this.bleUsable,
    this.bleUndiscoverable,
    this.legsReady,
    this.bleUsableChanges,
    this.sessionPeerCount,
    this.linkPeerCount,
    this.onSetDtnMaxBytes,
    this.sessionTableCount,
    this.sessionPeerHexes,
    this.onSetBle,
    this.onResetLinks,
    this.linkSettled,
    this.sessionUp,
    this.systemBtOn,
    this.refreshSystemBt,
    this.sessionEvents,
    this.linkSettledEvents,
    this.ackEvents,
    this.onSetDialParallelism,
    this.onSetTraceEveryAdvertisement,
    this.onSetConnectionPriority,
    this.onSetFragmentDelay,
    this.onSetSuppressAcks,
    this.onSetQuietLink,
    this.onSetStaleSweepSuspended,
    this.establishmentCount,
    this.onResetEstablishmentCount,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _bluetoothEnabled;
  late bool _udpEnabled;
  bool _isRetryingPublicAddressDiscovery = false;
  StreamSubscription<AppState>? _storeSubscription;

  /// Ring radius entry. Free numeric input rather than a fixed set of choices:
  /// the meaningful radii depend on the roster a plan brings, and a control
  /// built from whatever roster happens to be loaded offers the wrong ones the
  /// moment that roster changes — or none at all when there is none.
  final TextEditingController _ringRadiusController = TextEditingController();

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
    _ringRadiusController.dispose();
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
          if (widget.onSetRingGate != null) _buildRingRadiusSelector(),

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

          // Noise session table (debug)
          _buildSessionTableSection(),

          if (widget.onUnignorePeer != null) ...[
            const Divider(height: 32),
            _buildIgnoredPhonesSection(),
          ],

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
                      myNickname: widget.myNickname,
                      experimentRecorder: widget.experimentRecorder,
                                                      sendMessage: widget.sendMessage,
                      onResetSessions: widget.onResetSessions,
                      onResetDtnBuffer: widget.onResetDtnBuffer,
                      onSetRingGate: widget.onSetRingGate,
                      onSeverLinks: widget.onSeverLinks,
                      onCryptoBench: widget.onCryptoBench,
                      bleUsable: widget.bleUsable,
      bleUndiscoverable: widget.bleUndiscoverable,
      legsReady: widget.legsReady,
                      bleUsableChanges: widget.bleUsableChanges,
                      sessionPeerCount: widget.sessionPeerCount,
                      linkPeerCount: widget.linkPeerCount,
                      onSetDtnMaxBytes: widget.onSetDtnMaxBytes,
                      sessionTableCount: widget.sessionTableCount,
                      sessionPeerHexes: widget.sessionPeerHexes,
                      onSetBle: widget.onSetBle,
                      onResetLinks: widget.onResetLinks,
                      linkSettled: widget.linkSettled,
                      sessionUp: widget.sessionUp,
                      systemBtOn: widget.systemBtOn,
                      refreshSystemBt: widget.refreshSystemBt,
                      sessionEvents: widget.sessionEvents,
                      linkSettledEvents: widget.linkSettledEvents,
      ackEvents: widget.ackEvents,
                      onSetDialParallelism: widget.onSetDialParallelism,
                      onSetTraceEveryAdvertisement:
                          widget.onSetTraceEveryAdvertisement,
                      onSetConnectionPriority: widget.onSetConnectionPriority,
      onSetFragmentDelay: widget.onSetFragmentDelay,
      onSetSuppressAcks: widget.onSetSuppressAcks,
      onSetQuietLink: widget.onSetQuietLink,
      onSetStaleSweepSuspended: widget.onSetStaleSweepSuspended,
                      establishmentCount: widget.establishmentCount,
                      onResetEstablishmentCount:
                          widget.onResetEstablishmentCount,
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

  /// DEBUG/TESTBED. The ring-radius link gate: which radius is armed, and the
  /// switch that disarms it.
  ///
  /// Deliberately says NOTHING about the roster — not its size, not this
  /// device's position in it, not which peers the current radius reaches. A
  /// radius is a standing policy; the roster is whatever plan happens to be
  /// loaded at this instant. Describing one in terms of the other made the
  /// panel read as a live topology view, which it is not: it went stale the
  /// moment a different plan loaded, and it offered a set of radii derived
  /// from however many phones were on the desk that evening.
  ///
  /// Visible because the gate is PERSISTED and enforced on both ends. Without a
  /// control here an armed radius survives an app restart, a device reboot, a
  /// Bluetooth stack restart and a transport toggle, and the only symptom is
  /// that two particular phones will not link — which reads exactly like a dead
  /// radio and cost an evening before this existed. Worse, it is
  /// self-perpetuating: the ring sweep's own warm-up needs every pair to
  /// handshake, and a gate left armed refuses the very links that warm-up
  /// depends on, so the run can never start again.
  ///
  /// The roster is not editable here. It arrives with a plan and is hardware,
  /// not policy; this screen only says which of it is currently reachable and
  /// lets the constraint be lifted.
  Widget _buildRingRadiusSelector() {
    final radius = widget.store.state.settings.ringRadius;

    Future<void> apply(int? next) async {
      await widget.onSetRingGate
          ?.call(widget.store.state.settings.ringRoster, next);
      widget.onSettingsChanged?.call();
      _ringRadiusController.text = next?.toString() ?? '';
      if (mounted) setState(() {});
    }

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
                'Ring radius (debug)',
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
            radius == null
                ? 'Off. Link formation is unconstrained.'
                : 'Armed at $radius: a link may only span $radius hop(s) '
                    'around the ring, which is ordered by sorted pubkey. '
                    'Peers further round are refused, in both directions.',
            style: const TextStyle(
                fontSize: GlType.textXs, color: GlColors.textMuted),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _ringRadiusController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'radius',
                    hintText: 'off',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) async {
                    // Blank, zero or nonsense all mean off. A radius of zero
                    // would permit no link at all, which is never what anyone
                    // wants from a text field and is better spelled "off".
                    final parsed = int.tryParse(v.trim());
                    await apply(parsed == null || parsed <= 0 ? null : parsed);
                  },
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final parsed =
                      int.tryParse(_ringRadiusController.text.trim());
                  await apply(parsed == null || parsed <= 0 ? null : parsed);
                },
                child: const Text('Apply'),
              ),
              TextButton(
                onPressed: radius == null ? null : () => apply(null),
                child: const Text('Off'),
              ),
            ],
          ),
        ],
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
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.store.state.settings.showLinkDiagnostics,
            onChanged: (v) {
              widget.store.dispatch(SetShowLinkDiagnosticsAction(v));
              widget.onSettingsChanged?.call();
              setState(() {});
            },
            title: const Text(
              'Link diagnostics (debug)',
              style: TextStyle(
                  fontSize: GlType.textSm, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Show what each pair\'s connection is made of: legs on peer rows '
              'and in chat, where 2 legs means the pair converged to dual-role, '
              'and this device\'s ACL count beside the Nearby totals. Ground '
              'truth from the OS.',
              style: TextStyle(
                  fontSize: GlType.textXs, color: GlColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// Every Noise session this device currently holds, one row each, with a
  /// per-row purge and a purge-everything button.
  ///
  /// Read from the SESSIONS slice and NOT from the peer list, and the two are
  /// genuinely different sets — this is the whole reason the section is worth
  /// having. A session is keyed by identity and lives until an explicit
  /// reset; a peer record is presence-scoped, and the stale sweep deletes a
  /// quiet non-friend from `peersList` after ten silent announce cycles while
  /// its session survives untouched. That peer is still perfectly sendable —
  /// `hasSession` short-circuits the establish, the message seals and goes to
  /// the DTN buffer — so a table driven off `peersList` would hide exactly
  /// the sessions whose existence is least obvious from anywhere else in the
  /// UI. Iterating the session slice and looking the peer record up
  /// OPTIONALLY (falling back to the pubkey prefix for a name) is what makes
  /// those rows visible.
  ///
  /// Rows are ordered by pubkey hex, not by recency. Recency is the more
  /// interesting sort and it was the first instinct, but each row carries a
  /// destructive button: a list that reorders when a handshake completes
  /// moves a delete target under the operator's finger between the glance and
  /// the tap, and the thing they would hit by mistake is unrecoverable
  /// mid-run. A deterministic order costs nothing and cannot do that.
  Widget _buildSessionTableSection() {
    final sessions = widget.store.state.sessions;
    final hexes = sessions.peerHexes.toList()..sort();
    final now = DateTime.now().millisecondsSinceEpoch;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.vpn_key_outlined, size: 16, color: GlColors.warning),
              SizedBox(width: 6),
              Text(
                'Noise sessions (debug)',
                style: TextStyle(
                  fontSize: GlType.textSm,
                  fontWeight: FontWeight.w600,
                  color: GlColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s1),
          const Text(
            'Peers this device can seal a message to right now. A session '
            'outlives the link that formed it, so a peer here may be out of '
            'range and still sendable — the message is carried. A peer that '
            'is NOT here cannot be messaged at all: a packet is never created '
            'without a session, and only a fresh handshake at direct range '
            'brings one back.',
            style: TextStyle(
                fontSize: GlType.textXs, color: GlColors.textMuted),
          ),
          const SizedBox(height: GlSpace.s2),
          Text(
            hexes.isEmpty
                ? 'No sessions — nothing can be messaged from this device.'
                : '${hexes.length} session${hexes.length == 1 ? '' : 's'}',
            style: const TextStyle(
              fontSize: GlType.textXs,
              color: GlColors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: GlSpace.s2),
          for (final hex in hexes)
            _buildSessionRow(hex, sessions.establishedAtMs[hex]!, now),
          if (hexes.isNotEmpty) ...[
            const SizedBox(height: GlSpace.s2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onResetSessions == null
                    ? null
                    : () => _confirmClearAllSessions(hexes.length),
                icon: const Icon(Icons.delete_forever_outlined, size: 16),
                label: const Text('Clear all sessions'),
                style: TextButton.styleFrom(
                  foregroundColor: GlColors.danger,
                  textStyle: const TextStyle(fontSize: GlType.textSm),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One session row. [hex] is the peer's lowercase pubkey hex — the session
  /// slice's key and the ONLY identifier guaranteed to exist here, since the
  /// peer record it names may have been swept.
  Widget _buildSessionRow(String hex, int establishedAtMs, int nowMs) {
    final peer = widget.store.state.peers.getPeerByPubkeyHex(hex);
    final nickname = peer?.nickname ?? '';
    final named = nickname.isNotEmpty;
    final prefix = hex.length >= 16 ? hex.substring(0, 16) : hex;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // No peer record is not an error state and must not read
                  // like one: the sweep drops a quiet non-friend's record
                  // while its session stays live and sendable. The pubkey is
                  // the identity; the nickname was only ever cosmetic.
                  named ? nickname : prefix,
                  style: TextStyle(
                    fontSize: GlType.textSm,
                    fontWeight: FontWeight.w600,
                    color: named ? GlColors.textStrong : GlColors.textMuted,
                  ),
                ),
                if (named)
                  Text(
                    prefix,
                    style: GlType.monoStyle(GlType.text2xs,
                        color: GlColors.textSubtle),
                  ),
                Text(
                  '${_sessionAgeLabel(nowMs - establishedAtMs)}'
                  '${named ? '' : ' · no peer record'}',
                  style: const TextStyle(
                      fontSize: GlType.text2xs, color: GlColors.textSubtle),
                ),
              ],
            ),
          ),
          // No confirmation: ignoring lives in memory only and is undone from
          // the ignored-phones panel below.
          IconButton(
            onPressed: widget.onIgnorePeer == null
                ? null
                : () => widget.onIgnorePeer!(_pubkeyBytes(hex)),
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            color: GlColors.warning,
            tooltip: 'Ignore this phone',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: widget.onResetSessionWith == null
                ? null
                : () => _confirmResetSessionWith(hex, named ? nickname : null),
            icon: const Icon(Icons.delete_outline, size: 18),
            color: GlColors.danger,
            tooltip: 'Drop this session',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// Phones the testbed is ignoring, each with the control that lifts it.
  /// Nothing here survives a restart, which the copy says so nobody looks for
  /// a stale entry after one.
  Widget _buildIgnoredPhonesSection() {
    final hexes = widget.store.state.settings.ignoredPeerHexes.toList()..sort();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.visibility_off_outlined,
                  size: 16, color: GlColors.warning),
              SizedBox(width: 6),
              Text(
                'Ignored phones (debug)',
                style: TextStyle(
                  fontSize: GlType.textSm,
                  fontWeight: FontWeight.w600,
                  color: GlColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlSpace.s1),
          const Text(
            'Phones in range that are not part of the experiment. An ignored '
            'phone gets no session and no link, and is left out of the ring. '
            'The list is forgotten when the app restarts.',
            style: TextStyle(
                fontSize: GlType.textXs, color: GlColors.textMuted),
          ),
          const SizedBox(height: GlSpace.s2),
          if (hexes.isEmpty)
            const Text(
              'Nobody is ignored.',
              style: TextStyle(
                fontSize: GlType.textXs,
                color: GlColors.textStrong,
                fontWeight: FontWeight.w600,
              ),
            ),
          for (final hex in hexes) _buildIgnoredPhoneRow(hex),
        ],
      ),
    );
  }

  Widget _buildIgnoredPhoneRow(String hex) {
    final nickname =
        widget.store.state.peers.getPeerByPubkeyHex(hex)?.nickname ?? '';
    final prefix = hex.length >= 16 ? hex.substring(0, 16) : hex;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (nickname.isNotEmpty)
                  Text(
                    nickname,
                    style: const TextStyle(
                      fontSize: GlType.textSm,
                      fontWeight: FontWeight.w600,
                      color: GlColors.textStrong,
                    ),
                  ),
                Text(
                  prefix,
                  style: GlType.monoStyle(GlType.text2xs,
                      color: GlColors.textSubtle),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => widget.onUnignorePeer!(hex),
            style: TextButton.styleFrom(
              foregroundColor: GlColors.warning,
              textStyle: const TextStyle(fontSize: GlType.textSm),
            ),
            child: const Text('Stop ignoring'),
          ),
        ],
      ),
    );
  }

  /// How long ago the session established, coarsened as it ages. The exact
  /// millisecond is never the question being asked here — "did this form in
  /// this stage or the last one" is — so seconds resolution near zero and
  /// minutes beyond it is what the label carries.
  String _sessionAgeLabel(int ageMs) {
    if (ageMs < 0) return 'established just now';
    final seconds = ageMs ~/ 1000;
    if (seconds < 60) return 'established ${seconds}s ago';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return 'established ${minutes}m ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return 'established ${hours}h ${minutes % 60}m ago';
    return 'established ${hours ~/ 24}d ${hours % 24}h ago';
  }

  /// Peer pubkey hex back to the bytes the coordinator keys on. The session
  /// slice stores hex because it is a map key; the session manager and the
  /// action both take the raw key, so exactly one conversion belongs here.
  /// A malformed key is not tolerated — it cannot be a session key, and
  /// silently skipping it would leave a delete button that does nothing.
  static Uint8List _pubkeyBytes(String hex) => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);

  Future<void> _confirmResetSessionWith(String hex, String? nickname) async {
    final who = nickname ?? hex.substring(0, hex.length >= 16 ? 16 : hex.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Drop this session?'),
        content: Text(
          'The Noise session with $who is deleted from this device. Until '
          'the two devices are in direct range and handshake again, every '
          'message to this peer FAILS at creation — no packet is made, so '
          'nothing is buffered or carried. If a link gate is active and this '
          'peer is not a current neighbour, they cannot re-handshake at all.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Drop')),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.onResetSessionWith?.call(_pubkeyBytes(hex));
  }

  Future<void> _confirmClearAllSessions(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear ALL sessions?'),
        content: Text(
          'All $count Noise session(s) are deleted from this device.\n\n'
          'If an experiment is running, this ruins the run. Every later '
          'message to a peer that is not a direct neighbour fails at '
          'creation — no packet exists without a session — and under a link '
          'gate those peers can never re-handshake, so the failures are '
          'silent and permanent for the rest of the run. Stop and restart the '
          'run rather than trying to recover it.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: GlColors.danger),
              child: const Text('Clear all')),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.onResetSessions?.call();
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
            'learn your nickname over Bluetooth. Your device also stops '
            'relaying mesh traffic for anyone but yourself, even friends\' '
            'messages passing through to someone else.',
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
            onSelectionChanged: (selection) async {
              if (selection.isEmpty) return;
              final next = selection.first;
              if (widget.onColdCallTrustChanged != null) {
                await widget.onColdCallTrustChanged!(next);
              } else {
                widget.store.dispatch(SetColdCallTrustLevelAction(next));
              }
              if (!mounted) return;
              setState(() {});
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
