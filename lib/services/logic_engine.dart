import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/capture_data.dart';
import 'signal_generator.dart';

enum DeviceState {
  disconnected,
  permissionRequired,
  uploadingFirmware,
  ready,
  capturing,
  error,
}

class UsbDeviceInfo {
  final String name;
  final int vendorId;
  final int productId;
  final String manufacturer;
  final String productName;
  final bool isSupported;
  final bool hasPermission;

  UsbDeviceInfo({
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.manufacturer,
    required this.productName,
    required this.isSupported,
    required this.hasPermission,
  });

  factory UsbDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    return UsbDeviceInfo(
      name: map['name']?.toString() ?? '',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      manufacturer: map['manufacturer']?.toString() ?? 'Unknown',
      productName: map['productName']?.toString() ?? 'USB Device',
      isSupported: map['isSupported'] == true,
      hasPermission: map['hasPermission'] == true,
    );
  }

  String get hexVid => '0x${vendorId.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  String get hexPid => '0x${productId.toRadixString(16).padLeft(4, '0').toUpperCase()}';
}

class LogicEngine extends ChangeNotifier {
  static const MethodChannel _controlChannel = MethodChannel('com.antigravity.logic_analyzer/control');
  static const EventChannel _dataChannel = EventChannel('com.antigravity.logic_analyzer/data');

  DeviceState _state = DeviceState.disconnected;
  DeviceState get state => _state;

  List<UsbDeviceInfo> _devices = [];
  List<UsbDeviceInfo> get devices => _devices;

  UsbDeviceInfo? _selectedDevice;
  UsbDeviceInfo? get selectedDevice => _selectedDevice;

  String _statusMessage = 'Scan for devices to start';
  String get statusMessage => _statusMessage;

  int _sampleRate = 1000000; // 1 MHz default
  int get sampleRate => _sampleRate;

  int _sampleLimit = 100000; // 100k samples default
  int get sampleLimit => _sampleLimit;

  final BytesBuilder _sampleBuffer = BytesBuilder(copy: false);
  CaptureData? _currentCapture;
  CaptureData? get currentCapture => _currentCapture;

  StreamSubscription? _dataSubscription;

  LogicEngine() {
    _initDataStream();
  }

  void _initDataStream() {
    _dataSubscription = _dataChannel.receiveBroadcastStream().listen(
      (data) {
        if (data is Uint8List) {
          _sampleBuffer.add(data);
          notifyListeners();
        } else if (data is List<int>) {
          _sampleBuffer.add(Uint8List.fromList(data));
          notifyListeners();
        } else if (data is Map) {
          if (data['status'] == 'stopped') {
            _finalizeCapture();
          }
        }
      },
      onError: (err) {
        _statusMessage = 'Stream error: $err';
        _state = DeviceState.error;
        notifyListeners();
      },
    );
  }

  void setSampleRate(int rate) {
    _sampleRate = rate;
    notifyListeners();
  }

  void setSampleLimit(int limit) {
    _sampleLimit = limit;
    notifyListeners();
  }

  Future<void> scanDevices() async {
    try {
      final List<dynamic>? rawList = await _controlChannel.invokeMethod('listDevices');
      if (rawList != null) {
        _devices = rawList.map((m) => UsbDeviceInfo.fromMap(m as Map)).toList();
        final supported = _devices.where((d) => d.isSupported).toList();
        if (supported.isNotEmpty) {
          _selectedDevice = supported.first;
          if (_selectedDevice!.hasPermission) {
            _state = DeviceState.ready;
            _statusMessage = 'Device ready: ${_selectedDevice!.productName}';
          } else {
            _state = DeviceState.permissionRequired;
            _statusMessage = 'Permission required for ${_selectedDevice!.productName}';
          }
        } else if (_devices.isNotEmpty) {
          _statusMessage = 'Connected USB device not recognized as FX2 Logic Analyzer';
          _state = DeviceState.disconnected;
        } else {
          _statusMessage = 'No USB devices found. Connect logic analyzer via OTG.';
          _state = DeviceState.disconnected;
        }
      }
    } catch (e) {
      _statusMessage = 'Error scanning devices: $e';
      _state = DeviceState.error;
    }
    notifyListeners();
  }

  Future<bool> requestPermission() async {
    if (_selectedDevice == null) return false;
    try {
      final bool? granted = await _controlChannel.invokeMethod('requestPermission', {
        'vid': _selectedDevice!.vendorId,
        'pid': _selectedDevice!.productId,
      });
      if (granted == true) {
        _state = DeviceState.ready;
        _statusMessage = 'Permission granted. Ready to capture!';
        await scanDevices();
        return true;
      } else {
        _statusMessage = 'Permission denied by user.';
        _state = DeviceState.permissionRequired;
      }
    } catch (e) {
      _statusMessage = 'Permission request failed: $e';
      _state = DeviceState.error;
    }
    notifyListeners();
    return false;
  }

  Future<bool> uploadFirmware() async {
    if (_selectedDevice == null) return false;
    _state = DeviceState.uploadingFirmware;
    _statusMessage = 'Uploading fx2lafw firmware to Cypress FX2...';
    notifyListeners();

    try {
      final ByteData fwData = await rootBundle.load('assets/firmware/fx2lafw-saleae-logic.fw');
      final Uint8List fwBytes = fwData.buffer.asUint8List();

      final bool? ok = await _controlChannel.invokeMethod('uploadFirmware', {
        'firmware': fwBytes,
      });

      if (ok == true) {
        _state = DeviceState.ready;
        _statusMessage = 'Firmware fx2lafw loaded successfully!';
        notifyListeners();
        return true;
      } else {
        _statusMessage = 'Failed to load firmware to device.';
        _state = DeviceState.error;
      }
    } catch (e) {
      _statusMessage = 'Error loading firmware: $e';
      _state = DeviceState.error;
    }
    notifyListeners();
    return false;
  }

  Future<void> startCapture() async {
    if (_selectedDevice == null) return;
    _sampleBuffer.clear();
    _currentCapture = null;
    _state = DeviceState.capturing;
    _statusMessage = 'Capturing digital signals at ${CaptureData.formatFrequency(_sampleRate.toDouble())}...';
    notifyListeners();

    try {
      // First ensure firmware is active or try checking firmware version
      final dynamic fwVer = await _controlChannel.invokeMethod('checkFirmware');
      if (fwVer == null) {
        // Need to upload firmware first!
        final fwOk = await uploadFirmware();
        if (!fwOk) return;
      }

      final bool? ok = await _controlChannel.invokeMethod('startAcquisition', {
        'samplerate': _sampleRate,
        'sampleWide': false, // 8-bit mode (Channels 0..7)
        'sampleLimit': _sampleLimit,
      });

      if (ok != true) {
        _statusMessage = 'Failed to start acquisition on hardware.';
        _state = DeviceState.error;
        notifyListeners();
      }
    } catch (e) {
      _statusMessage = 'Error starting capture: $e';
      _state = DeviceState.error;
      notifyListeners();
    }
  }

  Future<void> stopCapture() async {
    try {
      await _controlChannel.invokeMethod('stopAcquisition');
    } catch (e) {
      debugPrint('Error stopping: $e');
    }
    _finalizeCapture();
  }

  void _finalizeCapture() {
    final raw = _sampleBuffer.takeBytes();
    _currentCapture = CaptureData(
      rawSamples: raw,
      sampleRate: _sampleRate,
    );
    _state = DeviceState.ready;
    _statusMessage = 'Capture complete: ${raw.length} samples (${CaptureData.formatTime(_currentCapture!.totalDurationSeconds)})';
    notifyListeners();
  }

  bool _isContinuousDemo = false;
  bool get isContinuousDemo => _isContinuousDemo;

  String _currentScenario = 'mixed';
  String get currentScenario => _currentScenario;

  Timer? _demoTimer;
  int _demoOffset = 0;

  Uint8List? _continuousBuffer;
  static const int _continuousBufferSize = 100000;
  static const int _chunkLength = 2000;

  void startContinuousDemo({String scenario = 'mixed'}) {
    stopCapture();
    stopContinuousDemo();

    _isContinuousDemo = true;
    _currentScenario = scenario;
    _sampleRate = 1000000; // 1 MHz
    _demoOffset = _continuousBufferSize;
    _sampleBuffer.clear();

    // Prefill continuous buffer so screen is populated immediately
    _continuousBuffer = SignalGenerator.generateSlice(
      scenario: _currentScenario,
      sampleRate: _sampleRate,
      chunkLength: _continuousBufferSize,
      globalSampleOffset: 0,
    );

    final initialTimeOffset = (_demoOffset - _continuousBufferSize) / _sampleRate;
    _currentCapture = CaptureData(
      rawSamples: _continuousBuffer!,
      sampleRate: _sampleRate,
      timeOffsetSeconds: initialTimeOffset,
    );

    _statusMessage = 'Demo continuo activo: $scenario';
    notifyListeners();

    // Push 2000 samples every 40ms with smooth zero-allocation shift
    _demoTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (!_isContinuousDemo || _continuousBuffer == null) return;

      final chunk = SignalGenerator.generateSlice(
        scenario: _currentScenario,
        sampleRate: _sampleRate,
        chunkLength: _chunkLength,
        globalSampleOffset: _demoOffset,
      );
      _demoOffset += _chunkLength;

      // Shift without reallocating
      _continuousBuffer!.setRange(0, _continuousBufferSize - _chunkLength, _continuousBuffer!, _chunkLength);
      _continuousBuffer!.setRange(_continuousBufferSize - _chunkLength, _continuousBufferSize, chunk);

      final timeOffset = (_demoOffset - _continuousBufferSize) / _sampleRate;
      _currentCapture = CaptureData(
        rawSamples: _continuousBuffer!,
        sampleRate: _sampleRate,
        timeOffsetSeconds: timeOffset,
      );
      notifyListeners();
    });
  }

  void stopContinuousDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _isContinuousDemo = false;
    _continuousBuffer = null;
    _statusMessage = 'Demo continuo detenido';
    notifyListeners();
  }

  void loadDemoCapture(CaptureData capture) {
    stopContinuousDemo();
    _currentCapture = capture;
    _sampleRate = capture.sampleRate;
    _state = DeviceState.ready;
    _statusMessage = 'Demo capture loaded: ${capture.totalSamples} samples';
    notifyListeners();
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _dataSubscription?.cancel();
    super.dispose();
  }
}
