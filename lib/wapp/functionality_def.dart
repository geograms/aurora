/*
 * Functionality API definition data classes.
 *
 * These describe the endpoint signatures (params, return types) of a
 * functionality so alternative providers know exactly what contract they
 * must implement. They live in their own file — separate from
 * [FunctionalityRegistry] — so that other subsystems (e.g. lib/connections/,
 * which owns the transport HAL definitions) can build [FunctionalityDef]s
 * without importing the registry and creating an import cycle.
 *
 * [FunctionalityRegistry] re-exports this file, so existing call sites that
 * import functionality_registry.dart keep compiling unchanged.
 */

class ParamDef {
  final String name;
  final String type;
  final String description;
  const ParamDef(this.name, this.type, [this.description = '']);

  factory ParamDef.fromJson(Map<String, dynamic> json) => ParamDef(
        json['name'] as String? ?? '',
        json['type'] as String? ?? 'any',
        json['description'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (description.isNotEmpty) 'description': description,
      };
}

class ReturnDef {
  final String type;
  final String description;
  final Map<String, String> fields;
  const ReturnDef(this.type, [this.description = '', this.fields = const {}]);

  factory ReturnDef.fromJson(dynamic json) {
    if (json is String) return ReturnDef(json);
    if (json is Map<String, dynamic>) {
      final fields = <String, String>{};
      final rawFields = json['fields'];
      if (rawFields is Map) {
        for (final e in rawFields.entries) {
          fields[e.key.toString()] = e.value?.toString() ?? 'any';
        }
      }
      return ReturnDef(
        json['type'] as String? ?? 'void',
        json['description'] as String? ?? '',
        fields,
      );
    }
    return const ReturnDef('void');
  }
}

class EndpointDef {
  final String name;
  final String description;
  final List<ParamDef> params;
  final ReturnDef returns;
  const EndpointDef(this.name, this.description, this.params, this.returns);

  factory EndpointDef.fromJson(Map<String, dynamic> json) {
    final rawParams = json['params'];
    final params = rawParams is List
        ? rawParams
            .whereType<Map<String, dynamic>>()
            .map(ParamDef.fromJson)
            .toList()
        : const <ParamDef>[];
    return EndpointDef(
      json['name'] as String? ?? '',
      json['description'] as String? ?? '',
      params,
      ReturnDef.fromJson(json['returns'] ?? 'void'),
    );
  }
}

class FunctionalityDef {
  final String id;
  final String description;
  final List<EndpointDef> endpoints;
  const FunctionalityDef(this.id, this.description,
      [this.endpoints = const []]);

  factory FunctionalityDef.fromJson(Map<String, dynamic> json) {
    final rawEndpoints = json['endpoints'];
    final endpoints = rawEndpoints is List
        ? rawEndpoints
            .whereType<Map<String, dynamic>>()
            .map(EndpointDef.fromJson)
            .toList()
        : const <EndpointDef>[];
    return FunctionalityDef(
      json['id'] as String? ?? '',
      json['description'] as String? ?? '',
      endpoints,
    );
  }
}
