package com.example.grassroots_networking

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // DEBUG/TESTBED power probe: raw fuel-gauge readings for the
        // experiment recorder. Read-only; interpretation happens offline.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grassroots/power",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> {
                    val bm =
                        getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    val sticky = registerReceiver(
                        null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    result.success(mapOf(
                        // Android convention: positive = current INTO the
                        // battery (charging), negative = discharge. OEMs
                        // vary; recorded raw, interpreted offline.
                        "currentNowUa" to bm.getIntProperty(
                            BatteryManager.BATTERY_PROPERTY_CURRENT_NOW),
                        "chargeCounterUah" to bm.getIntProperty(
                            BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER),
                        "levelPct" to bm.getIntProperty(
                            BatteryManager.BATTERY_PROPERTY_CAPACITY),
                        "charging" to bm.isCharging,
                        "voltageMv" to (sticky?.getIntExtra(
                            BatteryManager.EXTRA_VOLTAGE, -1) ?: -1),
                        "tempDeciC" to (sticky?.getIntExtra(
                            BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1),
                    ))
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grassroots/foreground_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    TransportForegroundService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    TransportForegroundService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
