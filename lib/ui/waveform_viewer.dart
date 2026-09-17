import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/capture_data.dart';
import '../models/trigger_config.dart';
import '../models/uart_packet.dart';
import '../services/uart_decoder.dart';
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
                        ? _buildTerminalTab(fullText, decodedHex.toString(), errorCount, activeColor)
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

  Widget _buildTerminalTab(String asciiText, String hexText, int errors, Color channelColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Stats bar & Actions
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF131720),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Bytes: ${_decodedUartPackets.length}  |  Errores: $errors',
                style: TextStyle(
                  color: errors > 0 ? Colors.redAccent : Colors.white70,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.copy, size: 14, color: Color(0xFF00E5FF)),
              label: const Text('Copiar Texto', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: asciiText));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Texto serial copiado al portapapeles'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
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
              reverse: true, // auto scroll to latest
              child: SelectableText(
                asciiText.isNotEmpty ? asciiText : '(Esperando tramas UART...)',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: Color(0xFF00E676),
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ],
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final waveWidth = constraints.maxWidth - WaveformPainter.labelWidth;
        final maxScrollY = _maxVerticalScroll(constraints.maxHeight);

        // Decode UART Packets in background when enabled
        if (_uartConfig.enabled && widget.capture.totalSamples > 10) {
          _decodedUartPackets = UartDecoder.decode(
            widget.capture,
            _uartConfig,
            maxPackets: 2000,
          );
        } else {
          _decodedUartPackets = const [];
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
                  ),
                ),
              ),
            ),

            // Top-Left Badges: Trigger Status + UART Decoder Badge
            Positioned(
              left: WaveformPainter.labelWidth + 8,
              top: 5,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. Trigger Status Badge
                  GestureDetector(
                    onTap: _showTriggerSettingsModal,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isTriggerActive
                                ? (_lockedTriggerSample != null ? Icons.lock : Icons.search)
                                : Icons.lock_open,
                            size: 13,
                            color: _isTriggerActive
                                ? (_lockedTriggerSample != null
                                    ? WaveformPainter.channelColors[_triggerConfig.channel]
                                    : Colors.amber)
                                : Colors.white54,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _triggerBadgeText,
                            style: TextStyle(
                              fontSize: 11,
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
                  if (_uartConfig.enabled) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _showUartDecoderModal,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14243B).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.terminal, size: 13, color: Color(0xFF00E5FF)),
                            const SizedBox(width: 5),
                            Text(
                              'UART: D${_uartConfig.channel} (${_decodedUartPackets.length}B)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00E5FF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Floating controls (Fit screen, Trigger, UART Terminal, Live scroll, Reset vertical, Clear cursors)
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
