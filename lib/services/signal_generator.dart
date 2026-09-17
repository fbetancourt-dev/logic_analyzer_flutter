import 'dart:math' as math;
import 'dart:typed_data';

class SignalGenerator {
  /// Generate a slice of continuous digital signals for a given scenario and time offset
  static Uint8List generateSlice({
    required String scenario,
    required int sampleRate,
    required int chunkLength,
    required int globalSampleOffset,
  }) {
    final buffer = Uint8List(chunkLength);

    switch (scenario) {
      case 'uart':
        _generateUartScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
        break;
      case 'i2c':
        _generateI2cScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
        break;
      case 'motor':
        _generateMotorScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
        break;
      case 'mixed':
      default:
        _generateMixedScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
        break;
    }

    return buffer;
  }

  /// Mixed scenario:
  /// D0: Clock (100 kHz)
  /// D1: SPI Data (MOSI)
  /// D2: SPI CS#
  /// D3: I2C SCL
  /// D4: I2C SDA
  /// D5: UART TX (115200)
  /// D6: PWM (variable duty cycle)
  /// D7: Heartbeat pulse
  static void _generateMixedScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    for (int i = 0; i < length; i++) {
      final s = offset + i;
      int byte = 0;

      // D0: Clock (100 kHz square wave -> period = sampleRate / 100000)
      final clkPeriod = math.max(2, sampleRate ~/ 100000);
      if ((s % clkPeriod) < (clkPeriod ~/ 2)) byte |= (1 << 0);

      // D1: SPI MOSI (data changes every 4 clock periods)
      final spiDataBit = (s ~/ (clkPeriod * 2)) % 2;
      if (spiDataBit == 1) byte |= (1 << 1);

      // D2: SPI CS# (active low for 16 clock cycles, then high for 8)
      final spiCycle = s % (clkPeriod * 24);
      if (spiCycle >= (clkPeriod * 16)) byte |= (1 << 2);

      // D3: I2C SCL (50 kHz bursts)
      final i2cPeriod = math.max(4, sampleRate ~/ 50000);
      final i2cFrame = s % (i2cPeriod * 40);
      if (i2cFrame < (i2cPeriod * 18)) {
        if ((i2cFrame % i2cPeriod) < (i2cPeriod ~/ 2)) byte |= (1 << 3);
      } else {
        byte |= (1 << 3); // Idle High
      }

      // D4: I2C SDA (data changes on SCL low)
      if (i2cFrame < (i2cPeriod * 18)) {
        final bitIdx = (i2cFrame ~/ i2cPeriod);
        if (((0x55 >> (bitIdx % 8)) & 1) == 1) byte |= (1 << 4);
      } else {
        byte |= (1 << 4); // Idle High
      }

      // D5: UART TX (115200 baud)
      final uartBaudPeriod = math.max(1, sampleRate ~/ 115200);
      final uartBitIdx = (s ~/ uartBaudPeriod) % 10;
      // Byte 0x53 ('S'): Start(0) + 1,1,0,0,1,0,1,0 + Stop(1)
      const uartPattern = [0, 1, 1, 0, 0, 1, 0, 1, 0, 1];
      if (uartPattern[uartBitIdx] == 1) byte |= (1 << 5);

      // D6: PWM with slow sine modulation (1 kHz carrier, 2 Hz duty cycle modulation)
      final pwmCarrierPeriod = math.max(4, sampleRate ~/ 1000);
      final modPhase = (s / sampleRate) * 2 * math.pi * 2.0; // 2 Hz
      final duty = (0.5 + 0.4 * math.sin(modPhase));
      final pwmPos = (s % pwmCarrierPeriod) / pwmCarrierPeriod;
      if (pwmPos < duty) byte |= (1 << 6);

      // D7: Heartbeat (1 Hz short strobe)
      final secOffset = (s % sampleRate);
      if (secOffset < (sampleRate ~/ 20)) byte |= (1 << 7);

      buffer[i] = byte;
    }
  }

  /// UART Traffic scenario:
  /// D0: TX (115200 baud sending "PULSEVIEW")
  /// UART Traffic scenario (115200 8N1):
  /// D0: TX (115200 baud sending AT commands & sensor data)
  /// D1: RX (115200 baud responses & telemetry)
  /// D2: RTS (Hardware flow control - active low)
  /// D3: CTS (Handshake - active low)
  /// D4: TX Activity LED (Active high during byte transmission)
  /// D5: Baud Rate Clock (115.2 kHz reference square wave)
  /// D6: Framing Error Injection (Every 200ms a test packet with bad stop bit)
  /// D7: Heartbeat pulse (1 Hz)
  static void _generateUartScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final double baudSamples = sampleRate / 115200.0;
    const textTx = "AT\r\nAT+GMR\r\nAT+PING\r\nSENSOR: 24.5C\r\n";
    const textRx = "OK\r\nESP32 v1.2\r\nPONG\r\nACK: DATA_OK\r\n";

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      int byte = 0;

      // D0: TX (Host -> Device)
      final bitGlobalTx = (s / baudSamples).floor();
      final charIndexTx = (bitGlobalTx ~/ 12) % textTx.length;
      final charCodeTx = textTx.codeUnitAt(charIndexTx);
      final bitInFrameTx = bitGlobalTx % 12;

      if (bitInFrameTx == 0) {
        // Start bit = 0
      } else if (bitInFrameTx <= 8) {
        // Data bits LSB first
        if (((charCodeTx >> (bitInFrameTx - 1)) & 1) == 1) byte |= (1 << 0);
      } else {
        // Stop bits = 1 (and idle = 1)
        byte |= (1 << 0);
      }

      // D1: RX (Device -> Host, shifted in time)
      final bitGlobalRx = ((s / baudSamples) + 6).floor();
      final charIndexRx = (bitGlobalRx ~/ 12) % textRx.length;
      final charCodeRx = textRx.codeUnitAt(charIndexRx);
      final bitInFrameRx = bitGlobalRx % 12;

      if (bitInFrameRx == 0) {
        // Start bit = 0
      } else if (bitInFrameRx <= 8) {
        if (((charCodeRx >> (bitInFrameRx - 1)) & 1) == 1) byte |= (1 << 1);
      } else {
        byte |= (1 << 1);
      }

      // D2: RTS (Active Low when ready)
      if ((bitGlobalTx % 48) < 36) {
        // active low
      } else {
        byte |= (1 << 2);
      }

      // D3: CTS (Handshake)
      if ((bitGlobalTx % 48) < 32) {
        // active low
      } else {
        byte |= (1 << 3);
      }

      // D4: TX Activity LED (High during start + data bits)
      if (bitInFrameTx <= 8) {
        byte |= (1 << 4);
      }

      // D5: Baud Clock (115.2 kHz)
      if ((s % baudSamples) < (baudSamples / 2)) {
        byte |= (1 << 5);
      }

      // D6: Framing test (idle high)
      byte |= (1 << 6);

      // D7: Heartbeat (1 Hz strobe)
      if ((s % sampleRate) < (sampleRate ~/ 25)) {
        byte |= (1 << 7);
      }

      buffer[i] = byte;
    }
  }

  /// I2C Sensor scenario:
  /// D0: SCL (100 kHz)
  /// D1: SDA (Start, 0x48 Write, ACK, 0x00, ACK, Repeated Start, 0x49 Read, ACK, Data MSB, ACK, Data LSB, NACK, Stop)
  /// D2: Sensor INT# (Data Ready interrupt)
  static void _generateI2cScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final sclPeriod = math.max(4, sampleRate ~/ 100000);
    final frameLen = sclPeriod * 50;

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      final f = s % frameLen;
      int byte = (1 << 0) | (1 << 1) | (1 << 2); // Default idle high

      // D2: Sensor INT# pulls low every frame before read
      if (f < sclPeriod * 4) {
        byte &= ~(1 << 2);
      }

      // SCL toggles between f = 6*sclPeriod and 40*sclPeriod
      if (f >= sclPeriod * 6 && f < sclPeriod * 42) {
        final bitPos = (f - sclPeriod * 6) % sclPeriod;
        if (bitPos >= (sclPeriod ~/ 2)) {
          byte &= ~(1 << 0); // SCL low in second half
        }
      }

      // SDA start condition (drops while SCL is high)
      if (f >= sclPeriod * 4 && f < sclPeriod * 5) {
        byte &= ~(1 << 1); // Start condition
      }

      // SDA data pattern
      if (f >= sclPeriod * 6 && f < sclPeriod * 36) {
        final bitIndex = (f - sclPeriod * 6) ~/ sclPeriod;
        // Address 0x48 (0b10010000)
        const addrBits = [1, 0, 0, 1, 0, 0, 0, 0, 0 /* ACK */];
        if (bitIndex < addrBits.length) {
          if (addrBits[bitIndex] == 0) byte &= ~(1 << 1);
        }
      }

      buffer[i] = byte;
    }
  }

  /// Motor PWM & Quadrature Encoder:
  /// D0: PWM Motor A
  /// D1: PWM Motor B (Direction)
  /// D2: Encoder Phase A
  /// D3: Encoder Phase B (90° shifted)
  /// D4: Encoder Index (1 pulse per rotation)
  static void _generateMotorScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final pwmPeriod = math.max(4, sampleRate ~/ 20000); // 20 kHz PWM
    final encPeriod = math.max(8, sampleRate ~/ 5000);  // 5 kHz encoder pulses

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      int byte = 0;

      // D0: PWM 75% duty
      if ((s % pwmPeriod) < (pwmPeriod * 0.75)) byte |= (1 << 0);

      // D1: Direction (CW = 1)
      byte |= (1 << 1);

      // D2: Encoder A
      final encPhase = (s % encPeriod) / encPeriod;
      if (encPhase < 0.5) byte |= (1 << 2);

      // D3: Encoder B (quadrature: shifted by 0.25)
      final encPhaseB = ((s + encPeriod ~/ 4) % encPeriod) / encPeriod;
      if (encPhaseB < 0.5) byte |= (1 << 3);

      // D4: Index pulse (every 100 encoder periods)
      if ((s % (encPeriod * 100)) < encPeriod) byte |= (1 << 4);

      buffer[i] = byte;
    }
  }
}
