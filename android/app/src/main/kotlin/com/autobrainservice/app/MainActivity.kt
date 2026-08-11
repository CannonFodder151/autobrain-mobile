package com.autobrainservice.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * Phone-side car detection (AUT-367).
 *
 * Listens for Bluetooth ACL connect/disconnect broadcasts and forwards them to
 * Flutter over the [CarKitChannel.EVENT_CHANNEL] event channel. The trigger is
 * deliberately the head-unit/car-kit ACL link (deterministic, no Android Auto
 * approval needed) — the Dart side applies the GPS speed guard before starting
 * a trip. See lib/services/car/car_kit_trip_monitor.dart.
 */
class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null
    private val carKitReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> emit("connected")
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> emit("disconnected")
                BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED -> emit("disconnected")
            }
        }

        private fun emit(state: String) {
            eventSink?.success(state)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CarKitChannel.EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                registerCarKitReceiver()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                runCatching { unregisterReceiver(carKitReceiver) }
            }
        })
    }

    private fun registerCarKitReceiver() {
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED)
        }
        runCatching { registerReceiver(carKitReceiver, filter) }
    }
}

object CarKitChannel {
    const val EVENT_CHANNEL = "autobrain/car_kit_connection"
}
