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
      case 27:
        return r'\e';
      default:
        return controlAbbr ?? '.';
    }
  }

  /// Check if the byte is an ASCII non-printable control character
  bool get isControlChar => value < 32 || value == 127;

  /// Standard 2-3 letter abbreviation for ASCII control characters
  String? get controlAbbr {
    if (!isControlChar) return null;
    const abbrs = [
      'NUL', 'SOH', 'STX', 'ETX', 'EOT', 'ENQ', 'ACK', 'BEL',
      'BS',  'HT',  'LF',  'VT',  'FF',  'CR',  'SO',  'SI',
      'DLE', 'DC1', 'DC2', 'DC3', 'DC4', 'NAK', 'SYN', 'ETB',
      'CAN', 'EM',  'SUB', 'ESC', 'FS',  'GS',  'RS',  'US',
    ];
    if (value >= 0 && value < abbrs.length) return abbrs[value];
    if (value == 127) return 'DEL';
    return null;
  }

  /// Unicode Control Picture glyph (e.g. ␍ for CR, ␊ for LF, ␀ for NUL)
  String get controlSymbol {
    if (value >= 0 && value <= 31) {
      return String.fromCharCode(0x2400 + value); // Unicode Control Pictures range
    }
    if (value == 127) return '\u2421'; // ␡ DEL
    if (value >= 32 && value <= 126) return String.fromCharCode(value);
    return '.';
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

class HexDumpLine {
  final int offset;
  final List<int> bytes;
  final int bytesPerLine;

  const HexDumpLine({
    required this.offset,
    required this.bytes,
    this.bytesPerLine = 16,
  });

  /// Hex offset formatted like CoolTerm (e.g. 0000 or 000000)
  String get offsetHex => offset.toRadixString(16).padLeft(bytesPerLine <= 8 ? 4 : 6, '0').toUpperCase();

  /// Hex values formatted with CoolTerm grouping and padding
  String get hexBytes {
    final sb = StringBuffer();
    for (int i = 0; i < bytesPerLine; i++) {
      if (i < bytes.length) {
        sb.write(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase());
      } else {
        sb.write('  ');
      }
      if (bytesPerLine == 16) {
        if (i == 7) {
          sb.write('  '); // Extra spacing between two 8-byte blocks
        } else if (i < 15) {
          sb.write(' ');
        }
      } else {
        if (i == 3) {
          sb.write('  '); // Extra spacing between two 4-byte blocks
        } else if (i < 7) {
          sb.write(' ');
        }
      }
    }
    return sb.toString();
  }

  /// ASCII / Decoded text (printable ASCII or dot)
  String get asciiChars {
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b >= 32 && b <= 126) {
        sb.write(String.fromCharCode(b));
      } else {
        sb.write('.');
      }
    }
    return sb.toString();
  }

  /// CoolTerm column header line
  static String headerText(int bpl) {
    if (bpl == 8) {
      return 'Offset   00 01 02 03  04 05 06 07  Decoded text';
    }
    return 'Offset    00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  Decoded text';
  }

  /// CoolTerm column divider line
  static String dividerText(int bpl) {
    if (bpl == 8) {
      return '───────  ────────────────────────  ────────────';
    }
    return '────────  ────────────────────────────────────────────────  ────────────';
  }
}

