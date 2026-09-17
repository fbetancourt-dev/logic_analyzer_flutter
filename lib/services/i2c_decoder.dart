import '../models/capture_data.dart';
import '../models/i2c_packet.dart';

enum _I2cState {
  idle,
  readingAddress,
  readingData,
}

class I2cDecoder {
  /// Decode I2C bus traffic from a CaptureData buffer
  static List<I2cPacket> decode(
    CaptureData capture,
    I2cConfig config, {
    int maxPackets = 2000,
  }) {
    if (!config.enabled || capture.totalSamples < 10) return const [];

    final packets = <I2cPacket>[];
    final totalSamples = capture.totalSamples;

    final sclMask = 1 << config.sclChannel;
    final sdaMask = 1 << config.sdaChannel;

    _I2cState state = _I2cState.idle;
    int currByte = 0;
    int bitCount = 0;
    int byteStartSample = 0;
    bool inTransaction = false;

    // Read initial states
    final b0 = capture.sampleAt(0);
    int lastScl = (b0 & sclMask) != 0 ? 1 : 0;
    int lastSda = (b0 & sdaMask) != 0 ? 1 : 0;

    for (int s = 1; s < totalSamples; s++) {
      if (packets.length >= maxPackets) break;

      final byteVal = capture.sampleAt(s);
      final curScl = (byteVal & sclMask) != 0 ? 1 : 0;
      final curSda = (byteVal & sdaMask) != 0 ? 1 : 0;

      // 1. Check for START or STOP conditions (SDA changes while SCL is HIGH)
      if (curScl == 1 && lastScl == 1) {
        // Falling edge of SDA while SCL is HIGH -> START or REPEATED START
        if (lastSda == 1 && curSda == 0) {
          final isRepeated = inTransaction;
          inTransaction = true;
          state = _I2cState.readingAddress;
          currByte = 0;
          bitCount = 0;
          byteStartSample = s;

          packets.add(I2cPacket(
            startSample: s - 1,
            endSample: s + 1,
            type: isRepeated ? I2cPacketType.repeatedStart : I2cPacketType.start,
          ));
        }
        // Rising edge of SDA while SCL is HIGH -> STOP condition
        else if (lastSda == 0 && curSda == 1) {
          if (inTransaction) {
            packets.add(I2cPacket(
              startSample: s - 1,
              endSample: s + 1,
              type: I2cPacketType.stop,
            ));
          }
          inTransaction = false;
          state = _I2cState.idle;
          currByte = 0;
          bitCount = 0;
        }
      }

      // 2. Sample data bit on SCL RISING EDGE (0 -> 1)
      if (lastScl == 0 && curScl == 1) {
        if (state == _I2cState.readingAddress || state == _I2cState.readingData) {
          if (bitCount == 0) {
            byteStartSample = s;
          }

          if (bitCount < 8) {
            currByte = (currByte << 1) | curSda;
            bitCount++;
          } else if (bitCount == 8) {
            // 9th clock pulse: ACK/NACK
            final ack = (curSda == 0); // 0 = ACK, 1 = NACK

            if (state == _I2cState.readingAddress) {
              final addr = (currByte >> 1) & 0x7F;
              final isRead = (currByte & 1) == 1;

              packets.add(I2cPacket(
                startSample: byteStartSample,
                endSample: s,
                type: I2cPacketType.address,
                value: addr,
                isRead: isRead,
                ack: ack,
              ));

              state = _I2cState.readingData;
            } else {
              packets.add(I2cPacket(
                startSample: byteStartSample,
                endSample: s,
                type: I2cPacketType.data,
                value: currByte,
                ack: ack,
              ));
            }

            currByte = 0;
            bitCount = 0;
          }
        }
      }

      lastScl = curScl;
      lastSda = curSda;
    }

    return packets;
  }
}
