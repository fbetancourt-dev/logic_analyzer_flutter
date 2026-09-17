import 'dart:typed_data';

class CaptureData {
  final Uint8List rawSamples;
  final int sampleRate; // in Hz
  final DateTime timestamp;
  final int numChannels;
  final double timeOffsetSeconds;

  CaptureData({
    required this.rawSamples,
    required this.sampleRate,
    DateTime? timestamp,
    this.numChannels = 8,
    this.timeOffsetSeconds = 0.0,
  }) : timestamp = timestamp ?? DateTime.now();

  int get totalSamples => rawSamples.length;

  double get totalDurationSeconds =>
      sampleRate > 0 ? totalSamples / sampleRate : 0.0;

  /// Returns 0 or 1 for given channel (0..7) at sample index
  int getBit(int sampleIndex, int channel) {
    if (sampleIndex < 0 || sampleIndex >= rawSamples.length) return 0;
    return (rawSamples[sampleIndex] >> channel) & 1;
  }

  /// Format time in ns, µs, ms or s
  static String formatTime(double seconds) {
    if (seconds.abs() < 1e-6) {
      return '${(seconds * 1e9).toStringAsFixed(1)} ns';
    } else if (seconds.abs() < 1e-3) {
      return '${(seconds * 1e6).toStringAsFixed(2)} µs';
    } else if (seconds.abs() < 1.0) {
      return '${(seconds * 1e3).toStringAsFixed(3)} ms';
    } else {
      return '${seconds.toStringAsFixed(4)} s';
    }
  }

  static String formatFrequency(double hz) {
    if (hz >= 1e6) {
      return '${(hz / 1e6).toStringAsFixed(3)} MHz';
    } else if (hz >= 1e3) {
      return '${(hz / 1e3).toStringAsFixed(2)} kHz';
    } else {
      return '${hz.toStringAsFixed(1)} Hz';
    }
  }
}
