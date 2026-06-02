/*
 * DependencyResolver — decides whether a wapp's declared `requires`
 * are satisfiable on this host before it is launched.
 *
 * The model is install-driven: a wapp does not bundle its dependencies,
 * it declares them, and the user installs other wapps that provide them.
 * This resolver is the gate that turns an unmet declaration into a
 * "prompt to install" instead of a silent runtime failure.
 *
 * Three kinds of requirement are checked:
 *   - requires.functionalities → satisfied when at least one installed
 *     wapp registers as a provider in [FunctionalityRegistry].
 *   - requires.libraries → satisfied when a wapp with that exact id is
 *     installed (library wapps are matched by id, called via hal_lib_call).
 *   - requires.hal → satisfied when the tag maps to a HAL capability the
 *     runtime knows about (coreFunctionalities). Only truly-unknown tags
 *     are flagged; a tag the runtime defines is considered host business.
 *
 * Pure / no Flutter deps so it can be unit-tested in isolation.
 */

import '../main.dart' show WappManifest;
import 'functionality_registry.dart';

class UnmetDependencies {
  /// Required functionality IDs with no installed provider.
  final List<String> functionalities;

  /// Required library wapp IDs that are not installed.
  final List<String> libraries;

  /// Required HAL tags the runtime does not recognise at all.
  final List<String> hal;

  const UnmetDependencies({
    this.functionalities = const [],
    this.libraries = const [],
    this.hal = const [],
  });

  bool get isEmpty =>
      functionalities.isEmpty && libraries.isEmpty && hal.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// Flat list of every unmet requirement, for terse display.
  List<String> get all => [...functionalities, ...libraries, ...hal];
}

class DependencyResolver {
  DependencyResolver._();

  /// Resolve [manifest]'s requirements against the currently-[installed]
  /// wapps (the launcher's latest scan) and the live
  /// [FunctionalityRegistry]. Returns what is missing.
  static UnmetDependencies resolve(
    WappManifest manifest,
    List<WappManifest> installed,
  ) {
    final installedIds = installed.map((w) => w.id).toSet();

    final unmetFunc = manifest.requiredFunctionalities
        .where((id) =>
            FunctionalityRegistry.instance.providersFor(id).isEmpty)
        .toList();

    final unmetLib = manifest.requiredLibraries
        .where((id) => !installedIds.contains(id))
        .toList();

    final knownHal = FunctionalityRegistry.coreFunctionalities.keys.toSet();
    final unmetHal = manifest.requiredHal
        .where((tag) => !knownHal.contains('hal.$tag'))
        .toList();

    return UnmetDependencies(
      functionalities: unmetFunc,
      libraries: unmetLib,
      hal: unmetHal,
    );
  }
}
