/*
 * UpdatePage — the in-app Update Center (Settings → Updates).
 *
 * Shows the running version, a stable + beta release "table" pulled from GitHub
 * (geograms/aurora), release notes, and a Download → Install action for the
 * selected channel. Mirrors geogram's update page; the beta toggle opts into
 * pre-releases. Disabled on web (managed by the store/package manager).
 */

import 'package:flutter/material.dart';

import '../services/update_models.dart';
import '../services/update_service.dart';
import '../version.dart';

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final _svc = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _svc.load();
    if (mounted) setState(() {});
    if (_svc.supported) _svc.checkForUpdates();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: !_svc.supported
          ? const _WebNotice()
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Current version + check.
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.verified),
                    title: const Text('Geogram Aurora'),
                    subtitle: Text('Installed version $kAppVersion'
                        ' (build $kBuildNumber)'),
                    trailing: ValueListenableBuilder<UpdateStatus>(
                      valueListenable: _svc.status,
                      builder: (context, st, _) => st == UpdateStatus.checking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: 'Check for updates',
                              onPressed: _svc.checkForUpdates,
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Beta opt-in.
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerLow,
                  child: SwitchListTile(
                    secondary: const Icon(Icons.science_outlined),
                    title: const Text('Include beta releases'),
                    subtitle: const Text(
                        'Get pre-release builds earlier (may be unstable).'),
                    value: _svc.betaEnabled,
                    onChanged: (v) async {
                      await _svc.setBetaEnabled(v);
                      if (mounted) setState(() {});
                      _svc.checkForUpdates();
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Text('Releases',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.primary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                // Stable + beta cards.
                ValueListenableBuilder<ReleaseInfo?>(
                  valueListenable: _svc.stable,
                  builder: (context, rel, _) => _ReleaseCard(
                    channel: 'Stable',
                    icon: Icons.check_circle_outline,
                    release: rel,
                    active: !_svc.betaEnabled,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<ReleaseInfo?>(
                  valueListenable: _svc.beta,
                  builder: (context, rel, _) => _ReleaseCard(
                    channel: 'Beta',
                    icon: Icons.science_outlined,
                    release: rel,
                    active: _svc.betaEnabled,
                  ),
                ),
                const SizedBox(height: 16),
                // Error line.
                ValueListenableBuilder<UpdateStatus>(
                  valueListenable: _svc.status,
                  builder: (context, st, _) =>
                      (st == UpdateStatus.error && _svc.error != null)
                          ? Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_svc.error!,
                                  style: TextStyle(color: cs.error)),
                            )
                          : const SizedBox.shrink(),
                ),
              ],
            ),
    );
  }
}

class _ReleaseCard extends StatefulWidget {
  final String channel;
  final IconData icon;
  final ReleaseInfo? release;
  final bool active; // is this the channel the action targets

  const _ReleaseCard({
    required this.channel,
    required this.icon,
    required this.release,
    required this.active,
  });

  @override
  State<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends State<_ReleaseCard> {
  bool _expanded = false;

  String _date(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final svc = UpdateService.instance;
    final r = widget.release;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: widget.active
              ? cs.primary.withAlpha(120)
              : cs.outlineVariant.withAlpha(80),
          width: widget.active ? 1.5 : 1,
        ),
      ),
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icon, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text(widget.channel,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                if (r != null)
                  Text(_date(r.publishedAt),
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 6),
            if (r == null)
              Text('No release found',
                  style: TextStyle(color: cs.onSurfaceVariant))
            else ...[
              Row(
                children: [
                  Text(r.version,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                  const SizedBox(width: 8),
                  _statusChip(context, r),
                ],
              ),
              if ((r.body ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Row(
                    children: [
                      Text(_expanded ? 'Hide notes' : 'Release notes',
                          style: TextStyle(
                              fontSize: 12, color: cs.primary)),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: cs.primary),
                    ],
                  ),
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SelectableText(
                      r.body!.trim(),
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
              if (widget.active) ...[
                const SizedBox(height: 10),
                _action(context, svc, r),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BuildContext context, ReleaseInfo r) {
    final svc = UpdateService.instance;
    final cs = Theme.of(context).colorScheme;
    final (label, color) = svc.isNewer(r)
        ? ('New', cs.primary)
        : (r.version == svc.currentVersion
            ? ('Installed', cs.tertiary)
            : ('Older', cs.onSurfaceVariant));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _action(BuildContext context, UpdateService svc, ReleaseInfo r) {
    if (!svc.isNewer(r)) {
      return Text('You are up to date.',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.tertiary));
    }
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: svc.status,
      builder: (context, st, _) {
        if (st == UpdateStatus.downloading) {
          return ValueListenableBuilder<double>(
            valueListenable: svc.progress,
            builder: (context, p, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: p),
                const SizedBox(height: 4),
                Text('Downloading ${(p * 100).round()}%',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          );
        }
        if (st == UpdateStatus.downloaded) {
          return FilledButton.icon(
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: Text('Install ${r.version}'),
            onPressed: () => svc.install(r),
          );
        }
        return FilledButton.icon(
          icon: const Icon(Icons.download, size: 18),
          label: Text('Download ${r.version}'),
          onPressed: () => svc.download(r),
        );
      },
    );
  }
}

class _WebNotice extends StatelessWidget {
  const _WebNotice();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'In-app updates are available on the Android, Linux and Windows '
            'builds. On the web, reload to get the latest version.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}
