import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/capture_data.dart';
import '../models/uart_packet.dart';
import '../models/i2c_packet.dart';
import '../models/spi_packet.dart';
import '../models/pwm_measurement.dart';

class WaveformPainter extends CustomPainter {
  final CaptureData capture;
  final double viewOffsetSamples; // start sample index in viewport
  final double samplesPerPixel;   // zoom factor: samples displayed per horizontal pixel
  final double verticalScrollOffset; // vertical scroll offset for channels
  final double cursorASample;     // sample index for Cursor A (-1 if none)
  final double cursorBSample;     // sample index for Cursor B (-1 if none)
  final double? triggerSample;    // sample index of trigger point (if locked)
  final Color? triggerColor;      // color of trigger channel
  final Set<int> activeChannels;  // enabled channels (0..7)
  final UartConfig? uartConfig;   // UART protocol decoder configuration
  final List<UartPacket>? uartPackets; // Decoded UART packets
  final I2cConfig? i2cConfig;     // I2C protocol decoder configuration
  final List<I2cPacket>? i2cPackets;   // Decoded I2C packets
  final SpiConfig? spiConfig;     // SPI protocol decoder configuration
  final List<SpiPacket>? spiPackets;   // Decoded SPI packets
  final PwmConfig? pwmConfig;     // PWM measurement configuration
  final PwmMeasurement? pwmMeasurement; // Calculated PWM metrics

  static const List<Color> channelColors = [
    Color(0xFF00E676), // D0: Bright Green
    Color(0xFF00E5FF), // D1: Neon Cyan
    Color(0xFFFFD600), // D2: Vibrant Yellow
    Color(0xFFFF9100), // D3: Bright Orange
    Color(0xFFE040FB), // D4: Neon Magenta
    Color(0xFFFF5252), // D5: Coral Red
    Color(0xFFAEEA00), // D6: Lime Green
    Color(0xFF1DE9B6), // D7: Teal
  ];

  static const double labelWidth = 52.0;
  static const double timeAxisHeight = 28.0;
  static const double channelHeight = 44.0;
  static const double trackMargin = 8.0;

  WaveformPainter({
    required this.capture,
    required this.viewOffsetSamples,
    required this.samplesPerPixel,
    this.verticalScrollOffset = 0.0,
    this.cursorASample = -1,
    this.cursorBSample = -1,
    this.triggerSample,
    this.triggerColor,
    this.uartConfig,
    this.uartPackets,
    this.i2cConfig,
    this.i2cPackets,
    this.spiConfig,
    this.spiPackets,
    this.pwmConfig,
    this.pwmMeasurement,
    Set<int>? activeChannels,
  }) : activeChannels = activeChannels ?? {0, 1, 2, 3, 4, 5, 6, 7};


  @override
  void paint(Canvas canvas, Size size) {
    // 1. Background
    final bgPaint = Paint()..color = const Color(0xFF12141A);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final waveWidth = size.width - labelWidth;
    const totalChannels = 8;
    final visibleSampleCount = waveWidth * samplesPerPixel;

    // Grid lines paint
    final gridPaint = Paint()
      ..color = const Color(0xFF262C38)
      ..strokeWidth = 1.0;

    // 2. Vertical Time Slot Grid Lines (Moving synchronously with signals)
    _drawTimeGridLines(canvas, size, waveWidth);

    // 3. Channels Area (Clipped below Timeline Ruler with vertical translation)
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, timeAxisHeight, size.width, math.max(0.0, size.height - timeAxisHeight)));
    canvas.translate(0, -verticalScrollOffset);

    // Channel separator grid
    for (int i = 0; i <= totalChannels; i++) {
      final y = timeAxisHeight + i * channelHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw Channels
    for (int ch = 0; ch < totalChannels; ch++) {
      final trackY = timeAxisHeight + ch * channelHeight;

      // Label background
      final labelBg = Paint()..color = const Color(0xFF1A1E26);
      canvas.drawRect(Rect.fromLTWH(0, trackY, labelWidth, channelHeight), labelBg);
      canvas.drawLine(Offset(labelWidth, trackY), Offset(labelWidth, trackY + channelHeight), gridPaint);

      final isUartChannel = (uartConfig != null && uartConfig!.enabled && uartConfig!.channel == ch);
      final isI2cScl = (i2cConfig != null && i2cConfig!.enabled && i2cConfig!.sclChannel == ch);
      final isI2cSda = (i2cConfig != null && i2cConfig!.enabled && i2cConfig!.sdaChannel == ch);
      final isSpiSclk = (spiConfig != null && spiConfig!.enabled && spiConfig!.sclkChannel == ch);
      final isSpiMosi = (spiConfig != null && spiConfig!.enabled && spiConfig!.mosiChannel == ch);
      final isSpiMiso = (spiConfig != null && spiConfig!.enabled && spiConfig!.misoChannel == ch);
      final isSpiCs = (spiConfig != null && spiConfig!.enabled && spiConfig!.csChannel == ch);
      final isPwmChannel = (pwmConfig != null && pwmConfig!.enabled && pwmConfig!.channel == ch);

      String? protocolTag;
      Color protocolTagColor = const Color(0xFF00E5FF);
      if (isUartChannel) {
        protocolTag = 'UART';
        protocolTagColor = const Color(0xFF00E5FF);
      } else if (isI2cScl) {
        protocolTag = 'I2C CLK';
        protocolTagColor = const Color(0xFFFFD600);
      } else if (isI2cSda) {
        protocolTag = 'I2C DAT';
        protocolTagColor = const Color(0xFFFFD600);
      } else if (isSpiSclk) {
        protocolTag = 'SPI CLK';
        protocolTagColor = const Color(0xFFE040FB);
      } else if (isSpiMosi) {
        protocolTag = 'SPI MOSI';
        protocolTagColor = const Color(0xFFE040FB);
      } else if (isSpiMiso) {
        protocolTag = 'SPI MISO';
        protocolTagColor = const Color(0xFFE040FB);
      } else if (isSpiCs) {
        protocolTag = 'SPI CS#';
        protocolTagColor = const Color(0xFFE040FB);
      } else if (isPwmChannel) {
        protocolTag = 'PWM';
        protocolTagColor = const Color(0xFFAEEA00);
      }

      // Label text
      final textPainter = TextPainter(
        text: TextSpan(
          text: 'D$ch',
          style: TextStyle(
            color: channelColors[ch],
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      if (protocolTag != null) {
        textPainter.paint(canvas, Offset(8, trackY + 5));
        final tagPainter = TextPainter(
          text: TextSpan(
            text: protocolTag,
            style: TextStyle(
              color: protocolTagColor,
              fontSize: 7.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tagPainter.paint(canvas, Offset(6, trackY + 24));
      } else {
        textPainter.paint(canvas, Offset(12, trackY + (channelHeight - textPainter.height) / 2));
      }

      if (!activeChannels.contains(ch)) continue;

      // Logic Levels: Top = High, Bottom = Low
      final highY = trackY + trackMargin;
      final lowY = trackY + channelHeight - trackMargin;

      _drawChannelWaveform(
        canvas: canvas,
        channel: ch,
        highY: highY,
        lowY: lowY,
        waveWidth: waveWidth,
        color: channelColors[ch],
      );

      // Protocol Decoder Tracks
      if (isUartChannel) {
        _drawUartDecoderTrack(
          canvas: canvas,
          channel: ch,
          trackY: trackY,
          waveWidth: waveWidth,
        );
      } else if (isI2cSda) {
        _drawI2cDecoderTrack(
          canvas: canvas,
          channel: ch,
          trackY: trackY,
          waveWidth: waveWidth,
        );
      } else if (isSpiMosi) {
        _drawSpiDecoderTrack(
          canvas: canvas,
          channel: ch,
          trackY: trackY,
          waveWidth: waveWidth,
          isMosi: true,
        );
      } else if (isSpiMiso) {
        _drawSpiDecoderTrack(
          canvas: canvas,
          channel: ch,
          trackY: trackY,
          waveWidth: waveWidth,
          isMosi: false,
        );
      }

      // PWM Measurement Badge Overlay
      if (isPwmChannel && pwmMeasurement != null && pwmMeasurement!.frequencyHz > 0) {
        _drawPwmOverlay(
          canvas: canvas,
          channel: ch,
          trackY: trackY,
          waveWidth: waveWidth,
        );
      }

    }
    canvas.restore();

    // 4. Timeline Ruler (Pinned at Top, drawn over channels with moving time slots)
    _drawTimeline(canvas, size, waveWidth, visibleSampleCount);

    // 5. Draw Cursors
    _drawCursors(canvas, size, waveWidth);

    // 6. Draw Trigger Marker & Dashed Line
    _drawTriggerIndicator(canvas, size, waveWidth);

    // 7. Draw Vertical Scrollbar if channels exceed viewport height
    _drawVerticalScrollbar(canvas, size, totalChannels);
  }

  void _drawTimeGridLines(Canvas canvas, Size size, double waveWidth) {
    if (capture.sampleRate <= 0) return;
    final dtPerPixel = (1.0 / capture.sampleRate) * samplesPerPixel;
    const targetPixelSpacing = 80.0;
    final timeStep = _niceTimeStep(targetPixelSpacing * dtPerPixel);

    final startTimeSec = capture.timeOffsetSeconds + (viewOffsetSamples / capture.sampleRate);
    final firstTickTime = (startTimeSec / timeStep).floor() * timeStep;

    final gridLinePaint = Paint()
      ..color = const Color(0xFF1E2430)
      ..strokeWidth = 1.0;

    for (double t = firstTickTime; ; t += timeStep) {
      final x = labelWidth + ((t - startTimeSec) / dtPerPixel);
      if (x > size.width) break;
      if (x < labelWidth) continue;

      canvas.drawLine(Offset(x, timeAxisHeight), Offset(x, size.height), gridLinePaint);
    }
  }

  void _drawVerticalScrollbar(Canvas canvas, Size size, int totalChannels) {
    final contentHeight = totalChannels * channelHeight;
    final viewHeight = size.height - timeAxisHeight;
    if (contentHeight <= viewHeight || viewHeight <= 0) return;

    final thumbHeight = math.max(24.0, (viewHeight / contentHeight) * viewHeight);
    final maxScroll = contentHeight - viewHeight;
    final scrollProgress = (verticalScrollOffset / maxScroll).clamp(0.0, 1.0);
    final thumbY = timeAxisHeight + scrollProgress * (viewHeight - thumbHeight);

    final trackPaint = Paint()..color = Colors.white.withValues(alpha: 0.05);
    canvas.drawRect(Rect.fromLTWH(size.width - 4, timeAxisHeight, 4, viewHeight), trackPaint);

    final thumbPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 5, thumbY, 4, thumbHeight),
      const Radius.circular(2),
    );
    canvas.drawRRect(rrect, thumbPaint);
  }

  void _drawTimeline(Canvas canvas, Size size, double waveWidth, double visibleSamples) {
    final rulerBg = Paint()..color = const Color(0xFF171A21);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, timeAxisHeight), rulerBg);

    final sepPaint = Paint()
      ..color = const Color(0xFF262C38)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, timeAxisHeight), Offset(size.width, timeAxisHeight), sepPaint);

    final tickPaint = Paint()
      ..color = const Color(0xFF4A5568)
      ..strokeWidth = 1.0;

    final textStyle = const TextStyle(color: Color(0xFF9E9E9E), fontSize: 10);

    // Calculate nice time intervals
    final dtPerPixel = (1.0 / capture.sampleRate) * samplesPerPixel;
    const targetPixelSpacing = 80.0;
    final timeStep = _niceTimeStep(targetPixelSpacing * dtPerPixel);

    final startTimeSec = capture.timeOffsetSeconds + (viewOffsetSamples / capture.sampleRate);
    final firstTickTime = (startTimeSec / timeStep).floor() * timeStep;

    for (double t = firstTickTime; ; t += timeStep) {
      final x = labelWidth + ((t - startTimeSec) / dtPerPixel);
      if (x > size.width) break;
      if (x < labelWidth) continue;

      // Minor tick in ruler
      canvas.drawLine(Offset(x, timeAxisHeight - 8), Offset(x, timeAxisHeight), tickPaint);

      // Label
      final label = CaptureData.formatTime(t);
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, 6));
    }
  }

  double _niceTimeStep(double target) {
    final exp = (math.log(target) / math.ln10).floor();
    final frac = target / math.pow(10, exp);
    double niceFrac;
    if (frac < 1.5) {
      niceFrac = 1.0;
    } else if (frac < 3.5) {
      niceFrac = 2.0;
    } else if (frac < 7.5) {
      niceFrac = 5.0;
    } else {
      niceFrac = 10.0;
    }
    return niceFrac * math.pow(10, exp);
  }

  void _drawChannelWaveform({
    required Canvas canvas,
    required int channel,
    required double highY,
    required double lowY,
    required double waveWidth,
    required Color color,
  }) {
    if (capture.totalSamples == 0) return;

    final wavePaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool hasStarted = false;
    int lastState = -1;

    // Iterate through screen pixels to draw
    for (double px = 0; px < waveWidth; px += 1.0) {
      final sampleStart = (viewOffsetSamples + px * samplesPerPixel).floor();
      final sampleEnd = (viewOffsetSamples + (px + 1) * samplesPerPixel).ceil().clamp(0, capture.totalSamples);

      if (sampleStart >= capture.totalSamples) break;
      if (sampleEnd <= 0) continue;

      final s0 = sampleStart.clamp(0, capture.totalSamples - 1);
      final s1 = (sampleEnd - 1).clamp(0, capture.totalSamples - 1);

      final state0 = capture.getBit(s0, channel);
      final x = labelWidth + px;

      if (samplesPerPixel <= 2.0) {
        // High zoom detail: exact transitions
        final y = state0 == 1 ? highY : lowY;
        if (!hasStarted) {
          path.moveTo(x, y);
          hasStarted = true;
        } else {
          if (lastState != state0) {
            path.lineTo(x, state0 == 1 ? lowY : highY); // vertical edge
            path.lineTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        lastState = state0;
      } else {
        // Zoomed-out: check if there are transitions in this pixel column
        bool hasHigh = false;
        bool hasLow = false;
        final step = math.max(1, (sampleEnd - sampleStart) ~/ 16);
        for (int s = s0; s <= s1; s += step) {
          if (capture.getBit(s, channel) == 1) {
            hasHigh = true;
          } else {
            hasLow = true;
          }
          if (hasHigh && hasLow) break;
        }

        if (hasHigh && hasLow) {
          // Transition / pulse inside this pixel column
          if (!hasStarted) {
            path.moveTo(x, highY);
            hasStarted = true;
          }
          path.lineTo(x, lowY);
          path.lineTo(x, highY);
          lastState = 1;
        } else {
          final curState = hasHigh ? 1 : 0;
          final y = curState == 1 ? highY : lowY;
          if (!hasStarted) {
            path.moveTo(x, y);
            hasStarted = true;
          } else {
            if (lastState != curState) {
              path.lineTo(x, curState == 1 ? lowY : highY);
              path.lineTo(x, y);
            } else {
              path.lineTo(x, y);
            }
          }
          lastState = curState;
        }
      }
    }

    canvas.drawPath(path, wavePaint);
  }

  void _drawCursors(Canvas canvas, Size size, double waveWidth) {
    final cursorPaintA = Paint()
      ..color = const Color(0xFFFFEB3B)
      ..strokeWidth = 1.5;

    final cursorPaintB = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 1.5;

    double? xA;
    double? xB;

    if (cursorASample >= 0) {
      xA = labelWidth + (cursorASample - viewOffsetSamples) / samplesPerPixel;
      if (xA >= labelWidth && xA <= size.width) {
        canvas.drawLine(Offset(xA, 0), Offset(xA, size.height), cursorPaintA);
        _drawCursorHandle(canvas, xA, 'A', const Color(0xFFFFEB3B));
      }
    }

    if (cursorBSample >= 0) {
      xB = labelWidth + (cursorBSample - viewOffsetSamples) / samplesPerPixel;
      if (xB >= labelWidth && xB <= size.width) {
        canvas.drawLine(Offset(xB, 0), Offset(xB, size.height), cursorPaintB);
        _drawCursorHandle(canvas, xB, 'B', const Color(0xFF00E5FF));
      }
    }

    // Draw Delta HUD if both cursors are active
    if (cursorASample >= 0 && cursorBSample >= 0) {
      final deltaSamples = (cursorBSample - cursorASample).abs();
      final dt = deltaSamples / capture.sampleRate;
      final freq = dt > 0 ? 1.0 / dt : 0.0;

      final hudText = 'Δt = ${CaptureData.formatTime(dt)}  |  f ≈ ${CaptureData.formatFrequency(freq)}';
      final tp = TextPainter(
        text: TextSpan(
          text: hudText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final hudBg = Paint()..color = const Color(0xCC1A1E26);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - tp.width - 24, size.height - 36, tp.width + 16, 28),
        const Radius.circular(6),
      );
      canvas.drawRRect(rrect, hudBg);
      tp.paint(canvas, Offset(size.width - tp.width - 16, size.height - 30));
    }
  }

  void _drawCursorHandle(Canvas canvas, double x, String label, Color color) {
    final bg = Paint()..color = color;
    final path = Path()
      ..moveTo(x - 8, 0)
      ..lineTo(x + 8, 0)
      ..lineTo(x + 8, 14)
      ..lineTo(x, 22)
      ..lineTo(x - 8, 14)
      ..close();
    canvas.drawPath(path, bg);

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, 2));
  }

  void _drawTriggerIndicator(Canvas canvas, Size size, double waveWidth) {
    if (triggerSample == null || triggerSample! < 0) return;
    final x = labelWidth + (triggerSample! - viewOffsetSamples) / samplesPerPixel;
    if (x < labelWidth || x > size.width) return;

    final color = triggerColor ?? const Color(0xFFFFD600);

    // Dashed vertical trigger line through all channels
    final trigPaint = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 1.5;

    const dashHeight = 4.0;
    const dashSpace = 4.0;
    double startY = timeAxisHeight;
    while (startY < size.height) {
      canvas.drawLine(Offset(x, startY), Offset(x, math.min(startY + dashHeight, size.height)), trigPaint);
      startY += dashHeight + dashSpace;
    }

    // Trigger handle badge at the top of the ruler: "▼ T"
    final badgePaint = Paint()..color = color;
    final badgePath = Path()
      ..moveTo(x - 7, timeAxisHeight)
      ..lineTo(x + 7, timeAxisHeight)
      ..lineTo(x + 7, timeAxisHeight - 12)
      ..lineTo(x - 7, timeAxisHeight - 12)
      ..close();
    canvas.drawPath(badgePath, badgePaint);

    final arrowPath = Path()
      ..moveTo(x - 5, timeAxisHeight)
      ..lineTo(x + 5, timeAxisHeight)
      ..lineTo(x, timeAxisHeight + 6)
      ..close();
    canvas.drawPath(arrowPath, badgePaint);

    final tp = TextPainter(
      text: const TextSpan(
        text: 'T',
        style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, timeAxisHeight - 12));
  }

  void _drawUartDecoderTrack({
    required Canvas canvas,
    required int channel,
    required double trackY,
    required double waveWidth,
  }) {
    if (uartPackets == null || uartPackets!.isEmpty || uartConfig == null) return;

    final bubbleTop = trackY + 22.0;
    const bubbleHeight = 16.0;
    final bubbleBottom = bubbleTop + bubbleHeight;

    for (final packet in uartPackets!) {
      final xStart = labelWidth + (packet.startSample - viewOffsetSamples) / samplesPerPixel;
      final xEnd = labelWidth + (packet.endSample - viewOffsetSamples) / samplesPerPixel;

      // Skip packets outside visible viewport
      if (xEnd < labelWidth || xStart > labelWidth + waveWidth) continue;

      final clampedXStart = math.max(labelWidth, xStart);
      final clampedXEnd = math.min(labelWidth + waveWidth, xEnd);
      final bubbleWidth = clampedXEnd - clampedXStart;

      if (bubbleWidth < 2.0) {
        final dotPaint = Paint()
          ..color = packet.isFramingError ? Colors.redAccent : channelColors[channel]
          ..strokeWidth = 1.0;
        canvas.drawLine(Offset(clampedXStart, bubbleTop), Offset(clampedXStart, bubbleBottom), dotPaint);
        continue;
      }

      final isErr = packet.isFramingError || packet.isParityError;
      final fillColor = isErr
          ? Colors.redAccent.withValues(alpha: 0.45)
          : const Color(0xFF14243B).withValues(alpha: 0.90);
      final strokeColor = isErr ? Colors.redAccent : channelColors[channel];

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTRB(clampedXStart, bubbleTop, clampedXEnd, bubbleBottom),
        const Radius.circular(3),
      );

      canvas.drawRRect(rrect, Paint()..color = fillColor);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = strokeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      if (bubbleWidth > 10.0) {
        String label;
        if (isErr) {
          label = 'ERR';
        } else if (bubbleWidth > 60.0) {
          label = packet.displayText(uartConfig!.displayFormat);
        } else if (bubbleWidth > 20.0) {
          label = packet.displayText(UartDisplayFormat.ascii);
        } else {
          label = packet.displayText(UartDisplayFormat.hex);
        }

        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: isErr ? Colors.redAccent : Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.max(8, bubbleWidth - 4));

        final textX = clampedXStart + (bubbleWidth - tp.width) / 2;
        final textY = bubbleTop + (bubbleHeight - tp.height) / 2;
        tp.paint(canvas, Offset(textX, textY));
      }
    }
  }

  void _drawI2cDecoderTrack({
    required Canvas canvas,
    required int channel,
    required double trackY,
    required double waveWidth,
  }) {
    if (i2cPackets == null || i2cPackets!.isEmpty || i2cConfig == null) return;

    final bubbleTop = trackY + 22.0;
    const bubbleHeight = 16.0;
    final bubbleBottom = bubbleTop + bubbleHeight;

    for (final packet in i2cPackets!) {
      final xStart = labelWidth + (packet.startSample - viewOffsetSamples) / samplesPerPixel;
      final xEnd = labelWidth + (packet.endSample - viewOffsetSamples) / samplesPerPixel;

      if (xEnd < labelWidth || xStart > labelWidth + waveWidth) continue;

      final clampedXStart = math.max(labelWidth, xStart);
      final clampedXEnd = math.min(labelWidth + waveWidth, xEnd);
      final bubbleWidth = math.max(14.0, clampedXEnd - clampedXStart);

      Color fillColor;
      Color strokeColor;

      switch (packet.type) {
        case I2cPacketType.start:
        case I2cPacketType.repeatedStart:
          fillColor = const Color(0xFF00E676).withValues(alpha: 0.35);
          strokeColor = const Color(0xFF00E676);
          break;
        case I2cPacketType.address:
          fillColor = const Color(0xFFFFD600).withValues(alpha: 0.35);
          strokeColor = const Color(0xFFFFD600);
          break;
        case I2cPacketType.data:
          fillColor = const Color(0xFF00E5FF).withValues(alpha: 0.30);
          strokeColor = const Color(0xFF00E5FF);
          break;
        case I2cPacketType.stop:
          fillColor = Colors.redAccent.withValues(alpha: 0.40);
          strokeColor = Colors.redAccent;
          break;
      }

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTRB(clampedXStart, bubbleTop, clampedXStart + bubbleWidth, bubbleBottom),
        const Radius.circular(3),
      );

      canvas.drawRRect(rrect, Paint()..color = fillColor);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = strokeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      final label = bubbleWidth > 35.0 ? packet.bubbleLabel : packet.shortLabel;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: strokeColor,
            fontSize: 8.5,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(6, bubbleWidth - 2));

      final textX = clampedXStart + (bubbleWidth - tp.width) / 2;
      final textY = bubbleTop + (bubbleHeight - tp.height) / 2;
      tp.paint(canvas, Offset(textX, textY));
    }
  }

  void _drawSpiDecoderTrack({
    required Canvas canvas,
    required int channel,
    required double trackY,
    required double waveWidth,
    required bool isMosi,
  }) {
    if (spiPackets == null || spiPackets!.isEmpty || spiConfig == null) return;

    final bubbleTop = trackY + 22.0;
    const bubbleHeight = 16.0;
    final bubbleBottom = bubbleTop + bubbleHeight;

    for (final packet in spiPackets!) {
      final xStart = labelWidth + (packet.startSample - viewOffsetSamples) / samplesPerPixel;
      final xEnd = labelWidth + (packet.endSample - viewOffsetSamples) / samplesPerPixel;

      if (xEnd < labelWidth || xStart > labelWidth + waveWidth) continue;

      final clampedXStart = math.max(labelWidth, xStart);
      final clampedXEnd = math.min(labelWidth + waveWidth, xEnd);
      final bubbleWidth = math.max(12.0, clampedXEnd - clampedXStart);

      final strokeColor = isMosi ? const Color(0xFFE040FB) : const Color(0xFF1DE9B6);
      final fillColor = strokeColor.withValues(alpha: 0.25);

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTRB(clampedXStart, bubbleTop, clampedXStart + bubbleWidth, bubbleBottom),
        const Radius.circular(3),
      );

      canvas.drawRRect(rrect, Paint()..color = fillColor);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = strokeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      final label = bubbleWidth > 35.0
          ? (isMosi ? packet.mosiBubbleLabel : packet.misoBubbleLabel)
          : (isMosi ? packet.mosiHex : packet.misoHex);

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 8.5,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(6, bubbleWidth - 2));

      final textX = clampedXStart + (bubbleWidth - tp.width) / 2;
      final textY = bubbleTop + (bubbleHeight - tp.height) / 2;
      tp.paint(canvas, Offset(textX, textY));
    }
  }

  void _drawPwmOverlay({
    required Canvas canvas,
    required int channel,
    required double trackY,
    required double waveWidth,
  }) {
    if (pwmMeasurement == null) return;

    final badgeText = '${pwmMeasurement!.frequencyFormatted}  |  ${pwmMeasurement!.dutyFormatted} D';
    final tp = TextPainter(
      text: TextSpan(
        text: badgeText,
        style: const TextStyle(
          color: Color(0xFFAEEA00),
          fontSize: 9.5,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeWidth = tp.width + 12.0;
    final badgeHeight = 16.0;
    final badgeRight = labelWidth + waveWidth - 12.0;
    final badgeLeft = badgeRight - badgeWidth;
    final badgeTop = trackY + 4.0;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(badgeLeft, badgeTop, badgeWidth, badgeHeight),
      const Radius.circular(4),
    );

    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF162214).withValues(alpha: 0.85));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0xFFAEEA00).withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    tp.paint(canvas, Offset(badgeLeft + 6.0, badgeTop + (badgeHeight - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.capture != capture ||
        oldDelegate.viewOffsetSamples != viewOffsetSamples ||
        oldDelegate.samplesPerPixel != samplesPerPixel ||
        oldDelegate.verticalScrollOffset != verticalScrollOffset ||
        oldDelegate.cursorASample != cursorASample ||
        oldDelegate.cursorBSample != cursorBSample ||
        oldDelegate.triggerSample != triggerSample ||
        oldDelegate.triggerColor != triggerColor ||
        oldDelegate.uartConfig != uartConfig ||
        oldDelegate.uartPackets != uartPackets ||
        oldDelegate.i2cConfig != i2cConfig ||
        oldDelegate.i2cPackets != i2cPackets ||
        oldDelegate.spiConfig != spiConfig ||
        oldDelegate.spiPackets != spiPackets ||
        oldDelegate.pwmConfig != pwmConfig ||
        oldDelegate.pwmMeasurement != pwmMeasurement;
  }
}

