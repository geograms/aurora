/*
 * IwiProfile — slimmed-down profile model for the iwi launcher.
 *
 * Ported shape from geogram/lib/models/profile.dart but stripped to the
 * fields that the launcher actually cares about. The parent project's
 * Profile carries ~20 station/location/relay fields that iwi doesn't
 * need. If iwi ever needs them, add them here rather than importing
 * the parent class — the two lifecycles are intentionally decoupled.
 *
 * Persistence: written as a JSON entry inside `profiles.json` at the
 * geogram root by [ProfileService]. Never persist [nsec] anywhere
 * outside this file — it is the private signing key and must stay
 * inside the profile folder.
 */

class IwiProfile {
  /// Stable identifier. We use the callsign so paths on disk are
  /// human-readable (`devices/X1ABCD/`) and a profile can be swapped
  /// across machines by copying its folder name.
  final String id;

  /// Display label shown in the launcher AppBar and the welcome card.
  /// Free text chosen by the user. Falls back to [callsign] if empty.
  final String nickname;

  /// Callsign derived from the npub (X1 + first 4 bech32 chars). Stays
  /// stable for the life of the profile because it is also the [id].
  final String callsign;

  /// Bech32-encoded Nostr public key (`npub1...`). Shown to users,
  /// safe to share, used as the publisher identity when signing wapps.
  final String npub;

  /// Bech32-encoded Nostr private key (`nsec1...`). **Secret**. Kept
  /// only in the profile's own JSON entry so a profile export/backup
  /// is a single file copy.
  ///
  /// Encrypted profiles: empty while locked; hydrated in memory after
  /// unlock. [toJson] never writes it when [nsecEnvelope] is set.
  final String nsec;

  /// AES-GCM envelope holding the nsec at rest for encrypted profiles
  /// (see ProfileCrypto/NsecEnvelope). Null for plain profiles. When set,
  /// the plaintext [nsec] is never persisted.
  final Map<String, dynamic>? nsecEnvelope;

  /// Free-text bio / status the user can edit. Optional.
  final String description;

  /// Preferred avatar colour name (one of [kProfileColors]). Empty falls
  /// back to a deterministic colour derived from the callsign.
  final String color;

  /// Relative filename of the avatar image inside this profile's folder
  /// (`devices/<id>/<avatar>`), or empty when none is set (then the avatar
  /// renders as a coloured circle with the callsign initials).
  final String avatar;

  /// Unix epoch ms of creation. Used to sort profiles in the switcher.
  final int createdAt;

  const IwiProfile({
    required this.id,
    required this.nickname,
    required this.callsign,
    required this.npub,
    required this.nsec,
    required this.createdAt,
    this.description = '',
    this.color = '',
    this.avatar = '',
    this.nsecEnvelope,
  });

  String get displayName => nickname.isNotEmpty ? nickname : callsign;

  IwiProfile copyWith({
    String? id,
    String? nickname,
    String? callsign,
    String? npub,
    String? nsec,
    int? createdAt,
    String? description,
    String? color,
    String? avatar,
    Map<String, dynamic>? nsecEnvelope,
    bool clearNsecEnvelope = false,
  }) {
    return IwiProfile(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      callsign: callsign ?? this.callsign,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      createdAt: createdAt ?? this.createdAt,
      description: description ?? this.description,
      color: color ?? this.color,
      avatar: avatar ?? this.avatar,
      nsecEnvelope:
          clearNsecEnvelope ? null : (nsecEnvelope ?? this.nsecEnvelope),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nickname': nickname,
        'callsign': callsign,
        'npub': npub,
        // Encrypted profile: persist the envelope, NEVER the plaintext key
        // (the in-memory nsec is hydrated after unlock and must not leak
        // back to disk through a routine profile save).
        if (nsecEnvelope != null) 'nsec_enc': nsecEnvelope else 'nsec': nsec,
        'createdAt': createdAt,
        'description': description,
        'color': color,
        'avatar': avatar,
      };

  factory IwiProfile.fromJson(Map<String, dynamic> json) {
    final envelope = json['nsec_enc'];
    return IwiProfile(
      id: json['id'] as String,
      nickname: (json['nickname'] as String?) ?? '',
      callsign: json['callsign'] as String,
      npub: json['npub'] as String,
      nsec: (json['nsec'] as String?) ?? '',
      createdAt: (json['createdAt'] as int?) ??
          DateTime.now().millisecondsSinceEpoch,
      description: (json['description'] as String?) ?? '',
      color: (json['color'] as String?) ?? '',
      avatar: (json['avatar'] as String?) ?? '',
      nsecEnvelope: envelope is Map ? envelope.cast<String, dynamic>() : null,
    );
  }
}

/// The eight avatar colour choices, matching the original geogram palette.
const List<String> kProfileColors = [
  'red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan',
];
