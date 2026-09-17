import 'dart:math' as math;
import 'capture_data.dart';

enum TriggerSlope {
  rising,   // Flanco de subida (0 -> 1)
  falling,  // Flanco de bajada (1 -> 0)
  any,      // Cualquier flanco (cambio)
  none,     // Modo Auto / Roll libre sin sincronización
}

class TriggerConfig {
  final bool enabled;
  final int channel; // 0..7
  final TriggerSlope slope;
  final double screenRatio; // 0.15 = 15% from left

  const TriggerConfig({
    this.enabled = true,
    this.channel = 0,
    this.slope = TriggerSlope.rising,
    this.screenRatio = 0.15,
  });

  TriggerConfig copyWith({
    bool? enabled,
    int? channel,
    TriggerSlope? slope,
    double? screenRatio,
  }) {
    return TriggerConfig(
      enabled: enabled ?? this.enabled,
      channel: channel ?? this.channel,
      slope: slope ?? this.slope,
      screenRatio: screenRatio ?? this.screenRatio,
    );
  }

  String get slopeLabel {
    switch (slope) {
      case TriggerSlope.rising:
        return 'Subida (↑)';
      case TriggerSlope.falling:
        return 'Bajada (↓)';
      case TriggerSlope.any:
        return 'Ambos (↕)';
      case TriggerSlope.none:
        return 'Auto / Libre (○)';
    }
  }

  /// Scans the buffer for the latest matching trigger transition
  int? findTriggerSample(CaptureData capture, {required int searchFromSample, int lookback = 40000}) {
    if (!enabled || slope == TriggerSlope.none || capture.totalSamples < 2) {
      return null;
    }

    final start = searchFromSample.clamp(1, capture.totalSamples - 1);
    final stop = math.max(1, start - lookback);
    final mask = 1 << channel;
    final samples = capture.rawSamples;

    if (slope == TriggerSlope.rising) {
      for (int i = start; i >= stop; i--) {
        if ((samples[i - 1] & mask) == 0 && (samples[i] & mask) != 0) {
          return i;
        }
      }
    } else if (slope == TriggerSlope.falling) {
      for (int i = start; i >= stop; i--) {
        if ((samples[i - 1] & mask) != 0 && (samples[i] & mask) == 0) {
          return i;
        }
      }
    } else if (slope == TriggerSlope.any) {
      for (int i = start; i >= stop; i--) {
        if ((samples[i - 1] & mask) != (samples[i] & mask)) {
          return i;
        }
      }
    }
    return null;
  }
}
