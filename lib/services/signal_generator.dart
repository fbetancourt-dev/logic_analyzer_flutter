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
      case 'spi':
        _generateSpiScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
        break;
      case 'pwm':
        _generatePwmScenario(buffer, sampleRate, chunkLength, globalSampleOffset);
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

      // D0: Clock (100 kHz square wave)
      final clkPeriod = math.max(2, sampleRate ~/ 100000);
      if ((s % clkPeriod) < (clkPeriod ~/ 2)) byte |= (1 << 0);

      // D1: SPI MOSI
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

  /// UART Traffic scenario (115200 8N1):
  /// D0: TX (115200 baud sending AT commands & sensor data)
  /// D1: RX (115200 baud responses & telemetry)
  /// D2: RTS (Hardware flow control - active low)
  /// D3: CTS (Handshake - active low)
  /// D4: TX Activity LED (Active high during byte transmission)
  /// D5: Baud Rate Clock (115.2 kHz reference square wave)
  /// D6: Framing Error Injection
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

  /// I2C Sensor Scenario:
  /// D0: SCL (100 kHz I2C Clock)
  /// D1: SDA (Start, Addr 0x48 W, ACK, Reg 0x01, ACK, Data 0xA5, ACK, Stop)
  /// D2: Sensor INT# (Data ready interrupt line, active low)
  /// D7: Heartbeat (1 Hz)
  static void _generateI2cScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final sclHalfPeriod = math.max(2, sampleRate ~/ 200000); // 100 kHz clock -> period = 10 samples at 1 MHz
    final sclPeriod = sclHalfPeriod * 2;

    // Total bits per transaction:
    // 4 idle + 1 Start + 9 (Addr 0x48 W + ACK) + 9 (Reg 0x01 + ACK) + 9 (Data 0xA5 + ACK) + 1 Stop + 10 idle = 43 bits
    const sdaBits = [
      // Idle high
      1, 1, 1, 1,
      // Start condition (special handling: drops while SCL is high)
      0,
      // Byte 1: Addr 0x48 (0b1001000) + W (0) + ACK (0)
      1, 0, 0, 1, 0, 0, 0, 0, 0,
      // Byte 2: Reg 0x01 (0b00000001) + ACK (0)
      0, 0, 0, 0, 0, 0, 0, 1, 0,
      // Byte 3: Data 0xA5 (0b10100101) + ACK (0)
      1, 0, 1, 0, 0, 1, 0, 1, 0,
      // Stop condition (rises while SCL is high)
      1,
      // Idle
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    ];

    final frameLen = sdaBits.length * sclPeriod;

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      final f = s % frameLen;
      final bitIdx = f ~/ sclPeriod;
      final phase = f % sclPeriod;

      int scl = 1;
      int sda = 1;
      int intPin = 1;

      // SCL toggles only during active transmission (bits 5 to 32)
      if (bitIdx >= 5 && bitIdx <= 31) {
        scl = (phase < sclHalfPeriod) ? 0 : 1;
      } else {
        scl = 1; // Idle high
      }

      // SDA generation
      if (bitIdx == 4) {
        // Start condition: SDA drops while SCL is high
        sda = (phase < sclHalfPeriod) ? 1 : 0;
      } else if (bitIdx == 32) {
        // Stop condition: SDA rises while SCL is high
        sda = (phase < sclHalfPeriod) ? 0 : 1;
      } else if (bitIdx < sdaBits.length) {
        sda = sdaBits[bitIdx];
      }

      // Sensor INT# line: pulses low before transaction
      if (bitIdx < 3) {
        intPin = 0;
      }

      int byteVal = 0;
      if (scl == 1) byteVal |= (1 << 0); // D0: SCL
      if (sda == 1) byteVal |= (1 << 1); // D1: SDA
      if (intPin == 1) byteVal |= (1 << 2); // D2: INT#

      // D7: Heartbeat
      if ((s % sampleRate) < (sampleRate ~/ 25)) byteVal |= (1 << 7);

      buffer[i] = byteVal;
    }
  }

  /// SPI Bus Scenario:
  /// D0: SCLK (200 kHz, Mode 0)
  /// D1: MOSI (Master Out: 0x9F JEDEC ID Command, 0x00, 0x00, 0x00)
  /// D2: MISO (Slave In: 0x00, 0xEF Manufacturer, 0x40 Type, 0x15 Capacity)
  /// D3: CS# (Active-Low Chip Select)
  /// D7: Heartbeat
  static void _generateSpiScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final sclkHalf = math.max(2, sampleRate ~/ 400000); // 200 kHz clock
    final sclkPeriod = sclkHalf * 2;

    // 4 bytes: 32 clock cycles
    const mosiBytes = [0x9F, 0x00, 0x00, 0x00];
    const misoBytes = [0x00, 0xEF, 0x40, 0x15];

    // Frame: 8 idle + 32 clocks + 8 idle = 48 clock periods
    final frameClocks = 48;
    final frameLen = frameClocks * sclkPeriod;

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      final f = s % frameLen;
      final clockIdx = f ~/ sclkPeriod;
      final phase = f % sclkPeriod;

      int sclk = 0;
      int mosi = 0;
      int miso = 0;
      int cs = 1; // Default idle high

      // Active CS# region (clocks 8 to 40)
      if (clockIdx >= 8 && clockIdx < 40) {
        cs = 0; // Active low

        // SCLK Mode 0: idle low, pulse high in second half
        sclk = (phase >= sclkHalf) ? 1 : 0;

        final activeBitIdx = clockIdx - 8;
        final byteIdx = activeBitIdx ~/ 8;
        final bitInByte = 7 - (activeBitIdx % 8); // MSB first

        if (byteIdx < mosiBytes.length) {
          mosi = (mosiBytes[byteIdx] >> bitInByte) & 1;
          miso = (misoBytes[byteIdx] >> bitInByte) & 1;
        }
      }

      int byteVal = 0;
      if (sclk == 1) byteVal |= (1 << 0); // D0: SCLK
      if (mosi == 1) byteVal |= (1 << 1); // D1: MOSI
      if (miso == 1) byteVal |= (1 << 2); // D2: MISO
      if (cs == 1) byteVal |= (1 << 3);   // D3: CS#
      if ((s % sampleRate) < (sampleRate ~/ 25)) byteVal |= (1 << 7); // D7: Heartbeat

      buffer[i] = byteVal;
    }
  }

  /// PWM Multi-Frequency & Duty Cycle Scenario:
  /// D0: 20 kHz Motor PWM (75% Duty Cycle)
  /// D1: 1 kHz PWM with 2 Hz Sine-Swept Duty Cycle (10% to 90%)
  /// D2: 50 kHz High-Speed SMPS PWM (50% Duty Cycle)
  /// D3: 100 Hz Servo Pulse (1.5 ms Center)
  /// D7: 1 Hz Heartbeat
  static void _generatePwmScenario(Uint8List buffer, int sampleRate, int length, int offset) {
    final p20k = math.max(4, sampleRate ~/ 20000);
    final p1k = math.max(4, sampleRate ~/ 1000);
    final p50k = math.max(2, sampleRate ~/ 50000);
    final p100 = math.max(10, sampleRate ~/ 100);
    final servoCenterSamples = (sampleRate * 0.0015).toInt(); // 1.5 ms

    for (int i = 0; i < length; i++) {
      final s = offset + i;
      int byteVal = 0;

      // D0: 20 kHz 75% duty
      if ((s % p20k) < (p20k * 0.75)) byteVal |= (1 << 0);

      // D1: 1 kHz Sine-modulated duty cycle
      final mod = 0.5 + 0.4 * math.sin((s / sampleRate) * 2 * math.pi * 2.0);
      if ((s % p1k) < (p1k * mod)) byteVal |= (1 << 1);

      // D2: 50 kHz 50% duty
      if ((s % p50k) < (p50k * 0.50)) byteVal |= (1 << 2);

      // D3: 100 Hz servo (1.5ms pulse)
      if ((s % p100) < servoCenterSamples) byteVal |= (1 << 3);

      // D7: Heartbeat
      if ((s % sampleRate) < (sampleRate ~/ 25)) byteVal |= (1 << 7);

      buffer[i] = byteVal;
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

