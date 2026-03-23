package com.example.goofyrider_mobile

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity

class AndroidFusedLocationBridge(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {

    private val context: Context = activity
    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)
    private var eventSink: EventChannel.EventSink? = null
    private var callback: LocationCallback? = null
    private var currentMode: TrackingMode = TrackingMode.INITIALIZING_FIX
    private var currentConfig: TrackingConfig = TrackingConfig.defaultsFor(TrackingMode.INITIALIZING_FIX)
    private var staleSampleNanos: Long = DEFAULT_STALE_SAMPLE_NANOS
    private var lastElapsedRealtimeNanos: Long? = null
    private val requestBackgroundPermissionLauncher: ActivityResultLauncher<String>
    private val appSettingsLauncher: ActivityResultLauncher<Intent>
    private var pendingBackgroundPermissionResult: MethodChannel.Result? = null

    init {
        EventChannel(messenger, EVENT_CHANNEL_NAME).setStreamHandler(this)
        MethodChannel(messenger, CONTROL_CHANNEL_NAME).setMethodCallHandler(this)
        requestBackgroundPermissionLauncher = activity.registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { granted ->
            val status = if (granted || hasBackgroundLocationPermission()) "granted" else "denied"
            completePendingBackgroundPermissionResult(
                mapOf(
                    "status" to status,
                    "openedSettings" to false,
                ),
            )
        }
        appSettingsLauncher = activity.registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) {
            val status = if (hasBackgroundLocationPermission()) "granted" else "needs_settings"
            completePendingBackgroundPermissionResult(
                mapOf(
                    "status" to status,
                    "openedSettings" to true,
                ),
            )
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startLocationUpdates()
    }

    override fun onCancel(arguments: Any?) {
        stopLocationUpdates()
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setTrackingMode" -> {
                val wireMode = call.argument<String>("mode")
                val parsedMode = TrackingMode.fromWire(wireMode)
                if (parsedMode == null) {
                    result.error("invalid_mode", "Unsupported tracking mode: $wireMode", null)
                    return
                }
                currentMode = parsedMode
                currentConfig = TrackingConfig.fromCall(
                    call = call,
                    fallback = TrackingConfig.defaultsFor(parsedMode),
                )
                staleSampleNanos = readStaleSampleNanos(call)
                if (eventSink != null) {
                    restartLocationUpdates()
                }
                result.success(null)
            }

            "checkLocationSettings" -> {
                if (!hasFineLocationPermission()) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "message" to "Precise location is required for recording. Turn on precise location access for GoofyRider.",
                        ),
                    )
                    return
                }
                if (!hasBackgroundLocationPermission()) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "message" to "Background location is required for recording. Set location access to Allow all the time.",
                        ),
                    )
                    return
                }
                val settingsRequest = LocationSettingsRequest.Builder()
                    .addLocationRequest(currentConfig.toLocationRequest())
                    .build()
                LocationServices.getSettingsClient(context)
                    .checkLocationSettings(settingsRequest)
                    .addOnSuccessListener {
                        result.success(mapOf("ok" to true))
                    }
                    .addOnFailureListener { error ->
                        val message = if (error is ResolvableApiException) {
                            "Your phone's location settings are not ready for recording. Turn on location services, then try again."
                        } else {
                            error.message ?: "Location settings are not ready for recording."
                        }
                        result.success(
                            mapOf(
                                "ok" to false,
                                "message" to message,
                            ),
                        )
                    }
            }

            "ensureBackgroundLocationPermission" -> {
                ensureBackgroundLocationPermission(result)
            }

            else -> result.notImplemented()
        }
    }

    private fun ensureBackgroundLocationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(
                mapOf(
                    "status" to "granted",
                    "openedSettings" to false,
                ),
            )
            return
        }
        if (!hasFineLocationPermission()) {
            result.success(
                mapOf(
                    "status" to "fine_permission_required",
                    "openedSettings" to false,
                ),
            )
            return
        }
        if (hasBackgroundLocationPermission()) {
            result.success(
                mapOf(
                    "status" to "granted",
                    "openedSettings" to false,
                ),
            )
            return
        }
        if (pendingBackgroundPermissionResult != null) {
            result.error(
                "request_in_progress",
                "A background location permission request is already in progress.",
                null,
            )
            return
        }

        pendingBackgroundPermissionResult = result
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            requestBackgroundPermissionLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            return
        }

        try {
            val appSettingsIntent = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            )
            appSettingsLauncher.launch(appSettingsIntent)
        } catch (_: ActivityNotFoundException) {
            completePendingBackgroundPermissionResult(
                mapOf(
                    "status" to "settings_unavailable",
                    "openedSettings" to false,
                ),
            )
        }
    }

    private fun completePendingBackgroundPermissionResult(payload: Map<String, Any>) {
        val pendingResult = pendingBackgroundPermissionResult
        pendingBackgroundPermissionResult = null
        pendingResult?.success(payload)
    }

    private fun restartLocationUpdates() {
        stopLocationUpdates()
        startLocationUpdates()
    }

    private fun startLocationUpdates() {
        if (!hasFineLocationPermission()) {
            eventSink?.error(
                "permission_denied",
                "Precise location permission is required for recording.",
                null,
            )
            return
        }
        if (!hasBackgroundLocationPermission()) {
            eventSink?.error(
                "permission_denied",
                "Background location permission is required for recording. Set location access to Allow all the time.",
                null,
            )
            return
        }
        TrackingForegroundService.start(context)

        val locationRequest = currentConfig.toLocationRequest()
        if (callback == null) {
            callback = object : LocationCallback() {
                override fun onLocationResult(locationResult: LocationResult) {
                    pushLocations(locationResult)
                }
            }
        }

        try {
            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                callback!!,
                Looper.getMainLooper(),
            )
        } catch (securityException: SecurityException) {
            eventSink?.error("security_exception", securityException.message, null)
        }
    }

    private fun stopLocationUpdates() {
        val currentCallback = callback
        if (currentCallback != null) {
            fusedLocationClient.removeLocationUpdates(currentCallback)
        }
        TrackingForegroundService.stop(context)
    }

    private fun pushLocations(locationResult: LocationResult) {
        val nowRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        val sortedLocations = locationResult.locations.sortedBy { location ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                location.elapsedRealtimeNanos
            } else {
                location.time
            }
        }

        val samples = mutableListOf<Map<String, Any?>>()
        for (location in sortedLocations) {
            val elapsedRealtimeNanos = readElapsedRealtimeNanos(location)
            if (elapsedRealtimeNanos != null) {
                val previous = lastElapsedRealtimeNanos
                if (previous != null && elapsedRealtimeNanos <= previous) {
                    continue
                }
                if (nowRealtimeNanos - elapsedRealtimeNanos > staleSampleNanos) {
                    continue
                }
                lastElapsedRealtimeNanos = elapsedRealtimeNanos
            }

            samples.add(location.toPayload())
        }

        if (samples.isNotEmpty()) {
            eventSink?.success(mapOf("samples" to samples))
        }
    }

    private fun readElapsedRealtimeNanos(location: Location): Long? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
            location.elapsedRealtimeNanos
        } else {
            null
        }
    }

    private fun hasFineLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasBackgroundLocationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun readStaleSampleNanos(call: MethodCall): Long {
        val rawSeconds = call.argument<Number>("staleSampleThresholdSeconds")?.toLong()
        val safeSeconds = (rawSeconds ?: DEFAULT_STALE_SAMPLE_SECONDS).coerceAtLeast(1L)
        return safeSeconds * 1_000_000_000L
    }

    private fun Location.toPayload(): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>(
            "timestampUtc" to time,
            "elapsedRealtimeNanos" to readElapsedRealtimeNanos(this),
            "latitude" to latitude,
            "longitude" to longitude,
            "horizontalAccuracyM" to if (hasAccuracy()) accuracy else null,
            "altitudeM" to if (hasAltitude()) altitude else null,
            "platformSpeedMps" to if (hasSpeed()) speed else null,
            "bearingDeg" to if (hasBearing()) bearing else null,
            "provider" to provider,
            "isMocked" to readMockedFlag(this),
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            payload["verticalAccuracyM"] =
                if (hasVerticalAccuracy()) verticalAccuracyMeters else null
            payload["speedAccuracyMps"] = if (hasSpeedAccuracy()) speedAccuracyMetersPerSecond else null
            payload["bearingAccuracyDeg"] = if (hasBearingAccuracy()) bearingAccuracyDegrees else null
        } else {
            payload["verticalAccuracyM"] = null
            payload["speedAccuracyMps"] = null
            payload["bearingAccuracyDeg"] = null
        }
        return payload
    }

    @Suppress("DEPRECATION")
    private fun readMockedFlag(location: Location): Boolean? {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> location.isMock
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2 -> location.isFromMockProvider
            else -> null
        }
    }

    private enum class TrackingMode(private val wire: String) {
        INITIALIZING_FIX("initializing_fix"),
        ACTIVE_DESCENT("active_descent"),
        LIFT_UPHILL("lift_uphill"),
        STOPPED_IDLE("stopped_idle"),
        LOW_CONFIDENCE_RECOVERY("low_confidence_recovery");

        companion object {
            fun fromWire(value: String?): TrackingMode? {
                return entries.firstOrNull { it.wire == value }
            }
        }
    }

    private data class TrackingConfig(
        val priority: Int,
        val intervalMs: Long,
        val minIntervalMs: Long,
        val maxDelayMs: Long,
        val minDistanceM: Float,
        val waitForAccurate: Boolean,
    ) {
        fun toLocationRequest(): LocationRequest {
            return LocationRequest.Builder(priority, intervalMs)
                .setMinUpdateIntervalMillis(minIntervalMs)
                .setMaxUpdateDelayMillis(maxDelayMs)
                .setMinUpdateDistanceMeters(minDistanceM)
                .setWaitForAccurateLocation(waitForAccurate)
                .build()
        }

        companion object {
            fun defaultsFor(mode: TrackingMode): TrackingConfig {
                return when (mode) {
                    TrackingMode.INITIALIZING_FIX -> TrackingConfig(
                        priority = Priority.PRIORITY_HIGH_ACCURACY,
                        intervalMs = 1_000,
                        minIntervalMs = 500,
                        maxDelayMs = 0,
                        minDistanceM = 0f,
                        waitForAccurate = true,
                    )

                    TrackingMode.ACTIVE_DESCENT -> TrackingConfig(
                        priority = Priority.PRIORITY_HIGH_ACCURACY,
                        intervalMs = 900,
                        minIntervalMs = 250,
                        maxDelayMs = 900,
                        minDistanceM = 1f,
                        waitForAccurate = false,
                    )

                    TrackingMode.LIFT_UPHILL -> TrackingConfig(
                        priority = Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                        intervalMs = 4_000,
                        minIntervalMs = 2_500,
                        maxDelayMs = 12_000,
                        minDistanceM = 6f,
                        waitForAccurate = false,
                    )

                    TrackingMode.STOPPED_IDLE -> TrackingConfig(
                        priority = Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                        intervalMs = 12_000,
                        minIntervalMs = 8_000,
                        maxDelayMs = 45_000,
                        minDistanceM = 10f,
                        waitForAccurate = false,
                    )

                    TrackingMode.LOW_CONFIDENCE_RECOVERY -> TrackingConfig(
                        priority = Priority.PRIORITY_HIGH_ACCURACY,
                        intervalMs = 1_000,
                        minIntervalMs = 500,
                        maxDelayMs = 0,
                        minDistanceM = 0f,
                        waitForAccurate = true,
                    )
                }
            }

            fun fromCall(call: MethodCall, fallback: TrackingConfig): TrackingConfig {
                val rawConfig = call.argument<Map<String, Any?>>("config") ?: return fallback

                val priorityWire = rawConfig["priority"] as? String
                val parsedPriority = when (priorityWire) {
                    "high_accuracy" -> Priority.PRIORITY_HIGH_ACCURACY
                    "balanced_power" -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
                    else -> fallback.priority
                }

                val parsedIntervalMs = numberToLong(rawConfig["intervalMs"]) ?: fallback.intervalMs
                val parsedMinIntervalMs =
                    numberToLong(rawConfig["minIntervalMs"]) ?: fallback.minIntervalMs
                val parsedMaxDelayMs = numberToLong(rawConfig["maxDelayMs"]) ?: fallback.maxDelayMs
                val parsedMinDistanceM =
                    numberToFloat(rawConfig["minDistanceM"]) ?: fallback.minDistanceM
                val parsedWaitForAccurate =
                    (rawConfig["waitForAccurate"] as? Boolean) ?: fallback.waitForAccurate

                return TrackingConfig(
                    priority = parsedPriority,
                    intervalMs = parsedIntervalMs.coerceAtLeast(200L),
                    minIntervalMs = parsedMinIntervalMs.coerceAtLeast(100L),
                    maxDelayMs = parsedMaxDelayMs.coerceAtLeast(0L),
                    minDistanceM = parsedMinDistanceM.coerceAtLeast(0f),
                    waitForAccurate = parsedWaitForAccurate,
                )
            }

            private fun numberToLong(value: Any?): Long? {
                return when (value) {
                    is Number -> value.toLong()
                    is String -> value.toLongOrNull()
                    else -> null
                }
            }

            private fun numberToFloat(value: Any?): Float? {
                return when (value) {
                    is Number -> value.toFloat()
                    is String -> value.toFloatOrNull()
                    else -> null
                }
            }
        }
    }

    companion object {
        private const val EVENT_CHANNEL_NAME = "goofyrider/location_events"
        private const val CONTROL_CHANNEL_NAME = "goofyrider/location_control"
        private const val DEFAULT_STALE_SAMPLE_SECONDS = 30L
        private const val DEFAULT_STALE_SAMPLE_NANOS = DEFAULT_STALE_SAMPLE_SECONDS * 1_000_000_000L
    }
}
