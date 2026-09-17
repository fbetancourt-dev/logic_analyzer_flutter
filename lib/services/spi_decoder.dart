import '../models/capture_data.dart';
import '../models/spi_packet.dart';

class SpiDecoder {
  /// Decode SPI bus traffic (MOSI & MISO full-duplex)
  static List<SpiPacket> decode(
    CaptureData capture,
    SpiConfig config, {
    int maxPackets = 2000,
  }) {
    if (!config.enabled || capture.totalSamples < 10) return const [];

    final packets = <SpiPacket>[];
    final totalSamples = capture.totalSamples;

    final sclkMask = 1 << config.sclkChannel;
    final mosiMask = 1 << config.mosiChannel;
    final misoMask = 1 << config.misoChannel;
    final csMask = 1 << config.csChannel;

    // Active sampling edge:
    // Mode 0 (0,0): Rising
    // Mode 1 (0,1): Falling
    // Mode 2 (1,0): Falling
    // Mode 3 (1,1): Rising
    final bool sampleOnRising = (config.cpol == config.cpha);

    int csFrame = 0;
    int bitCount = 0;
    int currMosi = 0;
    int currMiso = 0;
    int byteStartSample = 0;

    final b0 = capture.sampleAt(0);
    int lastSclk = (b0 & sclkMask) != 0 ? 1 : 0;
    int lastCs = (b0 & csMask) != 0 ? 1 : 0;

    for (int s = 1; s < totalSamples; s++) {
      if (packets.length >= maxPackets) break;

      final byteVal = capture.sampleAt(s);
      final curSclk = (byteVal & sclkMask) != 0 ? 1 : 0;
      final curCs = (byteVal & csMask) != 0 ? 1 : 0;
      final curMosi = (byteVal & mosiMask) != 0 ? 1 : 0;
      final curMiso = (byteVal & misoMask) != 0 ? 1 : 0;

      final isCsAsserted = config.csActiveLow ? (curCs == 0) : (curCs == 1);
      final wasCsAsserted = config.csActiveLow ? (lastCs == 0) : (lastCs == 1);

      // CS transition: new transaction frame
      if (!wasCsAsserted && isCsAsserted) {
        csFrame++;
        bitCount = 0;
        currMosi = 0;
        currMiso = 0;
      }

      // If CS is asserted, look for clock edge
      if (isCsAsserted) {
        final isSamplingEdge = sampleOnRising
            ? (lastSclk == 0 && curSclk == 1)
            : (lastSclk == 1 && curSclk == 0);

        if (isSamplingEdge) {
          if (bitCount == 0) {
            byteStartSample = s;
          }

          if (config.lsbFirst) {
            currMosi |= (curMosi << bitCount);
            currMiso |= (curMiso << bitCount);
          } else {
            currMosi = (currMosi << 1) | curMosi;
            currMiso = (currMiso << 1) | curMiso;
          }

          bitCount++;

          if (bitCount >= config.wordSize) {
            packets.add(SpiPacket(
              startSample: byteStartSample,
              endSample: s,
              mosiByte: currMosi & 0xFF,
              misoByte: currMiso & 0xFF,
              csFrame: csFrame,
            ));

            bitCount = 0;
            currMosi = 0;
            currMiso = 0;
          }
        }
      }

      lastSclk = curSclk;
      lastCs = curCs;
    }

    return packets;
  }
}
