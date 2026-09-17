class SpiConfig {
  final bool enabled;
  final int sclkChannel; // default 0
  final int mosiChannel; // default 1
  final int misoChannel; // default 2
  final int csChannel;   // default 3
  final bool csActiveLow;
  final int cpol; // 0 or 1
  final int cpha; // 0 or 1
  final bool lsbFirst;
  final int wordSize; // 8

  const SpiConfig({
    this.enabled = true,
    this.sclkChannel = 0,
    this.mosiChannel = 1,
    this.misoChannel = 2,
    this.csChannel = 3,
    this.csActiveLow = true,
    this.cpol = 0,
    this.cpha = 0,
    this.lsbFirst = false,
    this.wordSize = 8,
  });

  SpiConfig copyWith({
    bool? enabled,
    int? sclkChannel,
    int? mosiChannel,
    int? misoChannel,
    int? csChannel,
    bool? csActiveLow,
    int? cpol,
    int? cpha,
    bool? lsbFirst,
    int? wordSize,
  }) {
    return SpiConfig(
      enabled: enabled ?? this.enabled,
      sclkChannel: sclkChannel ?? this.sclkChannel,
      mosiChannel: mosiChannel ?? this.mosiChannel,
      misoChannel: misoChannel ?? this.misoChannel,
      csChannel: csChannel ?? this.csChannel,
      csActiveLow: csActiveLow ?? this.csActiveLow,
      cpol: cpol ?? this.cpol,
      cpha: cpha ?? this.cpha,
      lsbFirst: lsbFirst ?? this.lsbFirst,
      wordSize: wordSize ?? this.wordSize,
    );
  }

  int get mode => (cpol << 1) | cpha;
}

class SpiPacket {
  final int startSample;
  final int endSample;
  final int mosiByte;
  final int misoByte;
  final int csFrame;

  const SpiPacket({
    required this.startSample,
    required this.endSample,
    required this.mosiByte,
    required this.misoByte,
    this.csFrame = 0,
  });

  String get mosiHex => '0x${mosiByte.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  String get misoHex => '0x${misoByte.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get mosiChar {
    if (mosiByte >= 32 && mosiByte <= 126) return String.fromCharCode(mosiByte);
    return '.';
  }

  String get misoChar {
    if (misoByte >= 32 && misoByte <= 126) return String.fromCharCode(misoByte);
    return '.';
  }

  String get mosiBubbleLabel {
    if (mosiByte >= 32 && mosiByte <= 126) {
      return "'$mosiChar' ($mosiHex)";
    }
    return mosiHex;
  }

  String get misoBubbleLabel {
    if (misoByte >= 32 && misoByte <= 126) {
      return "'$misoChar' ($misoHex)";
    }
    return misoHex;
  }
}
