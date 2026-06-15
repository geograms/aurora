import 'dart:io';
import 'package:aurora/services/i2p/i2p_structures.dart';
String hx(List<int> b)=>b.map((x)=>x.toRadixString(16).padLeft(2,'0')).join();
void main(List<String> a) {
  final ri = parseRouterInfo(File(a[0]).readAsBytesSync())!;
  for (final ad in ri.addresses) {
    print('style=${ad.style} opts.keys=${ad.options.keys.toList()}');
    final s = ad.staticKey;
    if (s!=null) print('  s = ${hx(s)}');
  }
  final keys = File('${File(a[0]).parent.path}/ntcp2.keys').readAsBytesSync();
  print('ntcp2.keys len=${keys.length}');
  print('  [0:32]   = ${hx(keys.sublist(0,32))}');
  print('  [32:64]  = ${hx(keys.sublist(32,64))}');
  print('  [64:80]  = ${hx(keys.sublist(64,80))}');
}
