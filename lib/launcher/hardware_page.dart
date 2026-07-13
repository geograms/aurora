import 'package:flutter/material.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';

import '../services/preferences_service.dart';
import '../services/social/node_profile_service.dart';

/// Settings → Hardware: what this device is made of (docs/NOSTR.md).
///
/// Stated ONCE, for the device, and read by every role — a box volunteered as
/// both an Indexer and an Archiver must not be asked twice what it is plugged
/// into, and two answers that can disagree is a bug waiting to be filed.
///
/// Full-size on purpose: the value is in the *combinations* — power source ×
/// uplink × which radios are actually attached — and a settings row cannot lay
/// that out.
///
/// Nothing here is a boast. The device announces facts; every other node scores
/// them for itself, and what it has *observed* about us always beats what we
/// *claimed*. So the page shows the measured numbers next to the stated ones,
/// where the two can be compared honestly.
class HardwarePage extends StatefulWidget {
  const HardwarePage({super.key});

  @override
  State<HardwarePage> createState() => _HardwarePageState();
}

class _HardwarePageState extends State<HardwarePage> {
  PreferencesService? _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = PreferencesService.instanceSync;
  }

  NodeProfileService get _svc => NodeProfileService.instance;

  void _save(VoidCallback change) {
    setState(change);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _prefs;
    if (p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final profile = _svc.build();

    return Scaffold(
      appBar: AppBar(title: const Text('Hardware')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'What this device is made of. Other nodes use it to decide who to '
            'ask for what — and on the day the grid goes down, a machine that '
            'is still running matters more than a fast one that is not.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          _header(context, 'Power'),
          _card(
            cs,
            Column(children: [
              // A dropdown belongs in the BODY of the row, not in a ListTile's
              // trailing slot: given a wide child, the tile crushes its title to
              // one letter per line. Full-width field, label above.
              _field(
                cs,
                icon: Icons.bolt,
                label: 'Power source',
                child: DropdownButton<int>(
                  value: p.nodePower,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('Not stated')),
                    for (var i = 0; i < PowerSource.values.length - 1; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(_powerLabel(PowerSource.values[i])),
                      ),
                  ],
                  onChanged: (v) => _save(() => p.nodePower = v ?? -1),
                ),
              ),
              _field(
                cs,
                icon: Icons.battery_charging_full,
                label: 'Autonomy without grid or sun',
                value: p.nodeAutonomyHours == 0
                    ? 'Unknown'
                    : '${p.nodeAutonomyHours} hours on the battery bank',
                child: Slider(
                  value: p.nodeAutonomyHours.clamp(0, 168).toDouble(),
                  max: 168,
                  divisions: 24,
                  onChanged: (v) => _save(() => p.nodeAutonomyHours = v.round()),
                ),
              ),
              _measured(
                cs,
                'Powered ${profile.poweredPct}% of the last week',
                profile.poweredPct == 0
                    ? 'Not watched long enough to say — and an honest "I don\'t '
                        'know" beats a guess another node would rank us on.'
                    : 'Measured here, one sample an hour. This is what other '
                        'nodes are told; they weigh what they have seen of us '
                        'above anything we claim.',
              ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, 'Uplink'),
          _card(
            cs,
            Column(children: [
              _field(
                cs,
                icon: Icons.public,
                label: 'How this device reaches the world',
                value: 'Now: ${_uplinkLabel(profile.uplink)}',
                child: DropdownButton<int>(
                  value: p.nodeUplink,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                        value: -1, child: Text('Detect automatically')),
                    for (var i = 0; i < UplinkKind.values.length - 1; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(_uplinkLabel(UplinkKind.values[i])),
                      ),
                  ],
                  onChanged: (v) => _save(() => p.nodeUplink = v ?? -1),
                ),
              ),
              _measured(
                cs,
                profile.bwClass == 0
                    ? 'Speed not measured yet'
                    : 'Observed about ${_bw(profile.bwClass)}',
                'Satellite looks exactly like ordinary Wi-Fi from in here, and '
                'that difference is the whole point of the field — so if this '
                'runs on Starlink, say so.',
              ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, 'Coverage'),
          _card(
            cs,
            Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.place_outlined),
                title: const Text('Say where this device serves'),
                subtitle: Text(p.nodeGeohash.isEmpty
                    ? 'Off — it says nothing about where it is'
                    : 'Region ${p.nodeGeohash} · ${_precisionKm(p.nodeGeohash)}'),
                value: p.nodeGeohash.isNotEmpty,
                onChanged: (on) => _save(() => p.nodeGeohash = on ? 'u0' : ''),
              ),
              if (p.nodeGeohash.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Precision — this is what the network is told, and '
                        'nothing finer. The fine digits are never stored, so '
                        'they cannot leak later.',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      Slider(
                        value: p.nodeGeohash.length.clamp(2, 6).toDouble(),
                        min: 2,
                        max: 6,
                        divisions: 4,
                        label: _precisionKm(p.nodeGeohash),
                        onChanged: (v) => _save(() {
                          final want = v.round();
                          var g = p.nodeGeohash;
                          while (g.length < want) {
                            g += '0';
                          }
                          p.nodeGeohash = g.substring(0, want);
                        }),
                      ),
                      Text(
                        'A phone should leave this off: a device in your pocket '
                        'has no business advertising where it sleeps. Turn it on '
                        'for a gateway on a hill or a box in a village hall — '
                        'being found is the whole reason it is up there.',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, 'Radios'),
          Text(
            'One row per antenna. A machine with a LoRa hat and a VHF rig has '
            'two very different footprints, and one number would lie about '
            'both. The frequency is what makes the range usable: a range says a '
            'station could hear you, a frequency says where to call.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          _card(
            cs,
            Column(children: [
              for (final r in _svc.radios)
                ListTile(
                  leading: Icon(_linkIcon(r.link)),
                  title: Text('${_linkLabel(r.link)} · ${r.rangeKm} km'),
                  subtitle: Text([
                    if (r.freqKhz > 0) _freq(r.freqKhz),
                    if (r.mode.isNotEmpty) r.mode,
                    describeSchedule(r.schedule),
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _save(() {
                      final rs = _svc.radios..removeWhere((x) => x.link == r.link);
                      _svc.radios = rs;
                    }),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add a radio'),
                onTap: _addRadio,
              ),
            ]),
          ),
          const SizedBox(height: 24),

          _card(
            cs,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What this means',
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(_verdict(profile),
                      style: TextStyle(color: cs.onSurface)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The honest, two-mode reading of the profile. People who own hardware that
  /// matters in a disaster should be told — they are the ones who decide
  /// whether to keep it running.
  String _verdict(NodeProfile p) {
    final normal = p.uplink == UplinkKind.fibre || p.uplink == UplinkKind.wifi
        ? 'On a normal day this is a useful, fast node.'
        : p.uplink == UplinkKind.cellular
            ? 'On a normal day this is an ordinary phone: it reads and posts, '
                'and it serves strangers nothing on a metered plan.'
            : 'On a normal day this is an ordinary node.';

    if (p.gridIndependent && p.uplinkIndependent && p.reachableOffgrid) {
      return '$normal\n\nIf the grid goes down it becomes one of the most '
          'valuable nodes your network has: still powered, a path out that no '
          'local infrastructure can take away, and reachable over the air by '
          'people with no signal at all. Keep it running.';
    }
    if (p.gridIndependent && p.reachableOffgrid) {
      return '$normal\n\nIf the grid goes down it keeps working and stays '
          'reachable over the air — which is exactly when a neighbourhood needs '
          'a node like this one.';
    }
    if (p.gridIndependent) {
      return '$normal\n\nIt survives a power cut. Adding a LoRa antenna would '
          'make it reachable when the internet goes too.';
    }
    if (p.reachableOffgrid) {
      return '$normal\n\nIt can be reached without the internet, but it dies '
          'with the grid. A battery or a panel would change that.';
    }
    return '$normal\n\nIt depends on the grid and on somebody else\'s network. '
        'That is fine — most devices do, and the mesh is built out of them.';
  }

  Future<void> _addRadio() async {
    var link = LinkFlag.lora;
    var range = 5;
    var freq = 868200;
    var mode = 'LoRa-SF7BW125';
    var schedule = 'always';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add a radio'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: link,
                  decoration: const InputDecoration(labelText: 'Link'),
                  items: const [
                    DropdownMenuItem(value: LinkFlag.lora, child: Text('LoRa')),
                    DropdownMenuItem(
                        value: LinkFlag.packetRadio,
                        child: Text('Packet radio / AX.25')),
                    DropdownMenuItem(
                        value: LinkFlag.bluetooth, child: Text('Bluetooth')),
                    DropdownMenuItem(
                        value: LinkFlag.wifiDirect, child: Text('Wi-Fi Direct')),
                  ],
                  onChanged: (v) => setLocal(() => link = v ?? LinkFlag.lora),
                ),
                TextFormField(
                  initialValue: '$range',
                  decoration: const InputDecoration(
                      labelText: 'Range (km)',
                      helperText: 'How far it really reaches. You know; no API '
                          'does.'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => range = int.tryParse(v) ?? range,
                ),
                TextFormField(
                  initialValue: '$freq',
                  decoration: const InputDecoration(
                    labelText: 'Listening frequency (kHz)',
                    helperText: '868200, 433775, 144800… 0 if not applicable.',
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => freq = int.tryParse(v) ?? freq,
                ),
                TextFormField(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  onChanged: (v) => mode = v,
                ),
                TextFormField(
                  initialValue: schedule,
                  decoration: const InputDecoration(
                    labelText: 'When it listens',
                    helperText: 'always · every 30m for 3m · 06:00-18:00 · '
                        'dawn-dusk',
                  ),
                  onChanged: (v) => schedule = v,
                ),
                const SizedBox(height: 8),
                Text(
                  describeSchedule(ListeningSchedule.parse(schedule)),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final rs = _svc.radios
      ..removeWhere((r) => r.link == link)
      ..add(RadioEntry(
        link: link,
        rangeKm: range,
        freqKhz: freq,
        mode: mode,
        schedule: ListeningSchedule.parse(schedule),
      ));
    _save(() => _svc.radios = rs);
  }

  Widget _header(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )),
      );

  /// A full-width labelled control. Deliberately NOT a ListTile with a wide
  /// `trailing`: that layout crushes the title into one letter per line the
  /// moment the control needs room.
  Widget _field(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    String? value,
    required Widget child,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(icon, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w500)),
                  if (value != null)
                    Text(value,
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12)),
                  child,
                ],
              ),
            ),
          ],
        ),
      );

  Widget _card(ColorScheme cs, Widget child) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: child,
      );

  Widget _measured(ColorScheme cs, String title, String why) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.insights, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w500)),
                  Text(why,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );

  static String _powerLabel(PowerSource p) => switch (p) {
        PowerSource.solarBattery => 'Solar + battery',
        PowerSource.windHydro => 'Wind / hydro',
        PowerSource.solar => 'Solar (daylight only)',
        PowerSource.gridUps => 'Grid + UPS',
        PowerSource.grid => 'Grid',
        PowerSource.vehicle => 'Vehicle',
        PowerSource.batteryOnly => 'Battery only',
        PowerSource.unknown => 'Not stated',
      };

  static String _uplinkLabel(UplinkKind u) => switch (u) {
        UplinkKind.satellite => 'Satellite (Starlink…)',
        UplinkKind.fibre => 'Wired / fibre',
        UplinkKind.wifi => 'Wi-Fi',
        UplinkKind.cellular => 'Cellular',
        UplinkKind.none => 'None — offgrid, mesh only',
        UplinkKind.unknown => 'Unknown',
      };

  static String _linkLabel(int l) => switch (l) {
        LinkFlag.lora => 'LoRa',
        LinkFlag.packetRadio => 'Packet radio',
        LinkFlag.bluetooth => 'Bluetooth',
        LinkFlag.wifiDirect => 'Wi-Fi Direct',
        LinkFlag.serial => 'Serial',
        _ => 'Radio',
      };

  static IconData _linkIcon(int l) => switch (l) {
        LinkFlag.lora => Icons.settings_input_antenna,
        LinkFlag.packetRadio => Icons.radio,
        LinkFlag.bluetooth => Icons.bluetooth,
        LinkFlag.wifiDirect => Icons.wifi_tethering,
        _ => Icons.cable,
      };

  static String _freq(int khz) => khz % 1000 == 0
      ? '${khz ~/ 1000} MHz'
      : '${(khz / 1000).toStringAsFixed(3)} MHz';

  static String _bw(int cls) {
    final bps = 1 << cls;
    if (bps > 1000000) return '${(bps / 1000000).toStringAsFixed(1)} MB/s';
    if (bps > 1000) return '${(bps / 1000).toStringAsFixed(0)} kB/s';
    return '$bps B/s';
  }

  /// What a geohash of this length actually promises.
  static String _precisionKm(String g) => switch (g.length) {
        <= 2 => 'a country, ±630 km',
        3 => 'a region, ±78 km',
        4 => 'a district, ±20 km',
        5 => 'a town, ±2.4 km',
        _ => 'a neighbourhood, ±0.6 km',
      };
}
