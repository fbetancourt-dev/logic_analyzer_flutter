package com.antigravity.logic_analyzer_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CONTROL_CHANNEL = "com.antigravity.logic_analyzer/control"
    private val DATA_CHANNEL = "com.antigravity.logic_analyzer/data"

    private lateinit var fx2UsbManager: Fx2UsbManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fx2UsbManager = Fx2UsbManager(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "listDevices" -> {
                    result.success(fx2UsbManager.listDevices())
                }
                "requestPermission" -> {
                    val vid = call.argument<Int>("vid") ?: 0
                    val pid = call.argument<Int>("pid") ?: 0
                    fx2UsbManager.requestPermission(vid, pid) { granted ->
                        result.success(granted)
                    }
                }
                "uploadFirmware" -> {
                    val fwBytes = call.argument<ByteArray>("firmware")
                    if (fwBytes != null) {
                        val success = fx2UsbManager.uploadFirmware(fwBytes)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGS", "Firmware bytes missing", null)
                    }
                }
                "checkFirmware" -> {
                    result.success(fx2UsbManager.checkFirmwareVersion())
                }
                "startAcquisition" -> {
                    val samplerate = (call.argument<Number>("samplerate") ?: 1000000).toLong()
                    val sampleWide = call.argument<Boolean>("sampleWide") ?: false
                    val sampleLimit = (call.argument<Number>("sampleLimit") ?: 0).toLong()
                    val success = fx2UsbManager.startAcquisition(samplerate, sampleWide, sampleLimit)
                    result.success(success)
                }
                "stopAcquisition" -> {
                    fx2UsbManager.stopAcquisition()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DATA_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    fx2UsbManager.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    fx2UsbManager.setEventSink(null)
                }
            }
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::fx2UsbManager.isInitialized) {
            fx2UsbManager.dispose()
        }
    }
}
