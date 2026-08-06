// Architecture guard — the rules in docs/architecture.md, machine-checked.
//
// Reviews do not catch these. A feature built in the wrong layer works, and a
// blocking call on the UI isolate is invisible until the device is busy. Both
// mistakes have been made here more than once, months apart, by people who knew
// the rule. So the rule is checked instead of remembered.
//
//   dart tool/arch_guard.dart              check; exit 1 on a NEW violation
//   dart tool/arch_guard.dart --list       every violation, baseline included
//   dart tool/arch_guard.dart --baseline   re-record the baseline (deliberate)
//
// Baseline, not zero-tolerance: what already exists is recorded in
// tool/arch_baseline.txt and does not fail the build; anything new does. A
// guard that fails on day one gets disabled on day two.
//
// No dependencies, on purpose — one file, plain Dart, so it keeps working.
import 'dart:io';

/// One thing we refuse to let back into the codebase.
class Rule {
  const Rule({
    required this.id,
    required this.why,
    required this.appliesTo,
    required this.pattern,
    this.exempt = const [],
    this.message,
  });

  /// Stable id — appears in the baseline, in `// arch-ignore:` and in docs.
  final String id;

  /// Why this rule exists. Printed with every violation, because a rule whose
  /// reason is unknown is a rule someone will delete.
  final String why;

  /// Path globs (simple `**`/`*` matching) this rule looks at.
  final List<String> appliesTo;

  /// What a violation looks like (compiled on use — `const` cannot hold a
  /// RegExp, and keeping the rule table const is what makes it readable).
  final String pattern;

  /// Paths inside [appliesTo] that are allowed to match.
  final List<String> exempt;

  /// Extra guidance for this specific hit.
  final String? message;
}

const rules = <Rule>[
  // ── isolates ──────────────────────────────────────────────────────────────
  Rule(
    id: 'no-blocking-io-on-ui',
    why: 'The UI isolate must never block: a synchronous read or a sleep is a '
        'dropped frame at best and an ANR on a loaded phone. Use the async '
        'form, or move the work to an isolate (docs/performance.md).',
    appliesTo: ['lib/ui/**', 'lib/wapp/**', 'lib/launcher/**', 'lib/profile/**'],
    pattern: r'\b(readAsStringSync|readAsBytesSync|writeAsStringSync|'
        r'writeAsBytesSync|readAsLinesSync|sleep)\s*\(',
  ),
  Rule(
    id: 'no-platform-channel-off-main',
    why: 'Platform channels only exist on the main isolate. Called from a '
        'spawned isolate they fail silently, which looks like a radio problem '
        'and is not.',
    appliesTo: ['lib/**/*_isolate.dart', 'lib/services/isolates/**'],
    pattern: r'\b(MethodChannel|EventChannel|Ble5Bus\.instance)\b',
  ),

  // ── layering: transports belong to the core ───────────────────────────────
  Rule(
    id: 'no-transport-in-wapp-layer',
    why: 'The wapp layer hands the core a payload and is called back. Reaching '
        'into a radio or the mesh internals from lib/wapp is how '
        'store-and-forward ended up inside the chat wapp '
        '(docs/architecture.md §1).',
    appliesTo: ['lib/wapp/**'],
    pattern: r'''import\s+['"][^'"]*(?:ble5_bus|ble_service_io|ble_gatt_|'''
        r'''ble_rns_radio|mesh_courier|mesh_store|mesh_session|mesh_custody|'''
        r'''rns_transport|rns_link|rns_packet)[^'"]*['"]''',
    message: 'Go through a service facade (RnsService, MeshService, '
        'BleService) instead.',
  ),
  Rule(
    id: 'no-app-logic-in-core',
    why: 'A core service must not know a wapp exists. Give the core a generic '
        'capability and let the wapp use it — otherwise every wapp needs its '
        'own special case in lib/.',
    appliesTo: ['lib/services/**', 'lib/connections/**'],
    pattern: r'''\b(?:wappId|appId|id)\s*==\s*['"]tools\.geogram\.\w+['"]''',
  ),

  // ── the HAL surface ───────────────────────────────────────────────────────
  Rule(
    id: 'hal-budget',
    why: 'Every hal_* verb widens the wapp/core contract forever. If a wapp '
        'needs one to make a TRANSPORT decision, the logic is on the wrong '
        'side of the line — that is exactly how hal_lxmf_pending was born.',
    appliesTo: ['lib/wapp/functionality_registry.dart'],
    // The distinction is DECIDING vs LOOKING UP. "Is there a path", "how many
    // are pending", "should this be carried" are the core's calls to make.
    // Naming things — who is reachable, which relays exist, where an address
    // points — is a directory lookup, and a wapp is allowed to ask: hal_relay_
    // reachable was reviewed under this rule and kept, because the chat wapp
    // uses it to TELL peers where its DM backups live, not to steer delivery.
    pattern: r"EndpointDef\('hal_\w*(has_path|_pending|_custody|_forward|"
        r"should_send|carrier|relay_decide)\w*'",
    message: 'Read-only diagnostics are fine but must be documented as such; '
        'a wapp must not steer delivery.',
  ),
];

/// Rules for the sibling wapps repo (C sources). Checked only when it is there.
const wappRules = <Rule>[
  Rule(
    id: 'no-transport-logic-in-wapps-repo',
    why: 'A wapp must not reimplement delivery: retries, custody, best-hope '
        'airing and reachability guessing are core concerns (MeshCourier). '
        'This exact code lived in wapps/chat/main.c and had to be removed.',
    appliesTo: ['*/main.c', '*/*.c'],
    pattern: r'\b(best_hope|bh_arm|bh_pump|store_and_forward|custody_|'
        r'hal_lxmf_pending|hal_rns_has_path)\w*\s*\(',
  ),
];

const baselinePath = 'tool/arch_baseline.txt';

void main(List<String> args) {
  final list = args.contains('--list');
  final rewrite = args.contains('--baseline');

  final root = Directory.current;
  final found = <String>[];
  final detail = <String, String>{};

  // [dir] is scanned; [rel] is what the globs match against — for this repo
  // that is the path as written in the rules ("lib/ui/x.dart"), for the sibling
  // wapps repo it is the path inside that repo ("chat/main.c").
  void scan(Directory dir, List<Rule> rs, String prefix, {bool inner = false}) {
    if (!dir.existsSync()) return;
    final base = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      var rel = f.path;
      if (inner) {
        rel = rel.startsWith(base) ? rel.substring(base.length) : rel;
      } else if (rel.startsWith('${root.path}/')) {
        rel = rel.substring(root.path.length + 1);
      } else if (rel.startsWith('./')) {
        rel = rel.substring(2);
      }
      if (rel.contains('/.') || rel.startsWith('.')) continue;
      if (!(rel.endsWith('.dart') || rel.endsWith('.c'))) continue;
      List<String> lines;
      try {
        lines = f.readAsLinesSync();
      } catch (_) {
        continue;
      }
      for (final r in rs) {
        if (!_matchesAny(rel, r.appliesTo)) continue;
        if (_matchesAny(rel, r.exempt)) continue;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//') ||
              line.trimLeft().startsWith('*') ||
              line.trimLeft().startsWith('/*')) {
            continue; // a rule name inside prose is not a violation
          }
          if (!_re(r.pattern).hasMatch(line)) continue;
          if (_ignored(lines, i, r.id)) continue;
          // Keyed on the offending LINE, not on file+rule: a baseline that
          // forgives a whole file also forgives the next violation added to
          // it, which is how a guard quietly stops guarding. Not keyed on the
          // line NUMBER either — those churn with every edit above them.
          var code = line.trim();
          if (code.length > 120) code = '${code.substring(0, 117)}...';
          final key = '$prefix$rel :: ${r.id} :: $code';
          found.add(key);
          detail[key] = '$prefix$rel:${i + 1}  $code';
        }
      }
    }
  }

  scan(Directory('lib'), rules, '');
  scan(Directory('tool'), rules, '');
  final wapps = Directory('../wapps');
  if (wapps.existsSync()) scan(wapps, wappRules, '../wapps/', inner: true);

  final uniq = found.toSet().toList()..sort();

  if (rewrite) {
    File(baselinePath).writeAsStringSync(
        '# Architecture-guard baseline — violations that predate the guard.\n'
        '# NEW violations fail the build; these do not. Shrink this file.\n'
        '# Regenerate deliberately: dart tool/arch_guard.dart --baseline\n'
        '${uniq.join('\n')}\n');
    stdout.writeln('baseline: ${uniq.length} entries -> $baselinePath');
    return;
  }

  final baseline = File(baselinePath).existsSync()
      ? File(baselinePath)
          .readAsLinesSync()
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toSet()
      : <String>{};

  final fresh = uniq.where((k) => !baseline.contains(k)).toList();
  final byId = <String, Rule>{
    for (final r in [...rules, ...wappRules]) r.id: r,
  };

  if (list) {
    stdout.writeln('all violations (${uniq.length}, '
        '${baseline.length} baselined):');
    for (final k in uniq) {
      stdout.writeln('  ${baseline.contains(k) ? "base" : "NEW "} '
          '${detail[k] ?? k}');
    }
  }

  if (fresh.isEmpty) {
    stdout.writeln('arch_guard: clean '
        '(${uniq.length} known, ${baseline.length} baselined)');
    return;
  }

  stderr.writeln('\narch_guard: ${fresh.length} NEW violation'
      '${fresh.length == 1 ? "" : "s"} of docs/architecture.md\n');
  final seen = <String>{};
  for (final k in fresh) {
    final id = k.split(' :: ').length > 1 ? k.split(' :: ')[1] : k;
    stderr.writeln('  ${detail[k] ?? k}');
    if (seen.add(id)) {
      final r = byId[id];
      if (r != null) {
        stderr.writeln('      rule: $id');
        stderr.writeln('      why:  ${r.why}');
        if (r.message != null) stderr.writeln('      fix:  ${r.message}');
      }
    }
    stderr.writeln('');
  }
  stderr.writeln('If this is genuinely right, annotate the line:');
  stderr.writeln('    // arch-ignore: <rule-id> <the reason>');
  stderr.writeln('or re-baseline deliberately and say why in the commit '
      'message:');
  stderr.writeln('    dart tool/arch_guard.dart --baseline');
  exit(1);
}

final _reCache = <String, RegExp>{};
RegExp _re(String p) => _reCache.putIfAbsent(p, () => RegExp(p));

/// `// arch-ignore: <rule> <reason>` on the line or the one above it.
bool _ignored(List<String> lines, int i, String id) {
  bool hit(String s) =>
      s.contains('arch-ignore:') &&
      s.contains(id) &&
      s.trim().length > 'arch-ignore:'.length + id.length + 8; // needs a reason
  if (hit(lines[i])) return true;
  if (i > 0 && hit(lines[i - 1])) return true;
  return false;
}

bool _matchesAny(String path, List<String> globs) {
  for (final g in globs) {
    final re = RegExp('^${RegExp.escape(g).replaceAll(r'\*\*', '.*').replaceAll(r'\*', '[^/]*')}\$');
    if (re.hasMatch(path)) return true;
  }
  return false;
}
