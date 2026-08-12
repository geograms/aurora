// The `uptime:`/`lifetime:` qty formatter (docs/XPRS.md section 10.5) — the
// same ranges the ESP32's xprs_fmt_duration uses (geogram_xprs), so the two
// stations describe themselves in the same units.
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/xprs/xprs_vocab.dart';

void main() {
  test('xprsFmtDuration picks the unit the reading deserves', () {
    expect(xprsFmtDuration(0), '0s');
    expect(xprsFmtDuration(119), '119s');
    expect(xprsFmtDuration(120), '2min');
    expect(xprsFmtDuration(7199), '119min');
    expect(xprsFmtDuration(7200), '2h');
    expect(xprsFmtDuration(48 * 3600 - 1), '47h');
    expect(xprsFmtDuration(48 * 3600), '2day');
    expect(xprsFmtDuration(94340), '26h'); // the spec's own example figure
    expect(xprsFmtDuration(38 * 86400 + 3600), '38day');
  });
}
