import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'models/capture_data.dart';
import 'services/logic_engine.dart';
import 'services/sr_exporter.dart';
import 'ui/waveform_viewer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LogicAnalyzerApp());
}

class LogicAnalyzerApp extends StatelessWidget {
  const LogicAnalyzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseView Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF00E676),
          surface: Color(0xFF161A22),
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1117),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late final LogicEngine _engine;
  late final AnimationController _pulseController;

  final List<int> _sampleRates = [
    20000,     // 20 kHz
    100000,    // 100 kHz
    500000,    // 500 kHz
    1000000,   // 1 MHz
    2000000,   // 2 MHz
    4000000,   // 4 MHz
    8000000,   // 8 MHz
    12000000,  // 12 MHz
    16000000,  // 16 MHz
    24000000,  // 24 MHz
  ];

  final List<int> _sampleLimits = [
    10000,
    50000,
    100000,
    500000,
    1000000,
    2000000,
    5000000,
  ];

  @override
  void initState() {
    super.initState();
    _engine = LogicEngine();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    // Initial scan after frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _engine.scanDevices();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _engine.dispose();
    super.dispose();
  }

  String _formatSampleRate(int hz) {
    if (hz >= 1000000) return '${hz ~/ 1000000} MHz';
    if (hz >= 1000) return '${hz ~/ 1000} kHz';
    return '$hz Hz';
  }

  String _formatSampleCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)} M';
    if (count >= 1000) return '${count ~/ 1000} k';
    return '$count';
  }

  void _generateStaticDemoSignal() {
    // Generate a simulated SPI / I2C / PWM test pattern
    const int sampleCount = 100000;
    const int rate = 1000000;
    final samples = Uint8List(sampleCount);

    for (int i = 0; i < sampleCount; i++) {
      int byte = 0;
      // D0: Clock 100 kHz (period = 10 samples)
      if ((i % 10) < 5) byte |= (1 << 0);
      // D1: Data (changes every 20 samples)
      if (((i ~/ 20) % 2) == 1) byte |= (1 << 1);
      // D2: Chip Select / Enable (active low every 200 samples)
      if ((i % 400) > 100) byte |= (1 << 2);
      // D3: PWM 50 kHz with varying duty cycle
      final pwmPeriod = 20;
      final duty = ((i / sampleCount) * pwmPeriod).toInt();
      if ((i % pwmPeriod) < duty) byte |= (1 << 3);
      // D4: Slow counter
      if (((i ~/ 100) % 2) == 1) byte |= (1 << 4);
      // D5: Glitches / Burst
      if ((i % 1500) < 60 && (i % 6) < 3) byte |= (1 << 5);

      samples[i] = byte;
    }

    _engine.loadDemoCapture(CaptureData(
      rawSamples: samples,
      sampleRate: rate,
    ));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Señal estática generada (100k muestras SPI / PWM / Clock)'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _exportCapture() async {
    final capture = _engine.currentCapture;
    if (capture == null || capture.totalSamples == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay muestras capturadas para exportar')),
      );
      return;
    }

    try {
      final file = await SrExporter.exportToSigrokFile(capture);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Captura Logic Analyzer (${capture.totalSamples} muestras @ ${_formatSampleRate(capture.sampleRate)})',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al exportar: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return AnimatedBuilder(
      animation: _engine,
      builder: (context, _) {
        final capture = _engine.currentCapture;
        final isCapturing = _engine.state == DeviceState.capturing;
        final hasDevice = _engine.selectedDevice != null;
        final isContinuous = _engine.isContinuousDemo;

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: isLandscape ? 44 : 56,
            backgroundColor: const Color(0xFF161A22),
            elevation: 2,
            title: Row(
              children: [
                const Icon(Icons.show_chart, color: Color(0xFF00E5FF), size: 22),
                const SizedBox(width: 8),
                Text(
                  'PulseView Mobile',
                  style: TextStyle(
                    fontSize: isLandscape ? 16 : 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            actions: [
              // Export button
              IconButton(
                tooltip: 'Exportar captura a .sr (PulseView)',
                icon: const Icon(Icons.share, color: Colors.white70, size: 20),
                onPressed: capture != null ? _exportCapture : null,
              ),

              // Continuous & Static Demo Menu
              PopupMenuButton<String>(
                tooltip: 'Demos de Señales (Continuas / Estáticas)',
                icon: isContinuous
                    ? const Icon(Icons.sensors, color: Color(0xFF00E5FF), size: 22)
                    : const Icon(Icons.auto_awesome, color: Color(0xFFFFD600), size: 22),
                color: const Color(0xFF1E222D),
                onSelected: (value) {
                  switch (value) {
                    case 'mixed':
                    case 'uart':
                    case 'i2c':
                    case 'motor':
                      _engine.startContinuousDemo(scenario: value);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Demo continuo iniciado: ${value.toUpperCase()} (Desplaza verticalmente para ver canales D0-D7)'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                      break;
                    case 'stop':
                      _engine.stopContinuousDemo();
                      break;
                    case 'static':
                      _generateStaticDemoSignal();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem<String>(
                    enabled: false,
                    child: Text(
                      'SEÑALES CONTINUAS (EN VIVO)',
                      style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  _buildDemoMenuItem('mixed', Icons.hub, 'Tráfico Mixto (SPI/I2C/UART/PWM)', isContinuous && _engine.currentScenario == 'mixed'),
                  _buildDemoMenuItem('uart', Icons.chat_bubble_outline, 'UART 115200 (TX/RX + RTS/CTS)', isContinuous && _engine.currentScenario == 'uart'),
                  _buildDemoMenuItem('i2c', Icons.memory, 'Sensor I2C con INT#', isContinuous && _engine.currentScenario == 'i2c'),
                  _buildDemoMenuItem('motor', Icons.rotate_right, 'Motor PWM 20kHz & Encoder', isContinuous && _engine.currentScenario == 'motor'),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    enabled: false,
                    child: Text(
                      'SEÑAL ESTÁTICA',
                      style: TextStyle(color: Color(0xFFFFD600), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'static',
                    child: Row(
                      children: [
                        Icon(Icons.bar_chart, color: Colors.white70, size: 18),
                        SizedBox(width: 8),
                        Text('Captura Estática (100k)', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  if (isContinuous) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(
                      value: 'stop',
                      child: Row(
                        children: [
                          Icon(Icons.stop_circle, color: Colors.redAccent, size: 18),
                          SizedBox(width: 8),
                          Text('Detener Demo Continuo', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),

              // USB Scan button
              IconButton(
                tooltip: 'Escanear USB OTG',
                icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
                onPressed: _engine.scanDevices,
              ),
            ],
          ),
          body: Column(
            children: [
              // 1. Hardware Status Bar
              _buildStatusBar(isLandscape),

              // 2. Waveform View Area
              Expanded(
                child: capture != null && capture.totalSamples > 0
                    ? WaveformViewer(
                        capture: capture,
                        isContinuous: isContinuous,
                      )
                    : _buildEmptyState(),
              ),

              // 3. Control Panel (Bottom)
              _buildControlPanel(isCapturing, hasDevice, isContinuous, isLandscape),
            ],
          ),
        );
      },
    );
  }

  PopupMenuItem<String> _buildDemoMenuItem(String value, IconData icon, String label, bool isSelected) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: isSelected ? const Color(0xFF00E5FF) : Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
          ),
          if (isSelected)
            const Icon(Icons.check, color: Color(0xFF00E5FF), size: 16),
        ],
      ),
    );
  }

  Widget _buildStatusBar(bool isLandscape) {
    final dev = _engine.selectedDevice;
    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (_engine.isContinuousDemo) {
      statusColor = const Color(0xFF00E5FF);
      statusText = 'DEMO EN VIVO: ${_engine.currentScenario.toUpperCase()} (Desplaza canales arriba/abajo)';
      statusIcon = Icons.sensors;
    } else {
      switch (_engine.state) {
        case DeviceState.disconnected:
          statusColor = Colors.orange;
          statusText = 'Desconectado';
          statusIcon = Icons.usb_off;
          break;
        case DeviceState.permissionRequired:
          statusColor = Colors.amber;
          statusText = 'Permiso OTG requerido';
          statusIcon = Icons.lock;
          break;
        case DeviceState.uploadingFirmware:
          statusColor = Colors.cyan;
          statusText = 'Cargando firmware fx2lafw...';
          statusIcon = Icons.cloud_upload;
          break;
        case DeviceState.ready:
          statusColor = const Color(0xFF00E676);
          statusText = dev != null ? '${dev.productName} (${dev.hexVid}:${dev.hexPid})' : 'Listo';
          statusIcon = Icons.check_circle;
          break;
        case DeviceState.capturing:
          statusColor = Colors.redAccent;
          statusText = 'Capturando a ${_formatSampleRate(_engine.sampleRate)}...';
          statusIcon = Icons.fiber_manual_record;
          break;
        case DeviceState.error:
          statusColor = Colors.red;
          statusText = _engine.statusMessage;
          statusIcon = Icons.error;
          break;
      }
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: isLandscape ? 4 : 7),
      color: const Color(0xFF1E222D),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_engine.isContinuousDemo)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.stop, size: 14, color: Colors.redAccent),
              label: const Text('Detener Demo', style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              onPressed: _engine.stopContinuousDemo,
            )
          else if (_engine.state == DeviceState.permissionRequired)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
              ),
              onPressed: _engine.requestPermission,
              child: const Text('Permiso', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
            )
          else if (_engine.state == DeviceState.ready && dev != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.flash_on, size: 14, color: Color(0xFFFFD600)),
              label: const Text('Recargar FW', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11)),
              onPressed: _engine.uploadFirmware,
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 64, color: Colors.white.withValues(alpha: 0.15)),
            const SizedBox(height: 12),
            const Text(
              'No hay capturas activas',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _engine.selectedDevice != null
                  ? 'Presiona "INICIAR CAPTURA" para leer señales de D0 a D7'
                  : 'Conecta el analizador lógico al adaptador OTG o inicia un demo continuo',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.sensors, size: 18),
                  label: const Text('Demo Mixto', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () => _engine.startContinuousDemo(scenario: 'mixed'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: const Text('Demo Serial UART', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () => _engine.startContinuousDemo(scenario: 'uart'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline, color: Color(0xFFFFD600), size: 18),
                  label: const Text('Señal Estática', style: TextStyle(color: Color(0xFFFFD600))),
                  onPressed: _generateStaticDemoSignal,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlPanel(bool isCapturing, bool hasDevice, bool isContinuous, bool isLandscape) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: isLandscape ? 6 : 10),
      decoration: const BoxDecoration(
        color: Color(0xFF161A22),
        border: Border(top: BorderSide(color: Color(0xFF262C38))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Sample Rate Selector
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('TASA (Hz)', style: TextStyle(color: Colors.white38, fontSize: isLandscape ? 9 : 11, fontWeight: FontWeight.bold)),
                  SizedBox(height: isLandscape ? 2 : 4),
                  Container(
                    height: isLandscape ? 34 : 40,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF202531),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButton<int>(
                      value: _engine.sampleRate,
                      isExpanded: true,
                      underline: const SizedBox(),
                      dropdownColor: const Color(0xFF202531),
                      style: TextStyle(color: Colors.white, fontSize: isLandscape ? 12 : 13, fontWeight: FontWeight.w600),
                      items: _sampleRates.map((r) {
                        return DropdownMenuItem<int>(
                          value: r,
                          child: Text(_formatSampleRate(r)),
                        );
                      }).toList(),
                      onChanged: (isCapturing || isContinuous) ? null : (v) => v != null ? _engine.setSampleRate(v) : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Sample Limit Selector
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('MUESTRAS', style: TextStyle(color: Colors.white38, fontSize: isLandscape ? 9 : 11, fontWeight: FontWeight.bold)),
                  SizedBox(height: isLandscape ? 2 : 4),
                  Container(
                    height: isLandscape ? 34 : 40,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF202531),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButton<int>(
                      value: _engine.sampleLimit,
                      isExpanded: true,
                      underline: const SizedBox(),
                      dropdownColor: const Color(0xFF202531),
                      style: TextStyle(color: Colors.white, fontSize: isLandscape ? 12 : 13, fontWeight: FontWeight.w600),
                      items: _sampleLimits.map((l) {
                        return DropdownMenuItem<int>(
                          value: l,
                          child: Text(_formatSampleCount(l)),
                        );
                      }).toList(),
                      onChanged: (isCapturing || isContinuous) ? null : (v) => v != null ? _engine.setSampleLimit(v) : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),

            // Big Action Button: START / STOP (Supports Real Capture & Continuous Demo)
            SizedBox(
              height: isLandscape ? 38 : 46,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: (isCapturing || isContinuous)
                      ? Colors.redAccent
                      : (hasDevice ? const Color(0xFF00E676) : const Color(0xFF00E5FF)),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: EdgeInsets.symmetric(horizontal: isLandscape ? 12 : 18),
                ),
                icon: (isCapturing || isContinuous)
                    ? AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, _) => Icon(
                          Icons.stop,
                          color: Colors.black,
                          size: (isLandscape ? 16 : 20) + _pulseController.value * 3,
                        ),
                      )
                    : Icon(Icons.play_arrow, size: isLandscape ? 20 : 24),
                label: Text(
                  isContinuous
                      ? 'DETENER DEMO'
                      : (isCapturing ? 'DETENER' : 'CAPTURA'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: isLandscape ? 12 : 14,
                    letterSpacing: 0.5,
                  ),
                ),
                onPressed: () {
                  if (isContinuous) {
                    _engine.stopContinuousDemo();
                  } else if (isCapturing) {
                    _engine.stopCapture();
                  } else {
                    _engine.startCapture();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
