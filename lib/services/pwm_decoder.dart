import 'dart:math' as math;
import '../models/capture_data.dart';
import '../models/pwm_measurement.dart';

class PwmDecoder {
  /// Analyze PWM signal characteristics on the target channel
  static PwmMeasurement analyze(
    CaptureData capture,
    PwmConfig config, {
    int maxCyclesToAnalyze = 100,
  }) {
    if (!config.enabled || capture.totalSamples < 4) {
      return const PwmMeasurement();
    }

    final total = capture.totalSamples;
    final ch = config.channel;
    final sampleRate = capture.sampleRate;
    final mask = 1 << ch;

    int lastBit = (capture.sampleAt(0) & mask) != 0 ? 1 : 0;
    int lastRising = -1;
    int lastFalling = -1;

    final periods = <int>[];
    final highTimes = <int>[];

    // Scan backwards from end or forwards across buffer
    // Scan recent samples up to 50,000 samples for responsive live stats
    final startIdx = math.max(0, total - 60000);

    for (int s = startIdx; s < total; s++) {
      final curBit = (capture.sampleAt(s) & mask) != 0 ? 1 : 0;

      if (lastBit == 0 && curBit == 1) {
        // Rising edge
        if (lastRising >= 0 && lastFalling > lastRising) {
          final p = s - lastRising;
          final h = lastFalling - lastRising;
          if (p > 1 && h > 0 && h < p) {
            periods.add(p);
            highTimes.add(h);
            if (periods.length >= maxCyclesToAnalyze) break;
          }
        }
        lastRising = s;
      } else if (lastBit == 1 && curBit == 0) {
        // Falling edge
        lastFalling = s;
      }

      lastBit = curBit;
    }

    if (periods.isEmpty) {
      // Check if static high or static low
      final curBit = (capture.sampleAt(total - 1) & mask) != 0 ? 1 : 0;
      return PwmMeasurement(
        frequencyHz: 0.0,
        dutyCyclePercent: curBit == 1 ? 100.0 : 0.0,
        periodSec: 0.0,
        highTimeSec: 0.0,
        lowTimeSec: 0.0,
        pulseCount: 0,
      );
    }

    // Latest cycle
    final latestPeriodSamples = periods.last;
    final latestHighSamples = highTimes.last;
    final latestLowSamples = latestPeriodSamples - latestHighSamples;

    final freq = sampleRate / latestPeriodSamples.toDouble();
    final periodSec = latestPeriodSamples / sampleRate.toDouble();
    final highSec = latestHighSamples / sampleRate.toDouble();
    final lowSec = latestLowSamples / sampleRate.toDouble();
    final duty = (latestHighSamples / latestPeriodSamples.toDouble()) * 100.0;

    // Aggregate statistics
    double sumFreq = 0.0;
    double minDuty = 100.0;
    double maxDuty = 0.0;

    for (int i = 0; i < periods.length; i++) {
      final f = sampleRate / periods[i].toDouble();
      final d = (highTimes[i] / periods[i].toDouble()) * 100.0;
      sumFreq += f;
      if (d < minDuty) minDuty = d;
      if (d > maxDuty) maxDuty = d;
    }

    final avgFreq = sumFreq / periods.length;

    return PwmMeasurement(
      frequencyHz: freq,
      dutyCyclePercent: duty,
      periodSec: periodSec,
      highTimeSec: highSec,
      lowTimeSec: lowSec,
      pulseCount: periods.length,
      avgFrequencyHz: avgFreq,
      minDutyPercent: minDuty,
      maxDutyPercent: maxDuty,
    );
  }
}
