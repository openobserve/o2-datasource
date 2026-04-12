package com.o2.scanner

import android.app.Application
import android.provider.Settings
import android.util.Log
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.longKey
import io.opentelemetry.api.common.AttributeKey.stringKey
import io.opentelemetry.api.common.Attributes
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes

/**
 * Application class for O2 Scanner with OpenTelemetry monitoring.
 *
 * Features:
 * - Auto-instrumentation for activities, crashes, ANRs
 * - Custom tracking for QR/barcode scanning operations
 * - Device identification for fleet monitoring
 */
class ScannerApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    private val deviceId: String by lazy {
        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
    }

    companion object {
        private const val TAG = "ScannerApplication"
    }

    override fun onCreate() {
        super.onCreate()

        // Initialize OpenTelemetry monitoring
        otelRum = initializeOpenTelemetry()
    }

    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        return try {
            OpenTelemetryRumInitializer.initialize(
                context = this,
                configuration = {
                    // Configure OpenObserve endpoint
                    httpExport {
                        baseUrl = "https://introspection.dev.zinclabs.dev/api/default"
                        baseHeaders = mapOf(
                            "Authorization" to "Basic aW50cm9zcGVjdGlvbnJvb3RAb3Blbm9ic2VydmUuYWk6MVpSZGoxRHdpRTVkN0tJVQ==",
                            "stream-name" to "o2scanner"
                        )
                    }
                }
            ).also {
                Log.i(TAG, "OpenTelemetry initialized - sending data to OpenObserve")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize OpenTelemetry", e)
            null
        }
    }

    /**
     * Track QR/Barcode scan events
     */
    fun trackScanEvent(
        scannedValue: String,
        barcodeFormat: String,
        scanDurationMs: Long,
        success: Boolean = true
    ) {
        val tracer = otelRum?.openTelemetry?.tracerProvider?.get("scanner")

        tracer?.spanBuilder("qr.scan")
            ?.setAttribute(stringKey("scan.format"), barcodeFormat)
            ?.setAttribute(stringKey("scan.value.length"), scannedValue.length.toString())
            ?.setAttribute(longKey("scan.duration_ms"), scanDurationMs)
            ?.setAttribute(stringKey("scan.status"), if (success) "success" else "failed")
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.startSpan()
            ?.end()

        Log.d(TAG, "Scan tracked: format=$barcodeFormat, duration=${scanDurationMs}ms")
    }

    /**
     * Track scan errors
     */
    fun trackScanError(errorType: String, errorMessage: String) {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("scanner-errors")

        logger?.logRecordBuilder()
            ?.setEventName("scan.error")
            ?.setAttribute(stringKey("error.type"), errorType)
            ?.setAttribute(stringKey("error.message"), errorMessage)
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.emit()

        Log.w(TAG, "Scan error: $errorType - $errorMessage")
    }

    /**
     * Track camera operations
     */
    fun trackCameraEvent(eventType: String, details: String = "") {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("camera")

        logger?.logRecordBuilder()
            ?.setEventName("camera.$eventType")
            ?.setAttribute(stringKey("event.details"), details)
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.emit()
    }
}
