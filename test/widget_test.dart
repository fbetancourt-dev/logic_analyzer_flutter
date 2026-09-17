import 'package:flutter_test/flutter_test.dart';
import 'package:logic_analyzer_flutter/main.dart';
import 'package:logic_analyzer_flutter/models/capture_data.dart';
import 'package:logic_analyzer_flutter/models/uart_packet.dart';
import 'package:logic_analyzer_flutter/models/i2c_packet.dart';
import 'package:logic_analyzer_flutter/models/spi_packet.dart';
import 'package:logic_analyzer_flutter/models/pwm_measurement.dart';
import 'package:logic_analyzer_flutter/services/uart_decoder.dart';
import 'package:logic_analyzer_flutter/services/i2c_decoder.dart';
import 'package:logic_analyzer_flutter/services/spi_decoder.dart';
import 'package:logic_analyzer_flutter/services/pwm_decoder.dart';
import 'package:logic_analyzer_flutter/services/signal_generator.dart';

void main() {
  testWidgets('App smoke test loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const LogicAnalyzerApp());
    expect(find.text('PulseView Mobile'), findsOneWidget);
    expect(find.text('No hay capturas activas'), findsOneWidget);
    expect(find.text('Demo UART'), findsOneWidget);
    expect(find.text('Demo I2C'), findsOneWidget);
    expect(find.text('Demo SPI'), findsOneWidget);
    expect(find.text('Demo PWM'), findsOneWidget);
  });

  group('UART Protocol Tests', () {
    test('Control character badge detection', () {
      expect(const UartPacket(startSample: 0, endSample: 1, value: 0x0D).isControlChar, isTrue);
      expect(const UartPacket(startSample: 0, endSample: 1, value: 0x0D).controlAbbr, equals('CR'));
      expect(const UartPacket(startSample: 0, endSample: 1, value: 0x0A).controlAbbr, equals('LF'));
      expect(const UartPacket(startSample: 0, endSample: 1, value: 0x1B).controlAbbr, equals('ESC'));
      expect(const UartPacket(startSample: 0, endSample: 1, value: 0x41).isControlChar, isFalse);
    });

    test('Hex dump line formatting', () {
      const line8 = HexDumpLine(offset: 0, bytes: [0x41, 0x54, 0x0D, 0x0A], bytesPerLine: 8);
      expect(line8.offsetHex, equals('0000'));
      expect(line8.hexBytes.contains('41 54 0D 0A'), isTrue);

      const line16 = HexDumpLine(offset: 0, bytes: [0x41, 0x54, 0x0D, 0x0A], bytesPerLine: 16);
      expect(line16.offsetHex, equals('000000'));
      expect(line16.hexBytes.contains('41 54 0D 0A'), isTrue);
    });

    test('Decodes UART stream from SignalGenerator', () {
      final slice = SignalGenerator.generateSlice(
        scenario: 'uart',
        sampleRate: 1000000,
        chunkLength: 50000,
        globalSampleOffset: 0,
      );
      final capture = CaptureData(rawSamples: slice, sampleRate: 1000000);
      final bytes = UartDecoder.decode(
        capture,
        UartConfig(channel: 0, baudRate: 115200),
      );
      expect(bytes.isNotEmpty, isTrue);
    });
  });

  group('I2C Protocol Tests', () {
    test('Decodes I2C start, address, data, stop from SignalGenerator', () {
      final slice = SignalGenerator.generateSlice(
        scenario: 'i2c',
        sampleRate: 1000000,
        chunkLength: 50000,
        globalSampleOffset: 0,
      );
      final capture = CaptureData(rawSamples: slice, sampleRate: 1000000);
      final packets = I2cDecoder.decode(
        capture,
        const I2cConfig(sclChannel: 0, sdaChannel: 1),
      );
      expect(packets.isNotEmpty, isTrue);
      expect(packets.any((p) => p.type == I2cPacketType.start), isTrue);
      expect(packets.any((p) => p.type == I2cPacketType.address), isTrue);
    });
  });

  group('SPI Protocol Tests', () {
    test('Decodes SPI full duplex packets from SignalGenerator', () {
      final slice = SignalGenerator.generateSlice(
        scenario: 'spi',
        sampleRate: 1000000,
        chunkLength: 50000,
        globalSampleOffset: 0,
      );
      final capture = CaptureData(rawSamples: slice, sampleRate: 1000000);
      final packets = SpiDecoder.decode(
        capture,
        const SpiConfig(sclkChannel: 0, mosiChannel: 1, misoChannel: 2, csChannel: 3),
      );
      expect(packets.isNotEmpty, isTrue);
      expect(packets.first.mosiHex.startsWith('0x'), isTrue);
    });
  });

  group('PWM Protocol Tests', () {
    test('Measures PWM frequency and duty cycle', () {
      final slice = SignalGenerator.generateSlice(
        scenario: 'pwm',
        sampleRate: 1000000,
        chunkLength: 50000,
        globalSampleOffset: 0,
      );
      final capture = CaptureData(rawSamples: slice, sampleRate: 1000000);
      final measurement = PwmDecoder.analyze(
        capture,
        const PwmConfig(channel: 0),
      );
      expect(measurement.pulseCount, greaterThan(0));
      expect(measurement.frequencyHz, greaterThan(10000));
      expect(measurement.dutyCyclePercent, inInclusiveRange(70.0, 80.0));
    });
  });
}
