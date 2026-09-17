package com.antigravity.logic_analyzer_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

class Fx2UsbManager(private val context: Context) {
    companion object {
        private const val TAG = "Fx2UsbManager"
        private const val ACTION_USB_PERMISSION = "com.antigravity.logic_analyzer.USB_PERMISSION"

        // EZ-USB Vendor Commands
        private const val CMD_EZUSB_LOAD = 0xA0
        private const val REG_CPUCS = 0xE600

        // fx2lafw Commands
        private const val CMD_GET_FW_VERSION = 0xB0
        private const val CMD_START = 0xB1
        private const val CMD_GET_REVID_VERSION = 0xB2

        private const val CMD_START_FLAGS_SAMPLE_8BIT = 0x00
        private const val CMD_START_FLAGS_SAMPLE_16BIT = 0x20
        private const val CMD_START_FLAGS_CLK_30MHZ = 0x00
        private const val CMD_START_FLAGS_CLK_48MHZ = 0x40

        // Supported VIDs and PIDs
        val SUPPORTED_DEVICES = listOf(
            Pair(0x0925, 0x3881), // Saleae Logic clone / CWAV USBee AX
            Pair(0x04B4, 0x8613), // Cypress default FX2LP
            Pair(0x04B4, 0x2066), // CWAV USBee ZX
            Pair(0x04B4, 0x2067)  // CWAV USBee SX
        )
    }

    private val usbManager: UsbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var activeDevice: UsbDevice? = null
    private var activeConnection: UsbDeviceConnection? = null
    private var activeInterface: UsbInterface? = null
    private var bulkInEndpoint: UsbEndpoint? = null

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val isCapturing = AtomicBoolean(false)
    private var captureThread: Thread? = null

    private var permissionCallback: ((Boolean) -> Unit)? = null

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (ACTION_USB_PERMISSION == intent?.action) {
                synchronized(this) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    Log.i(TAG, "Permission response for device: $device, granted: $granted")
                    if (granted && device != null) {
                        activeDevice = device
                    }
                    permissionCallback?.invoke(granted)
                    permissionCallback = null
                }
            }
        }
    }

    init {
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(usbReceiver, filter)
        }
    }

    fun dispose() {
        try {
            context.unregisterReceiver(usbReceiver)
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering receiver", e)
        }
        stopAcquisition()
        closeDevice()
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        this.eventSink = sink
    }

    fun listDevices(): List<Map<String, Any>> {
        val deviceList = mutableListOf<Map<String, Any>>()
        val devices = usbManager.deviceList
        for ((_, device) in devices) {
            val isSupported = SUPPORTED_DEVICES.any { it.first == device.vendorId && it.second == device.productId }
            val map = mapOf(
                "name" to device.deviceName,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "manufacturer" to (device.manufacturerName ?: "Unknown"),
                "productName" to (device.productName ?: "USB Device"),
                "isSupported" to isSupported,
                "hasPermission" to usbManager.hasPermission(device)
            )
            deviceList.add(map)
        }
        return deviceList
    }

    fun requestPermission(vid: Int, pid: Int, callback: (Boolean) -> Unit) {
        val device = usbManager.deviceList.values.firstOrNull { it.vendorId == vid && it.productId == pid }
            ?: run {
                Log.e(TAG, "requestPermission: device not found for VID $vid PID $pid")
                callback(false)
                return
            }

        activeDevice = device
        if (usbManager.hasPermission(device)) {
            callback(true)
            return
        }

        permissionCallback = callback
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val permissionIntent = PendingIntent.getBroadcast(
            context, 0, Intent(ACTION_USB_PERMISSION), flags
        )
        usbManager.requestPermission(device, permissionIntent)
    }

    private fun openDevice(): Boolean {
        // ALWAYS refresh device from current deviceList to handle re-enumeration
        val currentDevice = usbManager.deviceList.values.firstOrNull { d ->
            SUPPORTED_DEVICES.any { it.first == d.vendorId && it.second == d.productId }
        } ?: run {
            Log.e(TAG, "No supported device found in usbManager.deviceList")
            return false
        }
        activeDevice = currentDevice

        if (!usbManager.hasPermission(currentDevice)) {
            Log.e(TAG, "No permission to open device: ${currentDevice.deviceName} (${currentDevice.vendorId}:${currentDevice.productId})")
            return false
        }

        if (activeConnection != null && activeInterface != null && bulkInEndpoint != null) {
            return true
        }

        val conn = usbManager.openDevice(currentDevice) ?: run {
            Log.e(TAG, "Failed to open UsbDeviceConnection for ${currentDevice.deviceName}")
            return false
        }

        if (currentDevice.interfaceCount == 0) {
            Log.e(TAG, "Device has no interfaces")
            conn.close()
            return false
        }

        val iface = currentDevice.getInterface(0)
        if (!conn.claimInterface(iface, true)) {
            Log.e(TAG, "Failed to claim interface 0")
            conn.close()
            return false
        }

        // Find bulk IN endpoint (Endpoint 2 IN: 0x82)
        var epIn: UsbEndpoint? = null
        for (i in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(i)
            if (ep.direction == UsbConstants.USB_DIR_IN && ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                epIn = ep
                break
            }
        }

        activeConnection = conn
        activeInterface = iface
        bulkInEndpoint = epIn
        Log.i(TAG, "Device opened successfully: ${currentDevice.deviceName}. Bulk IN endpoint: $bulkInEndpoint")
        return true
    }

    fun closeDevice() {
        try {
            activeInterface?.let { activeConnection?.releaseInterface(it) }
            activeConnection?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing device", e)
        }
        activeConnection = null
        activeInterface = null
        bulkInEndpoint = null
    }

    fun uploadFirmware(firmwareBytes: ByteArray): Boolean {
        val currentDev = usbManager.deviceList.values.firstOrNull { d ->
            SUPPORTED_DEVICES.any { it.first == d.vendorId && it.second == d.productId }
        }

        // If device already running fx2lafw, it's ready!
        if (currentDev != null && (currentDev.productName == "fx2lafw" || currentDev.manufacturerName == "sigrok")) {
            Log.i(TAG, "Device is already running fx2lafw firmware! Skipping upload.")
            return true
        }

        Log.i(TAG, "uploadFirmware starting, size: ${firmwareBytes.size} bytes")
        if (!openDevice()) {
            Log.e(TAG, "Failed to open device for firmware upload")
            return false
        }
        val conn = activeConnection ?: return false

        // 1. Reset 8051 CPU: write 1 to REG_CPUCS (0xE600)
        val resetOn = byteArrayOf(0x01)
        val r1 = conn.controlTransfer(0x40, CMD_EZUSB_LOAD, REG_CPUCS, 0, resetOn, 1, 1000)
        if (r1 < 0) {
            Log.e(TAG, "Failed to set CPU reset on: $r1")
            return false
        }

        // 2. Upload firmware chunks
        val chunkSize = 4096
        var offset = 0
        while (offset < firmwareBytes.size) {
            val len = minOf(chunkSize, firmwareBytes.size - offset)
            val chunk = firmwareBytes.copyOfRange(offset, offset + len)
            val res = conn.controlTransfer(0x40, CMD_EZUSB_LOAD, offset, 0, chunk, len, 1000)
            if (res < 0) {
                Log.e(TAG, "Failed to upload firmware chunk at offset $offset: $res")
                return false
            }
            offset += len
        }

        // 3. Release 8051 CPU from reset: write 0 to REG_CPUCS (0xE600)
        val resetOff = byteArrayOf(0x00)
        val r2 = conn.controlTransfer(0x40, CMD_EZUSB_LOAD, REG_CPUCS, 0, resetOff, 1, 1000)
        if (r2 < 0) {
            Log.e(TAG, "Failed to release CPU reset: $r2")
            return false
        }

        Log.i(TAG, "Firmware uploaded successfully! Waiting for FX2 reboot...")
        closeDevice()
        Thread.sleep(800)

        val newDevice = usbManager.deviceList.values.firstOrNull { d ->
            SUPPORTED_DEVICES.any { it.first == d.vendorId && it.second == d.productId }
        }
        activeDevice = newDevice
        return newDevice != null
    }

    fun checkFirmwareVersion(): Map<String, Any>? {
        val currentDev = usbManager.deviceList.values.firstOrNull { d ->
            SUPPORTED_DEVICES.any { it.first == d.vendorId && it.second == d.productId }
        } ?: return null

        if (currentDev.productName == "fx2lafw" || currentDev.manufacturerName == "sigrok") {
            Log.i(TAG, "Device descriptors identify fx2lafw running.")
            return mapOf("major" to 1, "minor" to 4)
        }

        if (!openDevice()) return null
        val conn = activeConnection ?: return null
        val buf = ByteArray(2)
        val ret = conn.controlTransfer(0xC0, CMD_GET_FW_VERSION, 0, 0, buf, buf.size, 1000)
        if (ret >= 2) {
            val major = buf[0].toInt() and 0xFF
            val minor = buf[1].toInt() and 0xFF
            Log.i(TAG, "fx2lafw firmware version: $major.$minor")
            return mapOf("major" to major, "minor" to minor)
        }
        Log.w(TAG, "Failed to read firmware version: ret=$ret")
        return null
    }

    fun startAcquisition(samplerate: Long, sampleWide: Boolean, sampleLimit: Long): Boolean {
        if (isCapturing.get()) {
            Log.w(TAG, "Already capturing")
            return true
        }

        if (!openDevice()) {
            Log.e(TAG, "Failed to open device for acquisition")
            return false
        }

        val conn = activeConnection ?: return false
        val epIn = bulkInEndpoint ?: run {
            Log.e(TAG, "No bulk IN endpoint available")
            return false
        }

        // Calculate samplerate delay and clock source
        val clk48 = (48000000L % samplerate) == 0L
        val clk30 = (30000000L % samplerate) == 0L
        val clockFreq = if (clk48) 48000000L else if (clk30) 30000000L else 48000000L
        val clkFlag = if (clk48) CMD_START_FLAGS_CLK_48MHZ else CMD_START_FLAGS_CLK_30MHZ

        val delay = ((clockFreq / samplerate) - 1).toInt().coerceIn(0, 1536)
        val wideFlag = if (sampleWide) CMD_START_FLAGS_SAMPLE_16BIT else CMD_START_FLAGS_SAMPLE_8BIT
        val flags = clkFlag or wideFlag

        val sampleDelayH = ((delay shr 8) and 0xFF).toByte()
        val sampleDelayL = (delay and 0xFF).toByte()

        // Verify firmware is responding with CMD_GET_FW_VERSION (0xB0)
        val fwVerBuf = ByteArray(2)
        val fwRet = conn.controlTransfer(0xC0, CMD_GET_FW_VERSION, 0, 0, fwVerBuf, fwVerBuf.size, 1000)
        Log.i(TAG, "CMD_GET_FW_VERSION control transfer ret=$fwRet, major=${fwVerBuf[0].toInt() and 0xFF}, minor=${fwVerBuf[1].toInt() and 0xFF}")

        isCapturing.set(true)
        captureThread = Thread({
            val bufferSize = 4096 // 4 KB (multiple of 512)
            val buffer = ByteArray(bufferSize)
            var totalSamplesCollected = 0L

            Log.i(TAG, "Acquisition thread started, listening on EP 0x82...")
            try {
                while (isCapturing.get() && !Thread.currentThread().isInterrupted) {
                    val bytesRead = conn.bulkTransfer(epIn, buffer, bufferSize, 200)
                    if (bytesRead > 0) {
                        val chunk = buffer.copyOf(bytesRead)
                        totalSamplesCollected += if (sampleWide) bytesRead / 2 else bytesRead

                        // Dispatch chunk to Flutter EventChannel
                        mainHandler.post {
                            eventSink?.success(chunk)
                        }

                        if (sampleLimit > 0 && totalSamplesCollected >= sampleLimit) {
                            Log.i(TAG, "Sample limit reached: $totalSamplesCollected samples")
                            break
                        }
                    } else if (bytesRead < 0) {
                        if (!isCapturing.get() || Thread.currentThread().isInterrupted) break
                        try {
                            Thread.sleep(20)
                        } catch (e: InterruptedException) {
                            break
                        }
                    }
                }
            } catch (e: InterruptedException) {
                Log.i(TAG, "Fx2CaptureThread interrupted cleanly.")
            } catch (e: Exception) {
                Log.e(TAG, "Exception in Fx2CaptureThread: $e")
            } finally {
                Log.i(TAG, "Acquisition thread finished. Total samples: $totalSamplesCollected")
                isCapturing.set(false)
                mainHandler.post {
                    eventSink?.success(mapOf("status" to "stopped", "totalSamples" to totalSamplesCollected))
                }
            }
        }, "Fx2CaptureThread").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }

        // Small delay to ensure thread is blocked on bulkTransfer
        try {
            Thread.sleep(20)
        } catch (e: InterruptedException) {
            // ignore
        }

        Log.i(TAG, "Sending CMD_START: samplerate=$samplerate, clock=$clockFreq, delay=$delay, flags=0x${flags.toString(16)}")
        val cmd = byteArrayOf(flags.toByte(), sampleDelayH, sampleDelayL)
        val res = conn.controlTransfer(0x40, CMD_START, 0, 0, cmd, cmd.size, 1000)
        if (res < 0) {
            Log.e(TAG, "CMD_START control transfer failed: $res")
            isCapturing.set(false)
            return false
        }
        Log.i(TAG, "CMD_START sent successfully, hardware sampling running!")
        return true
    }

    fun stopAcquisition() {
        if (isCapturing.compareAndSet(true, false)) {
            Log.i(TAG, "Stopping acquisition...")
            try {
                captureThread?.interrupt()
                captureThread?.join(300)
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping capture thread: $e")
            } finally {
                captureThread = null
            }
        }
    }
}
