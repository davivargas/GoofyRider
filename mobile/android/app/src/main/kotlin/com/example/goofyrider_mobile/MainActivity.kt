package com.example.goofyrider_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var locationBridge: AndroidFusedLocationBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationBridge = AndroidFusedLocationBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        val handled =
            locationBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true
        if (!handled) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val handled = locationBridge?.onActivityResult(requestCode, resultCode, data) == true
        if (!handled) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
