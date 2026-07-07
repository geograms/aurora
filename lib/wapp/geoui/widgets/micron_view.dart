// A renderer for NomadNet "micron" markup (the page format served by
// nomadnetwork.node peers). Parses the backtick-command grammar into styled
// text, headings, dividers, tappable links, and input fields.
//
// Grammar (from NomadNet's MicronParser): backtick is the format char.
//   `!  bold toggle   `_  underline toggle   `*  italic toggle
//   `F<rgb> / `FT<rrggbb>  fg colour   `f reset fg   `B.. bg (ignored on dark)
//   `c center  `l left  `r right  `a default
//   `  (bare) reset all formatting     \`  literal backtick
//   `[label`url`fields]  link (fields = pipe-delimited field_a=1|field_b)
//   `<flags|name`value>  input field  (? checkbox, numeric = width)
//   line >… heading (depth = number of >)   line -… divider
//
// Links + field submits are surfaced through [onLink]; text fields collect into
// a shared map so a submit link carries them.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class MicronView extends StatefulWidget {
  final String source;
  // A link/submit was tapped: [url] is the target (":/page/x.mu" = same node),
  // [fields] merges the link's own vars with any on-page input field values.
  final void Function(String url, Map<String, String> fields)? onLink;
  final EdgeInsets padding;
  const MicronView(this.source,
      {this.onLink,
      this.padding = const EdgeInsets.all(16),
      super.key});

  @override
  State<MicronView> createState() => _MicronViewState();
}

class _Style {
  bool bold = false, underline = false, italic = false;
  Color? fg;
  void reset() {
    bold = underline = italic = false;
    fg = null;
  }

  _Style clone() => _Style()
    ..bold = bold
    ..underline = underline
    ..italic = italic
    ..fg = fg;
}

class _MicronViewState extends State<MicronView> {
  static const _fg = Color(0xFFE6E9EF);
  static const _muted = Color(0xFF8B95A7);
  static const _link = Color(0xFF5B9DFF);

  // Live input-field controllers/values, keyed by field name, so a submit link
  // can gather the current page inputs.
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _checks = {};

  @override
  void didUpdateWidget(covariant MicronView old) {
    super.didUpdateWidget(old);
    // New page loaded — drop stale field state.
    if (old.source != widget.source) {
      for (final c in _text.values) {
        c.dispose();
      }
      _text.clear();
      _checks.clear();
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Color? _hexColor(String hex) {
    try {
      if (hex.length == 3) {
        final r = int.parse(hex[0] * 2, radix: 16);
        final g = int.parse(hex[1] * 2, radix: 16);
        final b = int.parse(hex[2] * 2, radix: 16);
        return Color.fromARGB(255, r, g, b);
      }
      if (hex.length == 6) {
        return Color(0xFF000000 | int.parse(hex, radix: 16));
      }
    } catch (_) {}
    return null;
  }

  TextStyle _ts(_Style s, double size) => TextStyle(
        color: s.fg ?? _fg,
        fontSize: size,
        height: 1.42,
        fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
        fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
        decoration:
            s.underline ? TextDecoration.underline : TextDecoration.none,
      );

  void _fire(String url, String fieldStr) {
    final fields = <String, String>{};
    // The link's own vars: field_a=1|field_b (bare name → its live input value).
    for (final part in fieldStr.split('|')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      if (eq >= 0) {
        fields[part.substring(0, eq)] = part.substring(eq + 1);
      } else {
        // Bare name → pull the current on-page input value.
        final t = _text[part];
        if (t != null) {
          fields[part] = t.text;
        } else if (_checks.containsKey(part)) {
          fields[part] = _checks[part]! ? '1' : '0';
        } else {
          fields[part] = '';
        }
      }
    }
    // Also submit ALL live text fields, so a chatroom's "send" link that only
    // names its target still carries the message the user typed.
    for (final e in _text.entries) {
      fields.putIfAbsent(e.key, () => e.value.text);
    }
    widget.onLink?.call(url, fields);
  }

  // Parse one line into inline spans, mutating [s] (formatting persists across
  // lines within the document, per micron). [align] out-param via [ctx].
  List<InlineSpan> _inline(String line, _Style s, double size) {
    final spans = <InlineSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf.toString(), style: _ts(s, size)));
        buf.clear();
      }
    }

    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (c == '\\' && i + 1 < line.length && line[i + 1] == '`') {
        buf.write('`');
        i += 2;
        continue;
      }
      if (c != '`') {
        buf.write(c);
        i++;
        continue;
      }
      final n = i + 1 < line.length ? line[i + 1] : '';
      switch (n) {
        case '!':
          flush();
          s.bold = !s.bold;
          i += 2;
          continue;
        case '_':
          flush();
          s.underline = !s.underline;
          i += 2;
          continue;
        case '*':
          flush();
          s.italic = !s.italic;
          i += 2;
          continue;
        case 'f':
          flush();
          s.fg = null;
          i += 2;
          continue;
        case 'b': // reset bg — ignored (fixed dark surface)
          i += 2;
          continue;
        case 'c':
        case 'l':
        case 'r':
        case 'a':
          i += 2;
          continue; // alignment handled at block level; skip token
        case 'F':
          flush();
          var j = i + 2;
          if (j < line.length && line[j] == 'T') {
            final hex = line.substring(
                j + 1, (j + 7) <= line.length ? j + 7 : line.length);
            s.fg = _hexColor(hex);
            i = j + 7;
          } else {
            final hex =
                line.substring(j, (j + 3) <= line.length ? j + 3 : line.length);
            s.fg = _hexColor(hex);
            i = j + 3;
          }
          continue;
        case 'B':
          var j = i + 2;
          i = (j < line.length && line[j] == 'T') ? j + 7 : j + 3;
          continue;
        case '[':
          {
            flush();
            final end = line.indexOf(']', i + 2);
            if (end < 0) {
              buf.write(c);
              i++;
              continue;
            }
            final inner = line.substring(i + 2, end);
            final parts = inner.split('`');
            final label = parts.isNotEmpty ? parts[0] : '';
            final url = parts.length > 1 ? parts[1] : '';
            final fieldStr = parts.length > 2 ? parts[2] : '';
            spans.add(TextSpan(
              text: label.isNotEmpty ? label : url,
              style: _ts(s, size).copyWith(
                  color: _link, decoration: TextDecoration.underline),
              recognizer: TapGestureRecognizer()
                ..onTap = () => _fire(url, fieldStr),
            ));
            i = end + 1;
            continue;
          }
        case '<':
          {
            flush();
            final end = line.indexOf('>', i + 2);
            if (end < 0) {
              buf.write(c);
              i++;
              continue;
            }
            spans.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _fieldWidget(line.substring(i + 2, end), size),
            ));
            i = end + 1;
            continue;
          }
        default:
          // Bare backtick → reset all formatting.
          flush();
          s.reset();
          i++;
          continue;
      }
    }
    flush();
    return spans;
  }

  // An input field: `<flags|name`value>` — render a TextField (or checkbox).
  Widget _fieldWidget(String inner, double size) {
    final parts = inner.split('`');
    final head = parts.isNotEmpty ? parts[0] : ''; // flags|name
    final initial = parts.length > 1 ? parts[1] : '';
    final bar = head.indexOf('|');
    final flags = bar >= 0 ? head.substring(0, bar) : '';
    final name = (bar >= 0 ? head.substring(bar + 1) : head).trim();
    if (name.isEmpty) return const SizedBox.shrink();
    if (flags.contains('?')) {
      final checked = _checks.putIfAbsent(name, () => initial.contains('*'));
      return SizedBox(
        height: 26,
        child: Checkbox(
          value: checked,
          visualDensity: VisualDensity.compact,
          onChanged: (v) => setState(() => _checks[name] = v ?? false),
        ),
      );
    }
    final ctl = _text.putIfAbsent(name, () => TextEditingController(text: initial));
    final widthChars = int.tryParse(RegExp(r'\d+').firstMatch(flags)?.group(0) ?? '') ?? 18;
    return Container(
      width: (widthChars.clamp(6, 40)) * (size * 0.62),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      child: TextField(
        controller: ctl,
        obscureText: flags.contains('!'),
        style: TextStyle(color: _fg, fontSize: size),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          hintText: name,
          hintStyle: TextStyle(color: _muted, fontSize: size * 0.92),
          filled: true,
          fillColor: const Color(0x22FFFFFF),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none),
        ),
      ),
    );
  }

  // The alignment currently in force for a line (last `c/`r/`l/`a command).
  TextAlign _lineAlign(String line) {
    var a = TextAlign.left;
    final m = RegExp('`([clra])').allMatches(line);
    for (final g in m) {
      switch (g.group(1)) {
        case 'c':
          a = TextAlign.center;
          break;
        case 'r':
          a = TextAlign.right;
          break;
        default:
          a = TextAlign.left;
      }
    }
    return a;
  }

  @override
  Widget build(BuildContext context) {
    final s = _Style();
    final blocks = <Widget>[];
    final lines = widget.source.replaceAll('\r\n', '\n').split('\n');
    for (final raw in lines) {
      final line = raw;
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 10));
        continue;
      }
      // Divider: a line of only '-' (optionally '-<char>').
      if (RegExp(r'^\s*-').hasMatch(line) &&
          RegExp(r'^\s*-+\S?\s*$').hasMatch(line)) {
        blocks.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1, color: Color(0x33FFFFFF)),
        ));
        continue;
      }
      // Heading: leading '>' run sets depth (bigger, bold).
      var depth = 0;
      var content = line;
      final h = RegExp(r'^(>+)\s?').firstMatch(line);
      if (h != null) {
        depth = h.group(1)!.length;
        content = line.substring(h.end);
        final hs = s.clone()..bold = true;
        final size = (20.0 - (depth - 1) * 2).clamp(14.0, 20.0);
        blocks.add(Padding(
          padding: EdgeInsets.only(top: depth == 1 ? 10 : 6, bottom: 4),
          child: Text.rich(
            TextSpan(children: _inline(content, hs, size)),
            textAlign: _lineAlign(line),
          ),
        ));
        continue;
      }
      final align = _lineAlign(line);
      blocks.add(Text.rich(
        TextSpan(children: _inline(content, s, 14.0)),
        textAlign: align,
      ));
    }
    return ListView(
      padding: widget.padding,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks),
      ],
    );
  }
}
