enum UartParity { none, even, odd }

enum UartDisplayFormat { ascii, hex, both }

class UartConfig {
  final bool enabled;
  final int channel; // 0..7
  final int baudRate; // e.g. 115200, 9600
  final int dataBits; // 8
  final UartParity parity;
  final int stopBits; // 1 or 2
  final bool lsbFirst; // true for standard UART
  final UartDisplayFormat displayFormat;

  const UartConfig({
    this.enabled = true,
    this.channel = 0,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.parity = UartParity.none,
    this.stopBits = 1,
    this.lsbFirst = true,
    this.displayFormat = UartDisplayFormat.both,
  });

  UartConfig copyWith({
    bool? enabled,
    int? channel,
    int? baudRate,
    int? dataBits,
    UartParity? parity,
    int? stopBits,
    bool? lsbFirst,
    UartDisplayFormat? displayFormat,
  }) {
    return UartConfig(
      enabled: enabled ?? this.enabled,
      channel: channel ?? this.channel,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      parity: parity ?? this.parity,
      stopBits: stopBits ?? this.stopBits,
      lsbFirst: lsbFirst ?? this.lsbFirst,
      displayFormat: displayFormat ?? this.displayFormat,
    );
  }
}

class UartPacket {
  final int startSample;
  final int endSample;
  final int value; // 0..255
  final bool isFramingError;
  final bool isParityError;

  const UartPacket({
    required this.startSample,
    required this.endSample,
    required this.value,
    this.isFramingError = false,
    this.isParityError = false,
  });

  /// Formatted character for single-line waveform bubble
  String get bubbleLabel {
    if (value >= 32 && value <= 126) {
      return String.fromCharCode(value);
    }
    switch (value) {
      case 10:
        return r'\n';
      case 13:
        return r'\r';
      case 9:
        return r'\t';
      case 0:
        return r'\0';
      default:
        return '.';
    }
  }

  /// Real character for terminal output (LF produces real newline)
  String get consoleChar {
    if (value >= 32 && value <= 126) {
      return String.fromCharCode(value);
    }
    if (value == 10) return '\n';
    if (value == 13) return ''; // Drop CR so CRLF formats cleanly
    if (value == 9) return '\t';
    return '.';
  }

  /// Readable ASCII character or escape sequence
  String get asciiString => bubbleLabel;

  /// Hex representation like "0x41" or "41"
  String get hexString => '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String displayText(UartDisplayFormat format) {
    if (isFramingError) return 'ERR';
    switch (format) {
      case UartDisplayFormat.ascii:
        return bubbleLabel;
      case UartDisplayFormat.hex:
        return hexString;
      case UartDisplayFormat.both:
        return (value >= 32 && value <= 126) ? "'$bubbleLabel' ($hexString)" : hexString;
    }
  }
}
