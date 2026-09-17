import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/capture_data.dart';
import '../models/trigger_config.dart';
import '../models/uart_packet.dart';
import '../models/i2c_packet.dart';
import '../models/spi_packet.dart';
import '../models/pwm_measurement.dart';
import '../services/uart_decoder.dart';
import '../services/i2c_decoder.dart';
import '../services/spi_decoder.dart';
import '../services/pwm_decoder.dart';
import 'waveform_painter.dart';

class WaveformViewer extends StatefulWidget {
  final CaptureData capture;
  final bool isContinuous;

  const WaveformViewer({
    super.key,
    required this.capture,
    this.isContinuous = false,
  });

  @override
  State<WaveformViewer> createState() => _WaveformViewerState();
}

class _WaveformViewerState extends State<WaveformViewer> {
  double _viewOffsetSamples = 0;
  double _samplesPerPixel = 100.0;
  double _verticalScrollOffset = 0.0;
  double _cursorASample = -1;
  double _cursorBSample = -1;
  int _activeCursorToPlace = 0; // 0 = A, 1 = B
  bool _autoScroll = true;

  double _baseZoom = 100.0;
  double _baseFocalSample = 0.0;

  // Oscilloscope-like Trigger synchronization state
  TriggerConfig _triggerConfig = const TriggerConfig(
    enabled: true,
    channel: 0,
    slope: TriggerSlope.rising,
    screenRatio: 0.15,
  );
  double? _lockedTriggerSample;

  // UART Protocol Decoder state
  UartConfig _uartConfig = const UartConfig(
    enabled: true,
    channel: 0,
    baudRate: 115200,
    dataBits: 8,
    parity: UartParity.none,
    stopBits: 1,
    displayFormat: UartDisplayFormat.both,
  );
  List<UartPacket> _decodedUartPackets = [];
  int _uartTerminalSubMode = 0; // 0 = Texto Plano, 1 = Símbolos de Control, 2 = Visor HEX
  int _hexBytesPerLine = 8; // 8 bytes (mobile friendly) or 16 bytes (classic CoolTerm)
  int? _selectedHexByteIndex; // Synchronized selection between HEX & ASCII panes

  // I2C Protocol Decoder state
  I2cConfig _i2cConfig = const I2cConfig(
    enabled: true,
    sclChannel: 0,
    sdaChannel: 1,
  );
  List<I2cPacket> _decodedI2cPackets = [];

  // SPI Protocol Decoder state
  SpiConfig _spiConfig = const SpiConfig(
    enabled: false,
    sclkChannel: 0,
    mosiChannel: 1,
    misoChannel: 2,
    csChannel: 3,
  );
  List<SpiPacket> _decodedSpiPackets = [];

  // PWM Measurement state
  PwmConfig _pwmConfig = const PwmConfig(
    enabled: false,
    channel: 0,
  );
  PwmMeasurement _pwmMeasurement = const PwmMeasurement();


  bool get _isTriggerActive =>
      _triggerConfig.enabled && _triggerConfig.slope != TriggerSlope.none;

  String get _triggerBadgeText {
    if (!_isTriggerActive) return 'TRIG: LIBRE';
    final slopeSym = switch (_triggerConfig.slope) {
      TriggerSlope.rising => '↑',
      TriggerSlope.falling => '↓',
      TriggerSlope.any => '↕',
      TriggerSlope.none => '○',
    };
    final status = _lockedTriggerSample != null ? 'LOCK' : 'AUTO';
    return 'TRIG: D${_triggerConfig.channel} $slopeSym ($status)';
  }

  @override
  void initState() {
    super.initState();
    if (widget.isContinuous) {
      _samplesPerPixel = 1.0;
      _autoScroll = true;
    } else {
      _fitToScreen();
    }
  }

  @override
  void didUpdateWidget(covariant WaveformViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isContinuous) {
      if (!oldWidget.isContinuous) {
        _samplesPerPixel = 1.0; // crisp zoom to see individual UART bits and decoded bubbles
        _autoScroll = true;
      }
    } else if (oldWidget.capture != widget.capture) {
      _fitToScreen();
    }
  }

  double _maxVerticalScroll(double viewportHeight) {
    const totalChannels = 8;
    final totalContentHeight = WaveformPainter.timeAxisHeight + totalChannels * WaveformPainter.channelHeight;
    return math.max(0.0, totalContentHeight - viewportHeight);
  }

  void _fitToScreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final waveWidth = renderBox.size.width - WaveformPainter.labelWidth;
        if (waveWidth > 0 && widget.capture.totalSamples > 0) {
          setState(() {
            _samplesPerPixel = (widget.capture.totalSamples / waveWidth).clamp(0.01, 1000000.0);
            _viewOffsetSamples = 0;
            _verticalScrollOffset = 0;
          });
        }
      }
    });
  }

  void _showTriggerSettingsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final activeColor = WaveformPainter.channelColors[_triggerConfig.channel];
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with Enable Switch
                    Row(
                      children: [
                        const Icon(Icons.flash_on, color: Color(0xFFFFD600), size: 22),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Sincronización de Trigger (Osciloscopio)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                        Switch(
                          value: _triggerConfig.enabled,
                          activeThumbColor: const Color(0xFF00E5FF),
                          onChanged: (val) {
                            setModalState(() {
                              _triggerConfig = _triggerConfig.copyWith(enabled: val);
                            });
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 18),

                    // Trigger Channel selector
                    const Text('Canal de Disparo:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(8, (i) {
                        final isSelected = _triggerConfig.channel == i;
                        final chColor = WaveformPainter.channelColors[i];
                        return ChoiceChip(
                          label: Text(
                            'D$i',
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: chColor,
                          backgroundColor: const Color(0xFF262C38),
                          side: BorderSide(color: isSelected ? chColor : Colors.white24),
                          onSelected: _triggerConfig.enabled
                              ? (sel) {
                                  if (sel) {
                                    setModalState(() {
                                      _triggerConfig = _triggerConfig.copyWith(channel: i);
                                    });
                                    setState(() {});
                                  }
                                }
                              : null,
                        );
                      }),
                    ),
                    const SizedBox(height: 16),

                    // Slope selector
                    const Text('Flanco de Sincronización:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildSlopeChip(setModalState, TriggerSlope.rising, 'Subida (↑ 0→1)', activeColor),
                        _buildSlopeChip(setModalState, TriggerSlope.falling, 'Bajada (↓ 1→0)', activeColor),
                        _buildSlopeChip(setModalState, TriggerSlope.any, 'Ambos (↕ Cambio)', activeColor),
                        _buildSlopeChip(setModalState, TriggerSlope.none, 'Libre / Roll (○)', activeColor),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Horizontal Screen Position
                    const Text('Posición del Trigger en Pantalla:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildRatioChip(setModalState, 0.10, '10% (Izq)'),
                          const SizedBox(width: 8),
                          _buildRatioChip(setModalState, 0.15, '15% (Osciloscopio)'),
                          const SizedBox(width: 8),
                          _buildRatioChip(setModalState, 0.25, '25% (Cuarto)'),
                          const SizedBox(width: 8),
                          _buildRatioChip(setModalState, 0.50, '50% (Centro)'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Explanation note
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF131720),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: activeColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _triggerConfig.enabled && _triggerConfig.slope != TriggerSlope.none
                                  ? 'La señal se anclará al flanco en D${_triggerConfig.channel}, manteniendo la onda fija y estable en pantalla mientras los datos fluyen.'
                                  : 'Modo libre: la señal se desplaza continuamente hacia la izquierda sin sincronización.',
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showUartDecoderModal() {
    int selectedTab = 0; // 0 = Terminal Serial, 1 = Configuración

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1E27),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final activeColor = WaveformPainter.channelColors[_uartConfig.channel];

            // Extract decoded text and stats
            final decodedAscii = StringBuffer();
            final decodedHex = StringBuffer();
            int errorCount = 0;

            for (final p in _decodedUartPackets) {
              if (p.isFramingError || p.isParityError) errorCount++;
              decodedAscii.write(p.consoleChar);
              decodedHex.write('${p.hexString.replaceAll('0x', '')} ');
            }

            final fullText = decodedAscii.toString();

            return Container(
              height: MediaQuery.of(ctx).size.height * 0.70,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top Title Bar
                  Row(
                    children: [
                      const Icon(Icons.terminal, color: Color(0xFF00E5FF), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Decodificador UART: D${_uartConfig.channel} @ ${_uartConfig.baudRate} bps',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Switch(
                        value: _uartConfig.enabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        onChanged: (val) {
                          setModalState(() {
                            _uartConfig = _uartConfig.copyWith(enabled: val);
                          });
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Tab selector: Terminal vs Settings
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 0 ? const Color(0xFF00E5FF) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 0 ? Colors.black : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.receipt_long, size: 16),
                          label: Text('Terminal (${_decodedUartPackets.length} bytes)'),
                          onPressed: () => setModalState(() => selectedTab = 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 1 ? const Color(0xFF00E5FF) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 1 ? Colors.black : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.settings, size: 16),
                          label: const Text('Ajustes Serial'),
                          onPressed: () => setModalState(() => selectedTab = 1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // TAB CONTENT
                  Expanded(
                    child: selectedTab == 0
                        ? _buildTerminalTab(setModalState, fullText, decodedHex.toString(), errorCount, activeColor)
                        : _buildSettingsTab(setModalState, activeColor),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTerminalTab(
    void Function(void Function()) setModalState,
    String asciiText,
    String hexText,
    int errors,
    Color channelColor,
  ) {
    // Generate Hex Dump string if needed
    final hexDumpBuffer = StringBuffer();
    if (_uartTerminalSubMode == 2) {
      final bpl = _hexBytesPerLine;
      hexDumpBuffer.writeln(HexDumpLine.headerText(bpl));
      hexDumpBuffer.writeln(HexDumpLine.dividerText(bpl));
      for (int i = 0; i < _decodedUartPackets.length; i += bpl) {
        final end = math.min(i + bpl, _decodedUartPackets.length);
        final rowPackets = _decodedUartPackets.sublist(i, end);
        final row = HexDumpLine(
          offset: i,
          bytes: rowPackets.map((p) => p.value).toList(),
          bytesPerLine: bpl,
        );
        final prefix = bpl == 8 ? '${row.offsetHex}:    ' : '${row.offsetHex}:   ';
        hexDumpBuffer.writeln('$prefix${row.hexBytes}  ${row.asciiChars}');
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sub-mode toggle & Action Buttons
        Row(
          children: [
            _buildTerminalModeChip(setModalState, 0, 'Texto', Icons.text_snippet),
            const SizedBox(width: 6),
            _buildTerminalModeChip(setModalState, 1, 'Símbolos', Icons.visibility),
            const SizedBox(width: 6),
            _buildTerminalModeChip(setModalState, 2, 'Visor HEX', Icons.grid_view),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.copy, size: 14, color: Color(0xFF00E5FF)),
              label: const Text('Copiar', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
              onPressed: () {
                final copyText = _uartTerminalSubMode == 2
                    ? hexDumpBuffer.toString()
                    : (_uartTerminalSubMode == 1
                        ? _decodedUartPackets.map((p) => p.isControlChar ? '[${p.controlAbbr ?? p.hexString}]' : String.fromCharCode(p.value)).join()
                        : asciiText);
                Clipboard.setData(ClipboardData(text: copyText));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Contenido copiado al portapapeles'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
        if (_uartTerminalSubMode == 2) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Text(
                'COLUMNAS:',
                style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
              const SizedBox(width: 8),
              _buildBplChip(setModalState, 8, '8 Bytes (Móvil)'),
              const SizedBox(width: 6),
              _buildBplChip(setModalState, 16, '16 Bytes (CoolTerm)'),
            ],
          ),
        ],
        const SizedBox(height: 6),

        // Stats summary bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF131720),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _uartTerminalSubMode == 2
                ? 'CoolTerm Hex View  |  ${_decodedUartPackets.length} bytes  |  $_hexBytesPerLine BPL  |  Errores: $errors'
                : 'Bytes recibidos: ${_decodedUartPackets.length}  |  Errores de encuadre: $errors',
            style: TextStyle(
              color: errors > 0 ? Colors.redAccent : const Color(0xFF80D8FF),
              fontSize: 10.5,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Terminal Console Screen
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0E14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: SingleChildScrollView(
              reverse: _uartTerminalSubMode != 2, // In Hex View, don't reverse so header is visible at top
              child: _buildTerminalContent(setModalState, asciiText, hexDumpBuffer.toString()),
            ),
          ),
        ),

        // Inspector Card for selected byte (when in Visor HEX mode)
        if (_uartTerminalSubMode == 2 && _selectedHexByteIndex != null && _selectedHexByteIndex! < _decodedUartPackets.length) ...[
          const SizedBox(height: 6),
          _buildHexByteInspectorCard(setModalState),
        ],
      ],
    );
  }

  Widget _buildHexByteInspectorCard(void Function(void Function()) setModalState) {
    if (_selectedHexByteIndex == null || _selectedHexByteIndex! >= _decodedUartPackets.length) {
      return const SizedBox();
    }
    final p = _decodedUartPackets[_selectedHexByteIndex!];
    final b = p.value;
    final hexStr = '0x${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    final decStr = '$b';
    final binStr = b.toRadixString(2).padLeft(8, '0');
    final octStr = '0o${b.toRadixString(8).padLeft(3, '0')}';
    final charLabel = p.isControlChar ? (p.controlAbbr ?? p.hexString) : "'${String.fromCharCode(b)}'";
    final offsetStr = _selectedHexByteIndex!.toRadixString(16).padLeft(_hexBytesPerLine <= 8 ? 4 : 6, '0').toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161E2E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.5), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF00E5FF)),
            ),
            child: Text(
              'Offset 0x$offsetStr',
              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildInspectorStat('HEX', hexStr, const Color(0xFF00E5FF)),
                  _buildInspectorStat('ASCII', charLabel, const Color(0xFF00E676)),
                  _buildInspectorStat('DEC', decStr, const Color(0xFFFFD600)),
                  _buildInspectorStat('BIN', binStr, Colors.white70),
                  _buildInspectorStat('OCT', octStr, const Color(0xFFE040FB)),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Colors.white54),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Deseleccionar',
            onPressed: () => setModalState(() => _selectedHexByteIndex = null),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectorStat(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 12.0),
      child: RichText(
        text: TextSpan(
          text: '$label: ',
          style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold),
          children: [
            TextSpan(
              text: value,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBplChip(
    void Function(void Function()) setModalState,
    int bpl,
    String label,
  ) {
    final isSel = _hexBytesPerLine == bpl;
    return ChoiceChip(
      label: Text(label, style: TextStyle(color: isSel ? Colors.black : Colors.white70, fontWeight: FontWeight.bold, fontSize: 10.5)),
      selected: isSel,
      selectedColor: const Color(0xFFFFD600),
      backgroundColor: const Color(0xFF1C2230),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: isSel ? const Color(0xFFFFD600) : Colors.white24),
      onSelected: (sel) {
        if (sel) {
          setModalState(() => _hexBytesPerLine = bpl);
        }
      },
    );
  }

  Widget _buildTerminalModeChip(
    void Function(void Function()) setModalState,
    int mode,
    String label,
    IconData icon,
  ) {
    final isSel = _uartTerminalSubMode == mode;
    return ChoiceChip(
      avatar: Icon(icon, size: 13, color: isSel ? Colors.black : Colors.white70),
      label: Text(label, style: TextStyle(color: isSel ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
      selected: isSel,
      selectedColor: const Color(0xFF00E5FF),
      backgroundColor: const Color(0xFF262C38),
      side: BorderSide(color: isSel ? const Color(0xFF00E5FF) : Colors.white24),
      onSelected: (sel) {
        if (sel) {
          setModalState(() => _uartTerminalSubMode = mode);
        }
      },
    );
  }

  Widget _buildTerminalContent(void Function(void Function()) setModalState, String asciiText, String hexDumpText) {
    if (_decodedUartPackets.isEmpty) {
      return const Text(
        '(Esperando tramas UART...)',
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white38),
      );
    }

    if (_uartTerminalSubMode == 0) {
      // 1. Plain text mode
      return SelectableText(
        asciiText,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          color: Color(0xFF00E676),
          height: 1.35,
        ),
      );
    } else if (_uartTerminalSubMode == 1) {
      // 2. Special Characters with explicit visual badges
      final spans = <InlineSpan>[];
      for (final p in _decodedUartPackets) {
        if (p.isControlChar) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF2E1738),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: const Color(0xFFE040FB), width: 0.9),
              ),
              child: Text(
                p.controlAbbr ?? p.hexString,
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE040FB),
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ));
          if (p.value == 10) {
            spans.add(const TextSpan(text: '\n'));
          }
        } else {
          spans.add(TextSpan(
            text: String.fromCharCode(p.value),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: Color(0xFF00E676),
            ),
          ));
        }
      }
      return SelectableText.rich(
        TextSpan(children: spans),
      );
    } else {
      // 3. CoolTerm Hex View: column-aligned, syntax-colored, with synchronized bi-directional selection!
      return _buildCoolTermInteractiveHexView(setModalState);
    }
  }

  Widget _buildCoolTermInteractiveHexView(void Function(void Function()) setModalState) {
    final bpl = _hexBytesPerLine;
    final totalBytes = _decodedUartPackets.length;
    final rowCount = (totalBytes + bpl - 1) ~/ bpl;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Column Header (CoolTerm style)
          Padding(
            padding: const EdgeInsets.only(bottom: 2.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: bpl <= 8 ? 64 : 76,
                  child: const Text(
                    'Offset',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF90CAF9),
                    ),
                  ),
                ),
                for (int b = 0; b < bpl; b++) ...[
                  SizedBox(
                    width: 24,
                    child: Text(
                      b.toRadixString(16).padLeft(2, '0').toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF90CAF9),
                      ),
                    ),
                  ),
                  if (bpl == 16 && b == 7) const SizedBox(width: 8)
                  else if (bpl == 8 && b == 3) const SizedBox(width: 8)
                  else if (b < bpl - 1) const SizedBox(width: 4),
                ],
                const SizedBox(width: 16),
                const Text(
                  'Decoded text',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF90CAF9),
                  ),
                ),
              ],
            ),
          ),

          // 2. Divider line
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: Text(
              HexDumpLine.dividerText(bpl),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: Color(0xFF37474F),
              ),
            ),
          ),

          // 3. Hex & ASCII Rows with synchronized bi-directional selection
          for (int r = 0; r < rowCount; r++)
            _buildCoolTermRow(setModalState, r, bpl),
        ],
      ),
    );
  }

  Widget _buildCoolTermRow(void Function(void Function()) setModalState, int r, int bpl) {
    final startIdx = r * bpl;
    final endIdx = math.min(startIdx + bpl, _decodedUartPackets.length);
    final rowPackets = _decodedUartPackets.sublist(startIdx, endIdx);
    final offsetStr = startIdx.toRadixString(16).padLeft(bpl <= 8 ? 4 : 6, '0').toUpperCase();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A. Offset cell
          SizedBox(
            width: bpl <= 8 ? 64 : 76,
            child: Text(
              '$offsetStr: ',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.0,
                color: Color(0xFF4FC3F7),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          // B. Hex bytes cells
          for (int b = 0; b < bpl; b++) ...[
            if (b < rowPackets.length) ...[
              () {
                final globalIdx = startIdx + b;
                final p = rowPackets[b];
                final isSel = _selectedHexByteIndex == globalIdx;

                Color byteColor;
                if (p.value == 0x0D) {
                  byteColor = const Color(0xFFFF80AB); // CR: Pink
                } else if (p.value == 0x0A) {
                  byteColor = const Color(0xFFEA80FC); // LF: Purple
                } else if (p.value == 0x00) {
                  byteColor = const Color(0xFFFFD54F); // NUL: Amber
                } else if (p.isControlChar) {
                  byteColor = const Color(0xFFFFAB40); // Control
                } else {
                  byteColor = const Color(0xFFECEFF1); // Standard ASCII data
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setModalState(() {
                      _selectedHexByteIndex = isSel ? null : globalIdx;
                    });
                  },
                  child: Container(
                    width: 24,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSel ? const Color(0xFF00E5FF).withValues(alpha: 0.35) : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: isSel ? const Color(0xFF00E5FF) : Colors.transparent,
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      p.value.toRadixString(16).padLeft(2, '0').toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.0,
                        fontWeight: (isSel || p.isControlChar) ? FontWeight.bold : FontWeight.normal,
                        color: isSel ? const Color(0xFF00E5FF) : byteColor,
                      ),
                    ),
                  ),
                );
              }(),
            ] else ...[
              const SizedBox(width: 24),
            ],

            // Spacing
            if (bpl == 16 && b == 7) const SizedBox(width: 8)
            else if (bpl == 8 && b == 3) const SizedBox(width: 8)
            else if (b < bpl - 1) const SizedBox(width: 4),
          ],

          // Gap between HEX and ASCII
          const SizedBox(width: 16),

          // C. ASCII / Decoded text cells
          for (int b = 0; b < rowPackets.length; b++) ...[
            () {
              final globalIdx = startIdx + b;
              final p = rowPackets[b];
              final isSel = _selectedHexByteIndex == globalIdx;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setModalState(() {
                    _selectedHexByteIndex = isSel ? null : globalIdx;
                  });
                },
                child: Container(
                  width: 11,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSel ? const Color(0xFF00E5FF).withValues(alpha: 0.35) : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(
                      color: isSel ? const Color(0xFF00E5FF) : Colors.transparent,
                      width: 1.0,
                    ),
                  ),
                  child: Text(
                    p.isControlChar ? '.' : String.fromCharCode(p.value),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.0,
                      fontWeight: (isSel || !p.isControlChar) ? FontWeight.bold : FontWeight.normal,
                      color: isSel
                          ? const Color(0xFF00E5FF)
                          : (p.isControlChar ? const Color(0xFF546E7A) : const Color(0xFF00E676)),
                    ),
                  ),
                ),
              );
            }(),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsTab(void Function(void Function()) setModalState, Color activeColor) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Channel selector
          const Text('Canal UART (Línea de Datos):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: List.generate(8, (i) {
              final isSel = _uartConfig.channel == i;
              final chCol = WaveformPainter.channelColors[i];
              return ChoiceChip(
                label: Text('D$i', style: TextStyle(color: isSel ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                selected: isSel,
                selectedColor: chCol,
                backgroundColor: const Color(0xFF262C38),
                side: BorderSide(color: isSel ? chCol : Colors.white24),
                onSelected: (sel) {
                  if (sel) {
                    setModalState(() => _uartConfig = _uartConfig.copyWith(channel: i));
                    setState(() {});
                  }
                },
              );
            }),
          ),
          const SizedBox(height: 12),

          // Baud Rate selector
          const Text('Velocidad en Baudios (Baud Rate):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [9600, 19200, 38400, 57600, 115200, 230400, 921600].map((b) {
              final isSel = _uartConfig.baudRate == b;
              return ChoiceChip(
                label: Text('$b', style: TextStyle(color: isSel ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                selected: isSel,
                selectedColor: const Color(0xFF00E5FF),
                backgroundColor: const Color(0xFF262C38),
                side: BorderSide(color: isSel ? const Color(0xFF00E5FF) : Colors.white24),
                onSelected: (sel) {
                  if (sel) {
                    setModalState(() => _uartConfig = _uartConfig.copyWith(baudRate: b));
                    setState(() {});
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Display Format in Waveform
          const Text('Etiquetas en Forma de Onda:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(
            children: [
              ChoiceChip(
                label: const Text('Ambos \'A\' (0x41)', style: TextStyle(fontSize: 11)),
                selected: _uartConfig.displayFormat == UartDisplayFormat.both,
                selectedColor: const Color(0xFF00E5FF),
                backgroundColor: const Color(0xFF262C38),
                onSelected: (sel) {
                  if (sel) {
                    setModalState(() => _uartConfig = _uartConfig.copyWith(displayFormat: UartDisplayFormat.both));
                    setState(() {});
                  }
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Solo ASCII', style: TextStyle(fontSize: 11)),
                selected: _uartConfig.displayFormat == UartDisplayFormat.ascii,
                selectedColor: const Color(0xFF00E5FF),
                backgroundColor: const Color(0xFF262C38),
                onSelected: (sel) {
                  if (sel) {
                    setModalState(() => _uartConfig = _uartConfig.copyWith(displayFormat: UartDisplayFormat.ascii));
                    setState(() {});
                  }
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Solo HEX', style: TextStyle(fontSize: 11)),
                selected: _uartConfig.displayFormat == UartDisplayFormat.hex,
                selectedColor: const Color(0xFF00E5FF),
                backgroundColor: const Color(0xFF262C38),
                onSelected: (sel) {
                  if (sel) {
                    setModalState(() => _uartConfig = _uartConfig.copyWith(displayFormat: UartDisplayFormat.hex));
                    setState(() {});
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSlopeChip(void Function(void Function()) setModalState, TriggerSlope slope, String label, Color color) {
    final isSelected = _triggerConfig.slope == slope;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
      ),
      selected: isSelected,
      selectedColor: color,
      backgroundColor: const Color(0xFF262C38),
      side: BorderSide(color: isSelected ? color : Colors.white24),
      onSelected: _triggerConfig.enabled
          ? (sel) {
              if (sel) {
                setModalState(() {
                  _triggerConfig = _triggerConfig.copyWith(slope: slope);
                });
                setState(() {});
              }
            }
          : null,
    );
  }

  Widget _buildRatioChip(void Function(void Function()) setModalState, double ratio, String label) {
    final isSelected = (_triggerConfig.screenRatio - ratio).abs() < 0.02;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
      ),
      selected: isSelected,
      selectedColor: const Color(0xFF00E5FF),
      backgroundColor: const Color(0xFF262C38),
      side: BorderSide(color: isSelected ? const Color(0xFF00E5FF) : Colors.white24),
      onSelected: _triggerConfig.enabled
          ? (sel) {
              if (sel) {
                setModalState(() {
                  _triggerConfig = _triggerConfig.copyWith(screenRatio: ratio);
                });
                setState(() {});
              }
            }
          : null,
    );
  }

  // ==========================================
  // I2C MODAL & TABS
  // ==========================================
  void _showI2cDecoderModal() {
    int selectedTab = 0; // 0 = Transacciones, 1 = Ajustes

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1E27),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.70,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title Bar
                  Row(
                    children: [
                      const Icon(Icons.sync_alt, color: Color(0xFFFFD600), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Decodificador I2C: SCL=D${_i2cConfig.sclChannel} / SDA=D${_i2cConfig.sdaChannel}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Switch(
                        value: _i2cConfig.enabled,
                        activeThumbColor: const Color(0xFFFFD600),
                        onChanged: (val) {
                          setModalState(() {
                            _i2cConfig = _i2cConfig.copyWith(enabled: val);
                          });
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Tabs
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 0 ? const Color(0xFFFFD600) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 0 ? Colors.black : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.list_alt, size: 16),
                          label: Text('Transacciones (${_decodedI2cPackets.length})'),
                          onPressed: () => setModalState(() => selectedTab = 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 1 ? const Color(0xFFFFD600) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 1 ? Colors.black : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.settings, size: 16),
                          label: const Text('Ajustes I2C'),
                          onPressed: () => setModalState(() => selectedTab = 1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Content
                  Expanded(
                    child: selectedTab == 0
                        ? _buildI2cTransactionsTab()
                        : _buildI2cSettingsTab(setModalState),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildI2cTransactionsTab() {
    if (_decodedI2cPackets.isEmpty) {
      return const Center(
        child: Text(
          '(Esperando tramas I2C...)',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
        ),
      );
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Paquetes detectados: ${_decodedI2cPackets.length}',
              style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 14, color: Color(0xFFFFD600)),
              label: const Text('Copiar Log', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11)),
              onPressed: () {
                final log = _decodedI2cPackets.map((p) => p.bubbleLabel).join(' ');
                Clipboard.setData(ClipboardData(text: log));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Log I2C copiado al portapapeles'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0E14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: ListView.separated(
              itemCount: _decodedI2cPackets.length,
              separatorBuilder: (ctx, i) => const Divider(color: Colors.white10, height: 1),
              itemBuilder: (ctx, i) {
                final p = _decodedI2cPackets[i];
                Color badgeCol;
                String typeStr;

                switch (p.type) {
                  case I2cPacketType.start:
                    badgeCol = const Color(0xFF00E676);
                    typeStr = 'START';
                    break;
                  case I2cPacketType.repeatedStart:
                    badgeCol = const Color(0xFF00E676);
                    typeStr = 'REPEATED START';
                    break;
                  case I2cPacketType.address:
                    badgeCol = const Color(0xFFFFD600);
                    typeStr = 'ADDR: ${p.hexString} (${p.isRead ? "READ" : "WRITE"})';
                    break;
                  case I2cPacketType.data:
                    badgeCol = const Color(0xFF00E5FF);
                    typeStr = 'DATA: ${p.hexString}';
                    break;
                  case I2cPacketType.stop:
                    badgeCol = Colors.redAccent;
                    typeStr = 'STOP';
                    break;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeCol.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: badgeCol, width: 0.8),
                        ),
                        child: Text(
                          p.shortLabel,
                          style: TextStyle(color: badgeCol, fontWeight: FontWeight.bold, fontSize: 10, fontFamily: 'monospace'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          typeStr,
                          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontFamily: 'monospace'),
                        ),
                      ),
                      if (p.type == I2cPacketType.address || p.type == I2cPacketType.data)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: p.ack ? const Color(0xFF00E676).withValues(alpha: 0.2) : Colors.redAccent.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            p.ack ? 'ACK' : 'NACK',
                            style: TextStyle(
                              color: p.ack ? const Color(0xFF00E676) : Colors.redAccent,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildI2cSettingsTab(void Function(void Function()) setModalState) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SCL Channel
          const Text('Línea de Reloj SCL:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _i2cConfig.sclChannel, (ch) => _i2cConfig = _i2cConfig.copyWith(sclChannel: ch)),
          const SizedBox(height: 14),

          // SDA Channel
          const Text('Línea de Datos SDA:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _i2cConfig.sdaChannel, (ch) => _i2cConfig = _i2cConfig.copyWith(sdaChannel: ch)),
        ],
      ),
    );
  }

  // ==========================================
  // SPI MODAL & TABS
  // ==========================================
  void _showSpiDecoderModal() {
    int selectedTab = 0; // 0 = Paquetes, 1 = Ajustes

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1E27),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.70,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title Bar
                  Row(
                    children: [
                      const Icon(Icons.flash_on, color: Color(0xFFE040FB), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Decodificador SPI (Full-Duplex): Modo ${_spiConfig.mode}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Switch(
                        value: _spiConfig.enabled,
                        activeThumbColor: const Color(0xFFE040FB),
                        onChanged: (val) {
                          setModalState(() {
                            _spiConfig = _spiConfig.copyWith(enabled: val);
                          });
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Tabs
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 0 ? const Color(0xFFE040FB) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 0 ? Colors.white : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.swap_horiz, size: 16),
                          label: Text('Paquetes (${_decodedSpiPackets.length})'),
                          onPressed: () => setModalState(() => selectedTab = 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedTab == 1 ? const Color(0xFFE040FB) : const Color(0xFF262C38),
                            foregroundColor: selectedTab == 1 ? Colors.white : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.settings, size: 16),
                          label: const Text('Ajustes SPI'),
                          onPressed: () => setModalState(() => selectedTab = 1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Content
                  Expanded(
                    child: selectedTab == 0
                        ? _buildSpiTransactionsTab()
                        : _buildSpiSettingsTab(setModalState),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSpiTransactionsTab() {
    if (_decodedSpiPackets.isEmpty) {
      return const Center(
        child: Text(
          '(Esperando tramas SPI...)',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
        ),
      );
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Bytes: ${_decodedSpiPackets.length}  |  Modo: ${_spiConfig.mode}',
              style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 14, color: Color(0xFFE040FB)),
              label: const Text('Copiar', style: TextStyle(color: Color(0xFFE040FB), fontSize: 11)),
              onPressed: () {
                final sb = StringBuffer();
                for (final p in _decodedSpiPackets) {
                  sb.writeln('Frame ${p.csFrame}: MOSI=${p.mosiHex} (\'${p.mosiChar}\') | MISO=${p.misoHex} (\'${p.misoChar}\')');
                }
                Clipboard.setData(ClipboardData(text: sb.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Log SPI copiado al portapapeles'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0E14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: ListView.separated(
              itemCount: _decodedSpiPackets.length,
              separatorBuilder: (ctx, i) => const Divider(color: Colors.white10, height: 1),
              itemBuilder: (ctx, i) {
                final p = _decodedSpiPackets[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        '#${p.csFrame}',
                        style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'),
                      ),
                      const SizedBox(width: 10),
                      // MOSI (TX)
                      Expanded(
                        child: Row(
                          children: [
                            const Text('TX: ', style: TextStyle(color: Color(0xFFE040FB), fontSize: 10, fontWeight: FontWeight.bold)),
                            Text(
                              '${p.mosiHex} \'${p.mosiChar}\'',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ),
                      // MISO (RX)
                      Expanded(
                        child: Row(
                          children: [
                            const Text('RX: ', style: TextStyle(color: Color(0xFF1DE9B6), fontSize: 10, fontWeight: FontWeight.bold)),
                            Text(
                              '${p.misoHex} \'${p.misoChar}\'',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSpiSettingsTab(void Function(void Function()) setModalState) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SCLK
          const Text('Reloj SPI SCLK:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _spiConfig.sclkChannel, (ch) => _spiConfig = _spiConfig.copyWith(sclkChannel: ch)),
          const SizedBox(height: 12),

          // MOSI
          const Text('Línea MOSI (Host -> Device):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _spiConfig.mosiChannel, (ch) => _spiConfig = _spiConfig.copyWith(mosiChannel: ch)),
          const SizedBox(height: 12),

          // MISO
          const Text('Línea MISO (Device -> Host):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _spiConfig.misoChannel, (ch) => _spiConfig = _spiConfig.copyWith(misoChannel: ch)),
          const SizedBox(height: 12),

          // CS#
          const Text('Chip Select CS#:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _buildChannelChips(setModalState, _spiConfig.csChannel, (ch) => _spiConfig = _spiConfig.copyWith(csChannel: ch)),
          const SizedBox(height: 14),

          // Modes
          const Text('Modo SPI (CPOL, CPHA):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              _buildSpiModeChip(setModalState, 0, 0, 'Modo 0 (0,0)'),
              _buildSpiModeChip(setModalState, 0, 1, 'Modo 1 (0,1)'),
              _buildSpiModeChip(setModalState, 1, 0, 'Modo 2 (1,0)'),
              _buildSpiModeChip(setModalState, 1, 1, 'Modo 3 (1,1)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChannelChips(
    void Function(void Function()) setModalState,
    int selectedChannel,
    void Function(int) onSelected,
  ) {
    return Wrap(
      spacing: 8,
      children: List.generate(8, (i) {
        final isSel = selectedChannel == i;
        final chCol = WaveformPainter.channelColors[i];
        return ChoiceChip(
          label: Text('D$i', style: TextStyle(color: isSel ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
          selected: isSel,
          selectedColor: chCol,
          backgroundColor: const Color(0xFF262C38),
          side: BorderSide(color: isSel ? chCol : Colors.white24),
          onSelected: (sel) {
            if (sel) {
              setModalState(() => onSelected(i));
              setState(() {});
            }
          },
        );
      }),
    );
  }

  Widget _buildSpiModeChip(
    void Function(void Function()) setModalState,
    int cpol,
    int cpha,
    String label,
  ) {
    final isSel = _spiConfig.cpol == cpol && _spiConfig.cpha == cpha;
    return ChoiceChip(
      label: Text(label, style: TextStyle(color: isSel ? Colors.white : Colors.white70, fontWeight: FontWeight.bold, fontSize: 11)),
      selected: isSel,
      selectedColor: const Color(0xFFE040FB),
      backgroundColor: const Color(0xFF262C38),
      side: BorderSide(color: isSel ? const Color(0xFFE040FB) : Colors.white24),
      onSelected: (sel) {
        if (sel) {
          setModalState(() => _spiConfig = _spiConfig.copyWith(cpol: cpol, cpha: cpha));
          setState(() {});
        }
      },
    );
  }

  // ==========================================
  // PWM INSPECTOR MODAL & DASHBOARD
  // ==========================================
  void _showPwmInspectorModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1E27),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.65,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title Bar
                  Row(
                    children: [
                      const Icon(Icons.speed, color: Color(0xFFAEEA00), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Inspector PWM: Canal D${_pwmConfig.channel}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Switch(
                        value: _pwmConfig.enabled,
                        activeThumbColor: const Color(0xFFAEEA00),
                        onChanged: (val) {
                          setModalState(() {
                            _pwmConfig = _pwmConfig.copyWith(enabled: val);
                          });
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Channel Selector
                  const Text('Canal a Medir:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  _buildChannelChips(setModalState, _pwmConfig.channel, (ch) => _pwmConfig = _pwmConfig.copyWith(channel: ch)),
                  const SizedBox(height: 16),

                  // Dashboard Metrics
                  Expanded(
                    child: _buildPwmDashboard(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPwmDashboard() {
    if (!_pwmConfig.enabled || _pwmMeasurement.frequencyHz == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.speed, size: 40, color: Colors.white.withValues(alpha: 0.2)),
            const SizedBox(height: 8),
            const Text(
              '(Sin señal PWM activa o ciclo estático en el canal)',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildPwmCard(
                  title: 'FRECUENCIA',
                  value: _pwmMeasurement.frequencyFormatted,
                  subtitle: 'Promedio: ${_pwmMeasurement.avgFrequencyHz >= 1000 ? "${(_pwmMeasurement.avgFrequencyHz / 1000).toStringAsFixed(2)} kHz" : "${_pwmMeasurement.avgFrequencyHz.toStringAsFixed(1)} Hz"}',
                  color: const Color(0xFFAEEA00),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPwmCard(
                  title: 'DUTY CYCLE (CICLO)',
                  value: _pwmMeasurement.dutyFormatted,
                  subtitle: 'Min: ${_pwmMeasurement.minDutyPercent.toStringAsFixed(1)}% | Max: ${_pwmMeasurement.maxDutyPercent.toStringAsFixed(1)}%',
                  color: const Color(0xFF00E5FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildPwmCard(
                  title: 'PERÍODO (T)',
                  value: _pwmMeasurement.periodFormatted,
                  subtitle: 'Ciclos: ${_pwmMeasurement.pulseCount}',
                  color: const Color(0xFFFFD600),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPwmCard(
                  title: 'TIEMPO ALTO / BAJO',
                  value: '${_pwmMeasurement.highTimeFormatted} H',
                  subtitle: 'Bajo: ${_pwmMeasurement.lowTimeFormatted}',
                  color: const Color(0xFFE040FB),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPwmCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1218),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 10, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final waveWidth = constraints.maxWidth - WaveformPainter.labelWidth;
        final maxScrollY = _maxVerticalScroll(constraints.maxHeight);

        // 1. Decode UART Packets in background when enabled
        if (_uartConfig.enabled && widget.capture.totalSamples > 10) {
          _decodedUartPackets = UartDecoder.decode(
            widget.capture,
            _uartConfig,
            maxPackets: 2000,
          );
        } else {
          _decodedUartPackets = const [];
        }

        // 2. Decode I2C Packets in background when enabled
        if (_i2cConfig.enabled && widget.capture.totalSamples > 10) {
          _decodedI2cPackets = I2cDecoder.decode(
            widget.capture,
            _i2cConfig,
            maxPackets: 2000,
          );
        } else {
          _decodedI2cPackets = const [];
        }

        // 3. Decode SPI Packets in background when enabled
        if (_spiConfig.enabled && widget.capture.totalSamples > 10) {
          _decodedSpiPackets = SpiDecoder.decode(
            widget.capture,
            _spiConfig,
            maxPackets: 2000,
          );
        } else {
          _decodedSpiPackets = const [];
        }

        // 4. Analyze PWM when enabled
        if (_pwmConfig.enabled && widget.capture.totalSamples > 10) {
          _pwmMeasurement = PwmDecoder.analyze(
            widget.capture,
            _pwmConfig,
          );
        } else {
          _pwmMeasurement = const PwmMeasurement();
        }

        // Oscilloscope trigger synchronization & Viewport update during continuous live streaming
        if (widget.isContinuous && _autoScroll && waveWidth > 0) {
          final visibleSamples = waveWidth * _samplesPerPixel;

          if (_triggerConfig.enabled && _triggerConfig.slope != TriggerSlope.none) {
            final rightMargin = ((1.0 - _triggerConfig.screenRatio) * visibleSamples).toInt();
            final searchFrom = math.max(1, widget.capture.totalSamples - 1 - rightMargin);
            final lookback = math.min(widget.capture.totalSamples, math.max(40000, (visibleSamples * 3).toInt()));

            final trig = _triggerConfig.findTriggerSample(
              widget.capture,
              searchFromSample: searchFrom,
              lookback: lookback,
            );

            if (trig != null) {
              _lockedTriggerSample = trig.toDouble();
              final targetOffset = trig - (_triggerConfig.screenRatio * visibleSamples);
              _viewOffsetSamples = targetOffset.clamp(0.0, math.max(0.0, widget.capture.totalSamples - visibleSamples));
            } else {
              _lockedTriggerSample = null;
              _viewOffsetSamples = (widget.capture.totalSamples - visibleSamples).clamp(0.0, double.infinity);
            }
          } else {
            _lockedTriggerSample = null;
            _viewOffsetSamples = (widget.capture.totalSamples - visibleSamples).clamp(0.0, double.infinity);
          }
        }

        return Stack(
          children: [
            // Gesture detector for pinch zoom & pan (both horizontal and vertical)
            Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  setState(() {
                    if (pointerSignal.scrollDelta.dy != 0) {
                      _verticalScrollOffset = (_verticalScrollOffset + pointerSignal.scrollDelta.dy).clamp(0.0, maxScrollY);
                    }
                    if (pointerSignal.scrollDelta.dx != 0) {
                      final dxSamples = pointerSignal.scrollDelta.dx * _samplesPerPixel;
                      _viewOffsetSamples = (_viewOffsetSamples + dxSamples).clamp(0.0, widget.capture.totalSamples.toDouble());
                    }
                  });
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (details) {
                  _baseZoom = _samplesPerPixel;
                  final px = (details.localFocalPoint.dx - WaveformPainter.labelWidth).clamp(0.0, math.max(1.0, waveWidth));
                  _baseFocalSample = _viewOffsetSamples + px * _samplesPerPixel;
                },
                onScaleUpdate: (details) {
                  setState(() {
                    // Horizontal zoom around focal point
                    if (details.scale != 1.0) {
                      final newZoom = (_baseZoom / details.scale).clamp(0.005, 1000000.0);
                      _samplesPerPixel = newZoom;

                      final px = (details.localFocalPoint.dx - WaveformPainter.labelWidth).clamp(0.0, math.max(1.0, waveWidth));
                      final maxOffset = widget.capture.totalSamples.toDouble();
                      _viewOffsetSamples = (_baseFocalSample - px * newZoom).clamp(0.0, maxOffset);

                      if (widget.isContinuous) {
                        _autoScroll = false;
                      }
                    }

                    // Horizontal pan (time navigation)
                    if (details.focalPointDelta.dx != 0 && details.scale == 1.0) {
                      final dxSamples = -details.focalPointDelta.dx * _samplesPerPixel;
                      final maxOffset = widget.capture.totalSamples.toDouble();
                      _viewOffsetSamples = (_viewOffsetSamples + dxSamples).clamp(0.0, maxOffset);
                      if (details.focalPointDelta.dx.abs() > 1.5 && widget.isContinuous) {
                        _autoScroll = false;
                      }
                    }

                    // Vertical pan (channels navigation when rotated or small screen)
                    if (details.focalPointDelta.dy != 0) {
                      _verticalScrollOffset = (_verticalScrollOffset - details.focalPointDelta.dy).clamp(0.0, maxScrollY);
                    }
                  });
                },
                onTapUp: (details) {
                  // Tap to set cursor
                  final localX = details.localPosition.dx;
                  if (localX >= WaveformPainter.labelWidth) {
                    final px = localX - WaveformPainter.labelWidth;
                    final sampleAtTap = (_viewOffsetSamples + px * _samplesPerPixel).clamp(0.0, widget.capture.totalSamples.toDouble());

                    setState(() {
                      if (_activeCursorToPlace == 0) {
                        _cursorASample = sampleAtTap;
                        _activeCursorToPlace = 1;
                      } else {
                        _cursorBSample = sampleAtTap;
                        _activeCursorToPlace = 0;
                      }
                    });
                  }
                },
                child: CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: WaveformPainter(
                    capture: widget.capture,
                    viewOffsetSamples: _viewOffsetSamples,
                    samplesPerPixel: _samplesPerPixel,
                    verticalScrollOffset: _verticalScrollOffset,
                    cursorASample: _cursorASample,
                    cursorBSample: _cursorBSample,
                    triggerSample: _lockedTriggerSample,
                    triggerColor: WaveformPainter.channelColors[_triggerConfig.channel],
                    uartConfig: _uartConfig,
                    uartPackets: _decodedUartPackets,
                    i2cConfig: _i2cConfig,
                    i2cPackets: _decodedI2cPackets,
                    spiConfig: _spiConfig,
                    spiPackets: _decodedSpiPackets,
                    pwmConfig: _pwmConfig,
                    pwmMeasurement: _pwmMeasurement,
                  ),
                ),
              ),
            ),

            // Top-Left Badges Strip: Trigger Status + Protocol Badges
            Positioned(
              left: WaveformPainter.labelWidth + 6,
              right: 60,
              top: 5,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 1. Trigger Status Badge
                    GestureDetector(
                      onTap: _showTriggerSettingsModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E222D).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _isTriggerActive
                                ? (_lockedTriggerSample != null
                                    ? WaveformPainter.channelColors[_triggerConfig.channel]
                                    : Colors.amber)
                                : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isTriggerActive
                                  ? (_lockedTriggerSample != null ? Icons.lock : Icons.search)
                                  : Icons.lock_open,
                              size: 12,
                              color: _isTriggerActive
                                  ? (_lockedTriggerSample != null
                                      ? WaveformPainter.channelColors[_triggerConfig.channel]
                                      : Colors.amber)
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _triggerBadgeText,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: _isTriggerActive
                                    ? (_lockedTriggerSample != null
                                        ? WaveformPainter.channelColors[_triggerConfig.channel]
                                        : Colors.amber)
                                    : Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 2. UART Decoder Badge
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _showUartDecoderModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _uartConfig.enabled ? const Color(0xFF14243B).withValues(alpha: 0.90) : const Color(0xFF1E222D).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _uartConfig.enabled ? const Color(0xFF00E5FF) : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.terminal, size: 12, color: _uartConfig.enabled ? const Color(0xFF00E5FF) : Colors.white54),
                            const SizedBox(width: 4),
                            Text(
                              _uartConfig.enabled ? 'UART: D${_uartConfig.channel} (${_decodedUartPackets.length}B)' : 'UART (OFF)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: _uartConfig.enabled ? const Color(0xFF00E5FF) : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 3. I2C Decoder Badge
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _showI2cDecoderModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _i2cConfig.enabled ? const Color(0xFF2B2814).withValues(alpha: 0.90) : const Color(0xFF1E222D).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _i2cConfig.enabled ? const Color(0xFFFFD600) : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sync_alt, size: 12, color: _i2cConfig.enabled ? const Color(0xFFFFD600) : Colors.white54),
                            const SizedBox(width: 4),
                            Text(
                              _i2cConfig.enabled ? 'I2C: D${_i2cConfig.sclChannel}/${_i2cConfig.sdaChannel} (${_decodedI2cPackets.length}P)' : 'I2C (OFF)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: _i2cConfig.enabled ? const Color(0xFFFFD600) : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 4. SPI Decoder Badge
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _showSpiDecoderModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _spiConfig.enabled ? const Color(0xFF2C1635).withValues(alpha: 0.90) : const Color(0xFF1E222D).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _spiConfig.enabled ? const Color(0xFFE040FB) : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flash_on, size: 12, color: _spiConfig.enabled ? const Color(0xFFE040FB) : Colors.white54),
                            const SizedBox(width: 4),
                            Text(
                              _spiConfig.enabled ? 'SPI: Modo ${_spiConfig.mode} (${_decodedSpiPackets.length}B)' : 'SPI (OFF)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: _spiConfig.enabled ? const Color(0xFFE040FB) : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 5. PWM Inspector Badge
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _showPwmInspectorModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _pwmConfig.enabled ? const Color(0xFF162514).withValues(alpha: 0.90) : const Color(0xFF1E222D).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _pwmConfig.enabled ? const Color(0xFFAEEA00) : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.speed, size: 12, color: _pwmConfig.enabled ? const Color(0xFFAEEA00) : Colors.white54),
                            const SizedBox(width: 4),
                            Text(
                              _pwmConfig.enabled
                                  ? (_pwmMeasurement.frequencyHz > 0 ? 'PWM: D${_pwmConfig.channel} (${_pwmMeasurement.badgeLabel})' : 'PWM: D${_pwmConfig.channel}')
                                  : 'PWM (OFF)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: _pwmConfig.enabled ? const Color(0xFFAEEA00) : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Floating controls column
            Positioned(
              right: 12,
              top: 36,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'fitScreen',
                    tooltip: 'Ajustar a pantalla',
                    backgroundColor: const Color(0xFF262C38),
                    onPressed: _fitToScreen,
                    child: const Icon(Icons.fullscreen, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'triggerSettings',
                    tooltip: 'Ajustes de Trigger (Osciloscopio)',
                    backgroundColor: _isTriggerActive
                        ? WaveformPainter.channelColors[_triggerConfig.channel]
                        : const Color(0xFF262C38),
                    foregroundColor: _isTriggerActive ? Colors.black : Colors.white,
                    onPressed: _showTriggerSettingsModal,
                    child: const Icon(Icons.tune, size: 18),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'uartTerminal',
                    tooltip: 'Decoder UART / Terminal Serial',
                    backgroundColor: _uartConfig.enabled ? const Color(0xFF00E5FF) : const Color(0xFF262C38),
                    foregroundColor: _uartConfig.enabled ? Colors.black : Colors.white,
                    onPressed: _showUartDecoderModal,
                    child: const Icon(Icons.terminal, size: 18),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'i2cModal',
                    tooltip: 'Decoder I2C',
                    backgroundColor: _i2cConfig.enabled ? const Color(0xFFFFD600) : const Color(0xFF262C38),
                    foregroundColor: _i2cConfig.enabled ? Colors.black : Colors.white,
                    onPressed: _showI2cDecoderModal,
                    child: const Icon(Icons.sync_alt, size: 18),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'spiModal',
                    tooltip: 'Decoder SPI',
                    backgroundColor: _spiConfig.enabled ? const Color(0xFFE040FB) : const Color(0xFF262C38),
                    foregroundColor: _spiConfig.enabled ? Colors.white : Colors.white,
                    onPressed: _showSpiDecoderModal,
                    child: const Icon(Icons.flash_on, size: 18),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'pwmModal',
                    tooltip: 'Inspector PWM',
                    backgroundColor: _pwmConfig.enabled ? const Color(0xFFAEEA00) : const Color(0xFF262C38),
                    foregroundColor: _pwmConfig.enabled ? Colors.black : Colors.white,
                    onPressed: _showPwmInspectorModal,
                    child: const Icon(Icons.speed, size: 18),
                  ),
                  if (widget.isContinuous) ...[
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'autoScroll',
                      tooltip: _autoScroll ? 'Pausar auto-scroll' : 'Reanudar auto-scroll',
                      backgroundColor: _autoScroll ? const Color(0xFF00E676) : const Color(0xFF262C38),
                      foregroundColor: _autoScroll ? Colors.black : Colors.white,
                      onPressed: () {
                        setState(() {
                          _autoScroll = !_autoScroll;
                        });
                      },
                      child: Icon(_autoScroll ? Icons.fast_forward : Icons.pause),
                    ),
                  ],
                  if (maxScrollY > 0) ...[
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'resetVertical',
                      tooltip: 'Ir a Canales Superiores (D0)',
                      backgroundColor: const Color(0xFF262C38),
                      onPressed: () {
                        setState(() {
                          _verticalScrollOffset = 0.0;
                        });
                      },
                      child: const Icon(Icons.vertical_align_top, color: Colors.white70, size: 18),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'clearCursors',
                    tooltip: 'Limpiar Cursores',
                    backgroundColor: const Color(0xFF262C38),
                    onPressed: () {
                      setState(() {
                        _cursorASample = -1;
                        _cursorBSample = -1;
                        _activeCursorToPlace = 0;
                      });
                    },
                    child: const Icon(Icons.timeline, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

