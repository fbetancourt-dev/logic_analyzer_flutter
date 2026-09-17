enum I2cPacketType {
  start,
  repeatedStart,
  address,
  data,
  stop,
}

class I2cConfig {
  final bool enabled;
  final int sclChannel; // default 0 or 3
  final int sdaChannel; // default 1 or 4
  final int addressBits; // 7

  const I2cConfig({
    this.enabled = true,
    this.sclChannel = 0,
    this.sdaChannel = 1,
    this.addressBits = 7,
  });

  I2cConfig copyWith({
    bool? enabled,
    int? sclChannel,
    int? sdaChannel,
    int? addressBits,
  }) {
    return I2cConfig(
      enabled: enabled ?? this.enabled,
      sclChannel: sclChannel ?? this.sclChannel,
      sdaChannel: sdaChannel ?? this.sdaChannel,
      addressBits: addressBits ?? this.addressBits,
    );
  }
}

class I2cPacket {
  final int startSample;
  final int endSample;
  final I2cPacketType type;
  final int value; // 7-bit addr or 8-bit data
  final bool isRead; // For address packets: true = Read, false = Write
  final bool ack; // true = ACK, false = NACK
  final bool isError;

  const I2cPacket({
    required this.startSample,
    required this.endSample,
    required this.type,
    this.value = 0,
    this.isRead = false,
    this.ack = true,
    this.isError = false,
  });

  String get hexString =>
      '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get bubbleLabel {
    switch (type) {
      case I2cPacketType.start:
        return 'S';
      case I2cPacketType.repeatedStart:
        return 'Sr';
      case I2cPacketType.address:
        final rw = isRead ? 'R' : 'W';
        final ackStr = ack ? 'A' : '~A';
        return '$hexString $rw [$ackStr]';
      case I2cPacketType.data:
        final ackStr = ack ? 'A' : '~A';
        final ascii = (value >= 32 && value <= 126) ? " '${String.fromCharCode(value)}'" : '';
        return '$hexString$ascii [$ackStr]';
      case I2cPacketType.stop:
        return 'P';
    }
  }

  String get shortLabel {
    switch (type) {
      case I2cPacketType.start:
        return 'S';
      case I2cPacketType.repeatedStart:
        return 'Sr';
      case I2cPacketType.address:
        return '$hexString ${isRead ? "R" : "W"}';
      case I2cPacketType.data:
        return hexString;
      case I2cPacketType.stop:
        return 'P';
    }
  }
}
