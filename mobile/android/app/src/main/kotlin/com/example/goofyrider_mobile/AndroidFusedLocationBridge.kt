package com.example.goofyrider_mobile

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
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
    private var currentMode: TrackingMode = TrackingMode.ACQUIRING
    private var currentConfig: TrackingConfig = TrackingConfig.defaultsFor(TrackingMode.ACQUIRING)
    private var watchdogThresholdNanos: Long =
        TrackingConfig.defaultsFor(TrackingMode.ACQUIRING)
            .watchdogThresholdMs * 1_000_000L
    private var maxAcceptedSampleAgeNanos: Long =
        computeMaxAcceptedSampleAgeNanos(
            watchdogThresholdNanos = watchdogThresholdNanos,
            maxDelayMs = currentConfig.maxDelayMs,
        )
    private var lastElapsedRealtimeNanos: Long? = null
    private var pendingBackgroundPermissionResult: MethodChannel.Result? = null
    private var isForegroundServiceRunning: Boolean = false
    private var activeRequestId: Long = 0L
    private var activeRequestStartedRealtimeNanos: Long? = null
    private var didLogFirstFixForActiveRequest: Boolean = false
    private val nativeWatchdogHandler = Handler(Looper.getMainLooper())
    private var nativeWatchdogRunnable: Runnable? = null

    init {
        EventChannel(messenger, EVENT_CHANNEL_NAME).setStreamHandler(this)
        MethodChannel(messenger, CONTROL_CHANNEL_NAME).setMethodCallHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startLocationUpdates()
    }

    override fun onCancel(arguments: Any?) {
        stopLocationUpdates(reason = "stream_cancel")
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
                watchdogThresholdNanos = readWatchdogThresholdNanos(call, currentConfig)
                maxAcceptedSampleAgeNanos = computeMaxAcceptedSampleAgeNanos(
                    watchdogThresholdNanos = watchdogThresholdNanos,
                    maxDelayMs = currentConfig.maxDelayMs,
                )
                Log.d(
                    TAG,
                    "setTrackingMode mode=${currentMode.name} active=${eventSink != null} watchdogMs=${watchdogThresholdNanos / 1_000_000L} acceptedAgeMs=${maxAcceptedSampleAgeNanos / 1_000_000L}",
                )
                if (eventSink != null) {
                    reconfigureLocationUpdates(reason = "mode_change")
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
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                REQUEST_CODE_BACKGROUND_LOCATION_PERMISSION,
            )
            return
        }

        try {
            val appSettingsIntent = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            )
            activity.startActivityForResult(appSettingsIntent, REQUEST_CODE_APP_SETTINGS)
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

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_BACKGROUND_LOCATION_PERMISSION) {
            return false
        }

        val granted =
            permissions.indices.any { index ->
                permissions[index] == Manifest.permission.ACCESS_BACKGROUND_LOCATION &&
                    grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            }
        val status = if (granted || hasBackgroundLocationPermission()) "granted" else "denied"
        completePendingBackgroundPermissionResult(
            mapOf(
                "status" to status,
                "openedSettings" to false,
            ),
        )
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_APP_SETTINGS) {
            return false
        }

        val status = if (hasBackgroundLocationPermission()) "granted" else "needs_settings"
        completePendingBackgroundPermissionResult(
            mapOf(
                "status" to status,
                "openedSettings" to true,
            ),
        )
        return true
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
        val locationRequest = currentConfig.toLocationRequest()
        val currentCallback =
            if (callback == null) {
                object : LocationCallback() {
                override fun onLocationResult(locationResult: LocationResult) {
                    pushLocations(locationResult)
                }
            }
            } else {
                callback!!
            }
        callback = currentCallback

        ensureForegroundServiceRunning(reason = "stream_start")
        beginLocationRequest(
            locationRequest = locationRequest,
            callback = currentCallback,
            reason = "stream_start",
        )
    }

    private fun reconfigureLocationUpdates(reason: String) {
        val existingCallback = callback ?: return
        Log.d(
            TAG,
            "reconfigureLocationUpdates reason=$reason mode=${currentMode.name} requestId=$activeRequestId",
        )
        // Install the new subscription before tearing down the old one, so
        // there is no zero-callback window during the swap. `beginLocationRequest`
        // issues a fresh `requestLocationUpdates`, then we remove the previous
        // callback on the same looper thread.
        val replacementCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                pushLocations(locationResult)
            }
        }
        callback = replacementCallback
        try {
            beginLocationRequest(
                locationRequest = currentConfig.toLocationRequest(),
                callback = replacementCallback,
                reason = reason,
            )
            fusedLocationClient.removeLocationUpdates(existingCallback)
        } catch (securityException: SecurityException) {
            eventSink?.error("security_exception", securityException.message, null)
        }
    }

    private fun beginLocationRequest(
        locationRequest: LocationRequest,
        callback: LocationCallback,
        reason: String,
    ) {
        activeRequestId += 1
        activeRequestStartedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        didLogFirstFixForActiveRequest = false
        Log.d(
            TAG,
            "requestLocationUpdates id=$activeRequestId reason=$reason mode=${currentMode.name} priority=${currentConfig.priority} intervalMs=${currentConfig.intervalMs} minIntervalMs=${currentConfig.minIntervalMs} maxDelayMs=${currentConfig.maxDelayMs} minDistanceM=${currentConfig.minDistanceM}",
        )

        fusedLocationClient.requestLocationUpdates(
            locationRequest,
            callback,
            Looper.getMainLooper(),
        )
        armNativeWatchdog()
    }

    private fun stopLocationUpdates(reason: String) {
        val currentCallback = callback
        if (currentCallback != null) {
            fusedLocationClient.removeLocationUpdates(currentCallback)
        }
        if (isForegroundServiceRunning) {
            Log.d(TAG, "stopLocationUpdates reason=$reason")
            TrackingForegroundService.stop(context)
            isForegroundServiceRunning = false
        }
        activeRequestStartedRealtimeNanos = null
        didLogFirstFixForActiveRequest = false
        cancelNativeWatchdog()
    }

    private fun nativeWatchdogThresholdMs(): Long {
        return maxOf(currentConfig.intervalMs * 2L, 4_000L)
    }

    private fun armNativeWatchdog() {
        cancelNativeWatchdog()
        val thresholdMs = nativeWatchdogThresholdMs()
        val runnable = Runnable { onNativeWatchdogExpired(thresholdMs) }
        nativeWatchdogRunnable = runnable
        nativeWatchdogHandler.postDelayed(runnable, thresholdMs)
    }

    private fun cancelNativeWatchdog() {
        val runnable = nativeWatchdogRunnable ?: return
        nativeWatchdogHandler.removeCallbacks(runnable)
        nativeWatchdogRunnable = null
    }

    private fun onNativeWatchdogExpired(thresholdMs: Long) {
        nativeWatchdogRunnable = null
        if (callback == null || eventSink == null) {
            return
        }
        Log.w(
            TAG,
            "nativeWatchdogStall thresholdMs=$thresholdMs mode=${currentMode.name} requestId=$activeRequestId",
        )
        eventSink?.success(
            mapOf(
                "diagnostic" to mapOf(
                    "kind" to "native_stall_restart",
                    "thresholdMs" to thresholdMs,
                    "mode" to currentMode.name.lowercase(),
                    "requestId" to activeRequestId,
                ),
            ),
        )
        reconfigureLocationUpdates(reason = "native_watchdog_stall")
    }

    private fun ensureForegroundServiceRunning(reason: String) {
        if (isForegroundServiceRunning) {
            return
        }
        TrackingForegroundService.start(context)
        isForegroundServiceRunning = true
        Log.d(TAG, "foregroundServiceStart reason=$reason")
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
        var droppedOutOfOrder = 0
        var droppedStale = 0
        var firstDroppedStaleAgeMs: Long? = null
        var firstDroppedProvider: String? = null
        for (location in sortedLocations) {
            val elapsedRealtimeNanos = readElapsedRealtimeNanos(location)
            if (elapsedRealtimeNanos != null) {
                val previous = lastElapsedRealtimeNanos
                if (previous != null && elapsedRealtimeNanos <= previous) {
                    droppedOutOfOrder += 1
                    continue
                }
                val ageNanos = nowRealtimeNanos - elapsedRealtimeNanos
                if (ageNanos > maxAcceptedSampleAgeNanos) {
                    droppedStale += 1
                    if (firstDroppedStaleAgeMs == null) {
                        firstDroppedStaleAgeMs = ageNanos / 1_000_000L
                        firstDroppedProvider = location.provider
                    }
                    continue
                }
                lastElapsedRealtimeNanos = elapsedRealtimeNanos
            }

            samples.add(location.toPayload())
            maybeLogFirstFix(location)
        }

        if (droppedOutOfOrder > 0 || droppedStale > 0) {
            Log.w(
                TAG,
                "pushLocations dropped=${droppedOutOfOrder + droppedStale}/${sortedLocations.size} stale=$droppedStale outOfOrder=$droppedOutOfOrder firstStaleAgeMs=${firstDroppedStaleAgeMs ?: -1L} acceptedAgeMs=${maxAcceptedSampleAgeNanos / 1_000_000L} mode=${currentMode.name} requestId=$activeRequestId provider=${firstDroppedProvider ?: "n/a"}",
            )
        }

        if (samples.isNotEmpty()) {
            eventSink?.success(mapOf("samples" to samples))
            armNativeWatchdog()
        }
    }

    private fun maybeLogFirstFix(location: Location) {
        if (didLogFirstFixForActiveRequest) {
            return
        }
        val requestStarted = activeRequestStartedRealtimeNanos ?: return
        val delayMs = ((SystemClock.elapsedRealtimeNanos() - requestStarted) / 1_000_000L)
            .coerceAtLeast(0L)
        Log.d(
            TAG,
            "firstFix id=$activeRequestId delayMs=$delayMs mode=${currentMode.name} provider=${location.provider ?: "unknown"}",
        )
        didLogFirstFixForActiveRequest = true
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

    private fun readWatchdogThresholdNanos(call: MethodCall, fallback: TrackingConfig): Long {
        val rawMs =
            call.argument<Map<String, Any?>>("config")
                ?.get("watchdogThresholdMs")
                ?.let { TrackingConfig.numberToLongForInternalUse(it) }

        val safeMs = (rawMs ?: fallback.watchdogThresholdMs)
            .coerceAtLeast(1_000L)
            .coerceAtMost(120_000L)

        return safeMs * 1_000_000L
    }

    private fun computeMaxAcceptedSampleAgeNanos(
        watchdogThresholdNanos: Long,
        maxDelayMs: Long,
    ): Long {
        val watchdogMs = (watchdogThresholdNanos / 1_000_000L).coerceAtLeast(1_000L)
        val batchGraceMs = maxDelayMs.coerceAtLeast(0L) * 3L
        val toleratedMs = maxOf(
            watchdogMs * 3L,
            watchdogMs + batchGraceMs,
        ).coerceAtMost(MAX_ACCEPTED_SAMPLE_AGE_MS)
        return toleratedMs * 1_000_000L
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
        ACQUIRING("acquiring"),
        ACTIVE("active");

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
        val watchdogThresholdMs: Long,
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
                    TrackingMode.ACQUIRING -> TrackingConfig(
                        priority = Priority.PRIORITY_HIGH_ACCURACY,
                        intervalMs = 1_000,
                        minIntervalMs = 500,
                        maxDelayMs = 0,
                        minDistanceM = 0f,
                        waitForAccurate = false,
                        watchdogThresholdMs = 8_000,
                    )

                    TrackingMode.ACTIVE -> TrackingConfig(
                        priority = Priority.PRIORITY_HIGH_ACCURACY,
                        intervalMs = 1_000,
                        minIntervalMs = 500,
                        maxDelayMs = 0,
                        minDistanceM = 0f,
                        waitForAccurate = false,
                        watchdogThresholdMs = 4_000,
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
                val parsedWatchdogThresholdMs =
                    numberToLong(rawConfig["watchdogThresholdMs"]) ?: fallback.watchdogThresholdMs

                return TrackingConfig(
                    priority = parsedPriority,
                    intervalMs = parsedIntervalMs.coerceAtLeast(200L),
                    minIntervalMs = parsedMinIntervalMs.coerceAtLeast(100L),
                    maxDelayMs = parsedMaxDelayMs.coerceAtLeast(0L),
                    minDistanceM = parsedMinDistanceM.coerceAtLeast(0f),
                    waitForAccurate = parsedWaitForAccurate,
                    watchdogThresholdMs = parsedWatchdogThresholdMs.coerceAtLeast(1_000L)
                )
            }

            private fun numberToLong(value: Any?): Long? {
                return when (value) {
                    is Number -> value.toLong()
                    is String -> value.toLongOrNull()
                    else -> null
                }
            }

            internal fun numberToLongForInternalUse(value: Any?): Long? {
                return numberToLong(value)
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
        private const val TAG = "AndroidFusedBridge"
        private const val EVENT_CHANNEL_NAME = "goofyrider/location_events"
        private const val CONTROL_CHANNEL_NAME = "goofyrider/location_control"
        private const val REQUEST_CODE_BACKGROUND_LOCATION_PERMISSION = 2001
        private const val REQUEST_CODE_APP_SETTINGS = 2002
        private const val MAX_ACCEPTED_SAMPLE_AGE_MS = 300_000L
    }
}
