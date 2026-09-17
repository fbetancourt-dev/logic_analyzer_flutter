class PwmConfig {
  final bool enabled;
  final int channel; // 0..7

  const PwmConfig({
    this.enabled = true,
    this.channel = 6,
  });

  PwmConfig copyWith({
    bool? enabled,
    int? channel,
  }) {
    return PwmConfig(
      enabled: enabled ?? this.enabled,
      channel: channel ?? this.channel,
    );
  }
}

class PwmMeasurement {
  final double frequencyHz;
  final double dutyCyclePercent;
  final double periodSec;
  final double highTimeSec;
  final double lowTimeSec;
  final int pulseCount;
  final double avgFrequencyHz;
  final double minDutyPercent;
  final double maxDutyPercent;

  const PwmMeasurement({
    this.frequencyHz = 0.0,
    this.dutyCyclePercent = 0.0,
    this.periodSec = 0.0,
    this.highTimeSec = 0.0,
    this.lowTimeSec = 0.0,
    this.pulseCount = 0,
    this.avgFrequencyHz = 0.0,
    this.minDutyPercent = 0.0,
    this.maxDutyPercent = 0.0,
  });

  String get frequencyFormatted {
    if (frequencyHz >= 1000000.0) {
      return '${(frequencyHz / 1000000.0).toStringAsFixed(3)} MHz';
    } else if (frequencyHz >= 1000.0) {
      return '${(frequencyHz / 1000.0).toStringAsFixed(2)} kHz';
    } else {
      return '${frequencyHz.toStringAsFixed(1)} Hz';
    }
  }

  String get dutyFormatted => '${dutyCyclePercent.toStringAsFixed(1)}%';

  String get periodFormatted => _formatTime(periodSec);
  String get highTimeFormatted => _formatTime(highTimeSec);
  String get lowTimeFormatted => _formatTime(lowTimeSec);

  static String _formatTime(double sec) {
    if (sec <= 0) return '0 s';
    if (sec < 1e-6) return '${(sec * 1e9).toStringAsFixed(1)} ns';
    if (sec < 1e-3) return '${(sec * 1e6).toStringAsFixed(2)} µs';
    if (sec < 1.0) return '${(sec * 1e3).toStringAsFixed(3)} ms';
    return '${sec.toStringAsFixed(4)} s';
  }

  String get badgeLabel => '$frequencyFormatted | $dutyFormatted';
}
