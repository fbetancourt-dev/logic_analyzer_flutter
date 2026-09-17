import 'dart:math' as math;
import '../models/capture_data.dart';
import '../models/uart_packet.dart';

class UartDecoder {
  /// Decodes UART packets from a capture buffer within a sample range
  static List<UartPacket> decode(
    CaptureData capture,
    UartConfig config, {
    int startSample = 0,
    int? endSample,
    int maxPackets = 1000,
  }) {
    if (!config.enabled || capture.totalSamples < 10 || config.baudRate <= 0) {
      return const [];
    }

    final packets = <UartPacket>[];
    final samples = capture.rawSamples;
    final total = capture.totalSamples;
    final mask = 1 << config.channel;

    final baudSamples = capture.sampleRate / config.baudRate;
    if (baudSamples < 1.0) {
      // Nyquist limit violated: sample rate is too low for this baud rate
      return const [];
    }

    final start = math.max(1, startSample);
    final stop = math.min(total - 1, endSample ?? total - 1);
    final hasParity = config.parity != UartParity.none;
    final parityOffset = hasParity ? 1 : 0;
    final totalBits = 1 + config.dataBits + parityOffset + config.stopBits;

    int i = start;
    while (i < stop && packets.length < maxPackets) {
      // 1. Look for falling edge (Idle HIGH -> Start bit LOW)
      if ((samples[i - 1] & mask) != 0 && (samples[i] & mask) == 0) {
        final startEdge = i;

        // 2. Validate start bit at 50% bit period
        final midStart = (startEdge + 0.5 * baudSamples).round();
        if (midStart >= total) break;
        if ((samples[midStart] & mask) != 0) {
          // False start / glitch
          i = startEdge + 1;
          continue;
        }

        // Check if full frame fits in buffer
        final frameEndEst = (startEdge + totalBits * baudSamples).round();
        if (frameEndEst >= total) {
          break; // Partial frame at end of buffer
        }

        // 3. Sample data bits
        int byteVal = 0;
        int onesCount = 0;
        for (int b = 0; b < config.dataBits; b++) {
          final samplePt = (startEdge + (1.5 + b) * baudSamples).round();
          final bit = (samples[samplePt] & mask) != 0 ? 1 : 0;
          if (bit == 1) onesCount++;

          if (config.lsbFirst) {
            byteVal |= (bit << b);
          } else {
            byteVal = (byteVal << 1) | bit;
          }
        }

        // 4. Parity check
        bool isParityError = false;
        if (hasParity) {
          final parityPt = (startEdge + (1.5 + config.dataBits) * baudSamples).round();
          final parityBit = (samples[parityPt] & mask) != 0 ? 1 : 0;
          if (config.parity == UartParity.even) {
            isParityError = ((onesCount + parityBit) % 2) != 0;
          } else if (config.parity == UartParity.odd) {
            isParityError = ((onesCount + parityBit) % 2) != 1;
          }
        }

        // 5. Stop bit check (Must be HIGH)
        final stopPt = (startEdge + (1.5 + config.dataBits + parityOffset) * baudSamples).round();
        final stopBit = (samples[stopPt] & mask) != 0 ? 1 : 0;
        final isFramingError = (stopBit == 0);

        final endSampleIdx = (startEdge + totalBits * baudSamples).round();

        packets.add(UartPacket(
          startSample: startEdge,
          endSample: endSampleIdx,
          value: byteVal,
          isFramingError: isFramingError,
          isParityError: isParityError,
        ));

        // Advance past frame
        i = math.max(i + 1, endSampleIdx);
      } else {
        i++;
      }
    }

    return packets;
  }
}
