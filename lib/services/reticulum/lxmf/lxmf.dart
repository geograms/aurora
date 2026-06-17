/*
 * LXMF constants (wire-compatible with markqvist/LXMF). LXMF is the messaging
 * layer Sideband / NomadNet / MeshChat speak on top of Reticulum; implementing it
 * lets Aurora interoperate with those projects.
 */

/// RNS app name for LXMF destinations.
const String kLxmfApp = 'lxmf';

/// A node's message-delivery destination: Destination(identity, IN, SINGLE,
/// 'lxmf', 'delivery'). Peers address messages here.
const List<String> kLxmfDeliveryAspects = ['delivery'];

/// Store-and-forward propagation node destination aspects.
const List<String> kLxmfPropagationAspects = ['propagation'];

/// Delivery methods.
enum LxmfMethod { opportunistic, direct, propagated, paper }

/// Field keys for the LXMF payload `fields` map (msgpack int -> value).
class LxmfField {
  static const int embeddedLxms = 0x01;
  static const int telemetry = 0x02;
  static const int telemetryStream = 0x03;
  static const int iconAppearance = 0x04;
  static const int fileAttachments = 0x05; // [[name(bytes), data(bytes)], ...]
  static const int image = 0x06; // [ext(bytes/str), data(bytes)]
  static const int audio = 0x07; // [mode(int), data(bytes)]
  static const int thread = 0x08; // bytes: thread id hash
  static const int commands = 0x09;
  static const int results = 0x0A;
  static const int group = 0x0B;
  static const int ticket = 0x0C;
  static const int event = 0x0D;
  static const int rnrRefs = 0x0E;
  static const int renderer = 0x0F;
  static const int replyTo = 0x30; // bytes: full LXMessage hash
  static const int replyQuote = 0x31;
  static const int reaction = 0x40;
  static const int comment = 0x41;
  static const int continuation = 0x42;
  static const int customType = 0xFB;
  static const int customData = 0xFC;
  static const int customMeta = 0xFD;
  static const int nonSpecific = 0xFE;
  static const int debug = 0xFF;
}

/// Content renderers (FIELD renderer).
class LxmfRenderer {
  static const int plain = 0x00;
  static const int micron = 0x01;
  static const int markdown = 0x02;
  static const int bbcode = 0x03;
}
