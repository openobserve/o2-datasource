# OpenTelemetry SDK for Android - Complete Integration Guide

A comprehensive guide to integrate OpenTelemetry auto-instrumentation into any Android application, with real-world examples from the O2 Scanner app.

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Step-by-Step Integration](#step-by-step-integration)
4. [Auto-Instrumentation Features](#auto-instrumentation-features)
5. [Custom Instrumentation](#custom-instrumentation)
6. [Backend Configuration](#backend-configuration)
7. [Testing & Verification](#testing--verification)
8. [Production Deployment](#production-deployment)
9. [Troubleshooting](#troubleshooting)
10. [Best Practices](#best-practices)

---

## Overview

### What is OpenTelemetry for Android?

OpenTelemetry provides automatic monitoring and observability for Android applications through:
- **Auto-instrumentation**: Automatic tracking of activities, crashes, ANRs, performance
- **Custom instrumentation**: Track business-specific events and metrics
- **Zero-code monitoring**: 95% of telemetry captured automatically after SDK integration

### What Gets Tracked Automatically?

✅ Activity lifecycle (onCreate, onResume, onPause, etc.)
✅ App crashes with full stack traces
✅ ANRs (Application Not Responding)
✅ Slow UI renders and frame drops
✅ Network connectivity changes
✅ App startup time
✅ Screen transitions

### Architecture

```
┌─────────────────────────────────────┐
│      Your Android Application       │
│  ┌───────────────────────────────┐  │
│  │   OpenTelemetry Android SDK   │  │
│  │  (Auto-Instrumentation)       │  │
│  └───────────────┬───────────────┘  │
└──────────────────┼───────────────────┘
                   │ OTLP/HTTP
                   ▼
         ┌─────────────────────┐
         │  Telemetry Backend  │
         │ (OpenObserve, Jaeger,│
         │  Prometheus, etc.)   │
         └─────────────────────┘
```

---

## Prerequisites

### Required Tools

- **Android Studio** (Arctic Fox or newer)
- **Gradle** 7.0+
- **Kotlin** 1.8+ or **Java** 11+
- **Android API Level** 21+ (Android 5.0+)

### Target Application Requirements

Your existing Android app should have:
- Access to source code (cannot instrument without source)
- Gradle build system
- Internet permission for telemetry export

---

## Step-by-Step Integration

### Step 1: Add Dependencies

#### Option A: Using Gradle Version Catalog (Recommended)

**File:** `build.gradle.kts` (Project level)

```kotlin
// No changes needed - just note your Kotlin version
plugins {
    id("com.android.application") version "8.2.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.20" apply false
}
```

**File:** `app/build.gradle.kts`

```kotlin
dependencies {
    // OpenTelemetry Android SDK - Auto-Instrumentation
    implementation(platform("io.opentelemetry.android:opentelemetry-android-bom:1.2.0-alpha"))
    implementation("io.opentelemetry.android:android-agent")

    // If you need desugaring for older Android versions (API < 26)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // Your existing dependencies remain unchanged
    // ...
}

android {
    // Enable BuildConfig if not already enabled
    buildFeatures {
        viewBinding = true // or dataBinding
        buildConfig = true  // Required for BuildConfig.VERSION_NAME
    }

    compileOptions {
        // Enable desugaring if targeting API < 26
        isCoreLibraryDesugaringEnabled = true
    }
}

// Force consistent dependency versions to avoid conflicts
configurations.all {
    resolutionStrategy {
        force("org.jetbrains.kotlin:kotlin-stdlib:1.9.20")
        force("org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.9.20")
        force("org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.20")
    }
}
```

#### Option B: Direct Dependencies (Alternative)

```kotlin
dependencies {
    implementation("io.opentelemetry.android:android-agent:1.2.0-alpha")
}
```

**Reference:** O2 Scanner implementation at `o2Scanner/app/build.gradle.kts:71-72`

---

### Step 2: Add Required Permissions

**File:** `app/src/main/AndroidManifest.xml`

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- Required for sending telemetry data -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:name=".YourApplication"  <!-- IMPORTANT: Reference your Application class -->
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:theme="@style/Theme.YourApp">

        <!-- Your activities -->

    </application>
</manifest>
```

**Reference:** O2 Scanner implementation at `o2Scanner/app/src/main/AndroidManifest.xml:18-20,23`

---

### Step 3: Create or Modify Application Class

#### Option A: Create New Application Class

If your app doesn't have a custom `Application` class yet:

**File:** `app/src/main/java/com/yourapp/YourApplication.kt`

```kotlin
package com.yourapp

import android.app.Application
import android.provider.Settings
import android.util.Log
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer

class YourApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    private val deviceId: String by lazy {
        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
    }

    companion object {
        private const val TAG = "YourApplication"
    }

    override fun onCreate() {
        super.onCreate()

        // Initialize OpenTelemetry
        otelRum = initializeOpenTelemetry()
    }

    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        return try {
            OpenTelemetryRumInitializer.initialize(
                context = this,
                configuration = {
                    // Configure your telemetry backend endpoint
                    httpExport {
                        baseUrl = "https://your-telemetry-backend.com/api/default"
                        baseHeaders = mapOf(
                            "Authorization" to "Bearer YOUR_TOKEN",
                            "stream-name" to "your-app-name"
                        )
                    }
                }
            ).also {
                Log.i(TAG, "OpenTelemetry initialized successfully")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize OpenTelemetry", e)
            null
        }
    }
}
```

**Reference:** O2 Scanner implementation at `o2Scanner/app/src/main/java/com/o2/scanner/ScannerApplication.kt:23-51`

#### Option B: Add to Existing Application Class

If you already have an `Application` class:

```kotlin
class YourExistingApplication : Application() {

    var otelRum: OpenTelemetryRum? = null  // Add this

    override fun onCreate() {
        super.onCreate()

        // Your existing initialization code
        initializeYourLibraries()

        // Add OpenTelemetry initialization
        otelRum = initializeOpenTelemetry()
    }

    // Add this method
    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        return try {
            OpenTelemetryRumInitializer.initialize(context = this)
        } catch (e: Exception) {
            Log.e("App", "Failed to init OpenTelemetry", e)
            null
        }
    }
}
```

---

### Step 4: Update AndroidManifest.xml

Register your Application class in the manifest:

```xml
<application
    android:name=".YourApplication"  <!-- Add this line -->
    android:icon="@mipmap/ic_launcher"
    android:label="@string/app_name">
    <!-- ... -->
</application>
```

---

### Step 5: Build and Test

```bash
# Clean and rebuild
./gradlew clean assembleDebug

# Install on device/emulator
adb install app/build/outputs/apk/debug/app-debug.apk

# Check logs for confirmation
adb logcat | grep -i opentelemetry
```

**Expected log output:**
```
I/YourApplication: OpenTelemetry initialized successfully
```

---

## Auto-Instrumentation Features

### What Gets Tracked Automatically

Once initialized, the SDK automatically captures:

#### 1. Activity Lifecycle

**Tracked Events:**
- `activity.created` - Activity onCreate()
- `activity.started` - Activity onStart()
- `activity.resumed` - Activity onResume()
- `activity.paused` - Activity onPause()
- `activity.stopped` - Activity onStop()
- `activity.destroyed` - Activity onDestroy()

**Attributes:**
- `screen.name` - Activity class name
- `activity.class` - Fully qualified class name
- `timestamp` - Event timestamp

**No code required** - This happens automatically for ALL activities.

#### 2. App Crashes

**Tracked Data:**
- Full stack trace
- Exception type and message
- Activity where crash occurred
- Device information
- App state at crash time

**Example:**
```
Crash Event: {
  "exception.type": "NullPointerException",
  "exception.message": "Attempt to invoke virtual method...",
  "exception.stacktrace": "at com.yourapp.MainActivity.onCreate...",
  "screen.name": "MainActivity",
  "device.id": "abc123"
}
```

#### 3. ANRs (Application Not Responding)

**Tracked When:**
- Main thread blocked > 5 seconds
- UI freeze detected
- Touch events not responding

**Attributes:**
- Thread stack traces
- Blocked duration
- Current activity

#### 4. Slow Renders

**Tracked:**
- Frame render time > 16ms (60 FPS threshold)
- Janky animations
- UI lag

**Attributes:**
- `render.duration_ms` - Time to render frame
- `screen.name` - Current screen
- `frame.drop.count` - Frames dropped

#### 5. Network State Changes

**Tracked Events:**
- WiFi connected/disconnected
- Mobile data connected/disconnected
- Network type changes (WiFi ↔ Mobile)
- Network unavailable

**Reference:** See MONITORING.md lines 15-37 for complete list

---

## Custom Instrumentation

While auto-instrumentation covers general app behavior, you'll want to track business-specific events.

### Example 1: Track User Actions

**Scenario:** E-commerce app tracking product views

```kotlin
class YourApplication : Application() {
    var otelRum: OpenTelemetryRum? = null

    // Add custom tracking methods
    fun trackProductView(productId: String, productName: String, price: Double) {
        val tracer = otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")

        tracer?.spanBuilder("product.viewed")
            ?.setAttribute(stringKey("product.id"), productId)
            ?.setAttribute(stringKey("product.name"), productName)
            ?.setAttribute(doubleKey("product.price"), price)
            ?.setAttribute(stringKey("user.id"), getCurrentUserId())
            ?.startSpan()
            ?.end()
    }

    fun trackAddToCart(productId: String, quantity: Int) {
        val tracer = otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")

        tracer?.spanBuilder("cart.item_added")
            ?.setAttribute(stringKey("product.id"), productId)
            ?.setAttribute(longKey("quantity"), quantity.toLong())
            ?.startSpan()
            ?.end()
    }
}
```

**Usage in Activity:**

```kotlin
class ProductActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Track product view
        (application as YourApplication).trackProductView(
            productId = "SKU-12345",
            productName = "Wireless Headphones",
            price = 99.99
        )
    }

    private fun onAddToCartClicked() {
        (application as YourApplication).trackAddToCart(
            productId = "SKU-12345",
            quantity = 1
        )
    }
}
```

### Example 2: Track Business Operations (O2 Scanner Reference)

**Scenario:** Barcode scanner app tracking scan events

```kotlin
class ScannerApplication : Application() {

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
            ?.setAttribute(stringKey("device.id"), getDeviceId())
            ?.startSpan()
            ?.end()

        Log.d(TAG, "Scan tracked: format=$barcodeFormat, duration=${scanDurationMs}ms")
    }
}
```

**Reference:** O2 Scanner implementation at `ScannerApplication.kt:56-74`

### Example 3: Track Errors and Exceptions

**Scenario:** Track specific error conditions

```kotlin
class YourApplication : Application() {

    fun trackCustomError(errorType: String, errorMessage: String, context: String) {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("app-errors")

        logger?.logRecordBuilder()
            ?.setEventName("app.error")
            ?.setAttribute(stringKey("error.type"), errorType)
            ?.setAttribute(stringKey("error.message"), errorMessage)
            ?.setAttribute(stringKey("error.context"), context)
            ?.setAttribute(stringKey("device.id"), getDeviceId())
            ?.setAttribute(stringKey("app.version"), BuildConfig.VERSION_NAME)
            ?.emit()

        Log.w(TAG, "Error tracked: $errorType - $errorMessage")
    }
}
```

**Usage:**

```kotlin
class PaymentActivity : AppCompatActivity() {
    private fun processPayment() {
        try {
            // Payment processing logic
        } catch (e: PaymentException) {
            (application as YourApplication).trackCustomError(
                errorType = "payment_failed",
                errorMessage = e.message ?: "Unknown payment error",
                context = "PaymentActivity.processPayment"
            )
        }
    }
}
```

**Reference:** O2 Scanner implementation at `ScannerApplication.kt:79-90`

### Example 4: Track Feature Usage

**Scenario:** Track which features users actually use

```kotlin
class YourApplication : Application() {

    fun trackFeatureUsage(featureName: String, details: Map<String, String> = emptyMap()) {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("features")

        val builder = logger?.logRecordBuilder()
            ?.setEventName("feature.used")
            ?.setAttribute(stringKey("feature.name"), featureName)
            ?.setAttribute(stringKey("user.id"), getCurrentUserId())

        // Add custom details
        details.forEach { (key, value) ->
            builder?.setAttribute(stringKey("feature.$key"), value)
        }

        builder?.emit()
    }
}
```

**Usage:**

```kotlin
// Track camera usage
(application as YourApplication).trackFeatureUsage(
    "camera",
    mapOf("mode" to "photo", "flash" to "on")
)

// Track search usage
(application as YourApplication).trackFeatureUsage(
    "search",
    mapOf("query_length" to "15", "results_count" to "42")
)
```

### Available Attribute Types

```kotlin
import io.opentelemetry.api.common.AttributeKey.*

// String attributes
stringKey("key.name")

// Numeric attributes
longKey("count")
doubleKey("amount")

// Boolean attributes
booleanKey("is_enabled")

// Array attributes
stringArrayKey("tags")
longArrayKey("item_ids")
```

---

## Backend Configuration

### Option 1: OpenObserve (Used in O2 Scanner)

```kotlin
private fun initializeOpenTelemetry(): OpenTelemetryRum? {
    return try {
        OpenTelemetryRumInitializer.initialize(
            context = this,
            configuration = {
                httpExport {
                    baseUrl = "https://introspection.dev.zinclabs.dev/api/default"
                    baseHeaders = mapOf(
                        "Authorization" to "Basic YOUR_BASE64_TOKEN",
                        "stream-name" to "your-app-name"
                    )
                }
            }
        )
    } catch (e: Exception) {
        Log.e(TAG, "Failed to init OpenTelemetry", e)
        null
    }
}
```

**Reference:** O2 Scanner at `ScannerApplication.kt:48-54`

### Option 2: Jaeger

```kotlin
httpExport {
    baseUrl = "http://your-jaeger-server:4318"
}
```

### Option 3: Self-Hosted OpenTelemetry Collector

```kotlin
httpExport {
    baseUrl = "http://192.168.1.100:4318"  // Internal network
    // or
    baseUrl = "http://collector.yourcompany.local:4318"
}
```

### Option 4: Cloud Services with Authentication

```kotlin
httpExport {
    baseUrl = "https://otel-collector.yourcloud.com:4318"
    baseHeaders = mapOf(
        "Authorization" to "Bearer ${BuildConfig.OTEL_API_KEY}",
        "X-Service-Name" to "mobile-app",
        "X-Environment" to BuildConfig.BUILD_TYPE
    )
}
```

### Option 5: Different Endpoints for Build Types

```kotlin
private fun initializeOpenTelemetry(): OpenTelemetryRum? {
    return try {
        OpenTelemetryRumInitializer.initialize(
            context = this,
            configuration = {
                httpExport {
                    baseUrl = when (BuildConfig.BUILD_TYPE) {
                        "debug" -> "http://10.0.2.2:4318"  // Local emulator
                        "staging" -> "https://staging-collector.company.com:4318"
                        "release" -> "https://prod-collector.company.com:4318"
                        else -> "http://10.0.2.2:4318"
                    }

                    baseHeaders = mapOf(
                        "Authorization" to "Bearer ${BuildConfig.OTEL_TOKEN}",
                        "X-App-Version" to BuildConfig.VERSION_NAME,
                        "X-Environment" to BuildConfig.BUILD_TYPE
                    )
                }
            }
        )
    } catch (e: Exception) {
        null
    }
}
```

### Securing API Keys

**Never hardcode tokens in code!** Use `gradle.properties` or BuildConfig:

**File:** `app/build.gradle.kts`

```kotlin
android {
    defaultConfig {
        // Read from gradle.properties or environment
        buildConfigField("String", "OTEL_ENDPOINT", "\"${project.findProperty("otel.endpoint")}\"")
        buildConfigField("String", "OTEL_TOKEN", "\"${project.findProperty("otel.token")}\"")
    }
}
```

**File:** `gradle.properties` (add to .gitignore!)

```properties
otel.endpoint=https://your-backend.com/api/default
otel.token=your-secret-token-here
```

**Usage:**

```kotlin
httpExport {
    baseUrl = BuildConfig.OTEL_ENDPOINT
    baseHeaders = mapOf("Authorization" to "Bearer ${BuildConfig.OTEL_TOKEN}")
}
```

---

## Testing & Verification

### Step 1: Enable Logging

Add logging to see telemetry events:

```kotlin
private fun initializeOpenTelemetry(): OpenTelemetryRum? {
    return try {
        OpenTelemetryRumInitializer.initialize(
            context = this,
            configuration = {
                httpExport {
                    baseUrl = "your-endpoint"
                }
            }
        ).also {
            Log.i(TAG, "✅ OpenTelemetry initialized - endpoint: your-endpoint")
        }
    } catch (e: Exception) {
        Log.e(TAG, "❌ OpenTelemetry initialization failed", e)
        null
    }
}
```

### Step 2: Check Device Logs

```bash
# Start logcat
adb logcat -c  # Clear logs
adb logcat | grep -i "opentelemetry\|YourApplication"

# Expected output:
# I/YourApplication: ✅ OpenTelemetry initialized - endpoint: https://...
# D/OpenTelemetryRum: Span exported: activity.created
# D/OpenTelemetryRum: Span exported: qr.scan
```

### Step 3: Verify Network Traffic

```bash
# Monitor network calls
adb logcat | grep -i "http\|network"

# Should see POST requests to your telemetry endpoint
```

### Step 4: Check Backend

1. **Open your telemetry backend** (OpenObserve, Jaeger, etc.)
2. **Navigate to Traces/Logs**
3. **Filter by your app** (stream name or service name)
4. **Verify events are appearing:**
   - Activity lifecycle events
   - Custom events you added
   - Device metadata

### Step 5: Test Specific Scenarios

**Test Auto-Instrumentation:**

```bash
# 1. Launch app → Should see "activity.created" event
# 2. Navigate between screens → Should see activity transitions
# 3. Force close app → Should NOT see crash (expected behavior)
# 4. Trigger actual crash → Should see crash event with stack trace
```

**Test Custom Events:**

Add temporary logging:

```kotlin
fun trackProductView(productId: String) {
    Log.d(TAG, "📊 Tracking product view: $productId")

    val tracer = otelRum?.openTelemetry?.tracerProvider?.get("app")
    tracer?.spanBuilder("product.viewed")
        ?.setAttribute(stringKey("product.id"), productId)
        ?.startSpan()
        ?.end()

    Log.d(TAG, "✅ Product view tracked")
}
```

### Step 6: Performance Verification

Monitor app performance to ensure telemetry doesn't impact UX:

```bash
# Check CPU usage
adb shell top | grep your.app.package

# Check memory usage
adb shell dumpsys meminfo your.app.package

# Check battery impact
adb shell dumpsys batterystats your.app.package
```

**Expected Impact:**
- CPU: < 1% additional usage
- Memory: < 5MB additional RAM
- Battery: Negligible (< 1% daily drain)
- APK Size: +1-2MB

---

## Production Deployment

### Checklist Before Production

- [ ] **Remove test/debug endpoints** - Use production backend URL
- [ ] **Secure API tokens** - Use BuildConfig, not hardcoded strings
- [ ] **Test on real devices** - Not just emulators
- [ ] **Verify data privacy** - Ensure no PII in telemetry
- [ ] **Configure sampling** - Reduce data volume if needed
- [ ] **Set up alerts** - For crashes and critical errors
- [ ] **Document for team** - How to view telemetry
- [ ] **Test offline behavior** - App should work without connectivity

### Production Configuration Example

```kotlin
class ProductionApplication : Application() {

    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        // Only enable in release builds or for opted-in users
        if (BuildConfig.BUILD_TYPE != "release" && !isUserOptedIn()) {
            Log.i(TAG, "Telemetry disabled in debug mode")
            return null
        }

        return try {
            OpenTelemetryRumInitializer.initialize(
                context = this,
                configuration = {
                    httpExport {
                        // Use production endpoint
                        baseUrl = BuildConfig.OTEL_ENDPOINT

                        // Secure authentication
                        baseHeaders = mapOf(
                            "Authorization" to "Bearer ${BuildConfig.OTEL_TOKEN}",
                            "X-App-Version" to BuildConfig.VERSION_NAME,
                            "X-Device-ID" to getDeviceId()
                        )
                    }
                }
            ).also {
                Log.i(TAG, "Telemetry enabled - version ${BuildConfig.VERSION_NAME}")
            }
        } catch (e: Exception) {
            // Never crash due to telemetry failure
            Log.e(TAG, "Telemetry init failed - continuing without it", e)
            null
        }
    }

    private fun isUserOptedIn(): Boolean {
        // Check user preferences
        val prefs = getSharedPreferences("settings", MODE_PRIVATE)
        return prefs.getBoolean("telemetry_enabled", true)
    }
}
```

### Gradual Rollout

Start with a small percentage of users:

```kotlin
private fun shouldEnableTelemetry(): Boolean {
    // Enable for 10% of users initially
    val deviceId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
    val hash = deviceId.hashCode().toLong().absoluteValue
    return (hash % 100) < 10  // 10% rollout
}

private fun initializeOpenTelemetry(): OpenTelemetryRum? {
    if (!shouldEnableTelemetry()) {
        return null
    }
    // ... rest of initialization
}
```

### Data Privacy Considerations

**DO:**
- ✅ Track device ID (anonymous identifier)
- ✅ Track app version, OS version, device model
- ✅ Track feature usage (which buttons clicked)
- ✅ Track performance metrics (duration, counts)
- ✅ Track error types and stack traces

**DON'T:**
- ❌ Track user names, emails, phone numbers
- ❌ Track payment information
- ❌ Track personal messages or content
- ❌ Track location data (unless explicitly needed and consented)
- ❌ Track passwords or authentication tokens

**Sanitize user input:**

```kotlin
fun trackSearchQuery(query: String) {
    // Don't send actual query, just metadata
    tracer?.spanBuilder("search.performed")
        ?.setAttribute(longKey("query.length"), query.length.toLong())
        ?.setAttribute(longKey("results.count"), resultCount)
        // NOT: .setAttribute(stringKey("query.text"), query)  ❌
        ?.startSpan()
        ?.end()
}
```

---

## Troubleshooting

### Issue 1: "Failed to initialize OpenTelemetry"

**Symptoms:**
```
E/YourApp: Failed to initialize OpenTelemetry
   java.lang.NoClassDefFoundError: io.opentelemetry.android.OpenTelemetryRum
```

**Solution:**
```kotlin
// In app/build.gradle.kts, ensure BOM is used:
implementation(platform("io.opentelemetry.android:opentelemetry-android-bom:1.2.0-alpha"))
implementation("io.opentelemetry.android:android-agent")
```

### Issue 2: Kotlin Version Mismatch

**Symptoms:**
```
e: Class 'kotlin.Unit' was compiled with incompatible version of Kotlin
```

**Solution:**
```kotlin
// In app/build.gradle.kts
configurations.all {
    resolutionStrategy {
        force("org.jetbrains.kotlin:kotlin-stdlib:1.9.20")
        force("org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.9.20")
        force("org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.20")
    }
}
```

**Reference:** O2 Scanner fix at `app/build.gradle.kts:48-56`

### Issue 3: No Data Appearing in Backend

**Check:**

```bash
# 1. Verify app has internet permission
grep INTERNET app/src/main/AndroidManifest.xml

# 2. Check if telemetry is initialized
adb logcat | grep -i "opentelemetry initialized"

# 3. Verify device connectivity
adb shell ping -c 3 8.8.8.8

# 4. Check endpoint URL
adb logcat | grep -i "http\|endpoint"

# 5. Test endpoint manually
curl -X POST https://your-endpoint/api/default \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'
```

### Issue 4: BuildConfig Not Found

**Symptoms:**
```
e: Unresolved reference: BuildConfig
```

**Solution:**
```kotlin
// In app/build.gradle.kts
android {
    buildFeatures {
        buildConfig = true  // Add this
    }
}
```

**Reference:** O2 Scanner fix at `app/build.gradle.kts:45`

### Issue 5: App Crashes on Startup

**Symptoms:**
App crashes immediately after adding OpenTelemetry

**Solution:**

```kotlin
// Wrap initialization in try-catch
private fun initializeOpenTelemetry(): OpenTelemetryRum? {
    return try {
        OpenTelemetryRumInitializer.initialize(context = this)
    } catch (e: Exception) {
        // Log but don't crash
        Log.e(TAG, "Telemetry init failed", e)
        null  // App continues without telemetry
    }
}
```

### Issue 6: Telemetry Delayed

**Expected Behavior:**
Telemetry is batched and sent every 10-30 seconds, not immediately.

**Verification:**
```bash
# Wait 30 seconds after triggering event, then check backend
# This is normal and reduces battery/network usage
```

### Issue 7: ProGuard/R8 Issues in Release Build

**Symptoms:**
Telemetry works in debug but fails in release build

**Solution:**

Add ProGuard rules:

**File:** `app/proguard-rules.pro`

```proguard
# OpenTelemetry
-keep class io.opentelemetry.** { *; }
-dontwarn io.opentelemetry.**

# Keep Application class
-keep public class * extends android.app.Application
```

---

## Best Practices

### 1. Initialize Early

```kotlin
class YourApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        // Initialize OpenTelemetry FIRST
        otelRum = initializeOpenTelemetry()

        // Then other libraries
        initializeOtherLibraries()
    }
}
```

### 2. Use Consistent Naming

```kotlin
// Good - Consistent naming scheme
"user.login"
"user.logout"
"user.profile_viewed"

"product.viewed"
"product.added_to_cart"
"product.purchased"

// Bad - Inconsistent
"LoginEvent"
"user_logged_out"
"ProfileView"
```

### 3. Add Context to Events

```kotlin
// Good - Rich context
tracer?.spanBuilder("payment.completed")
    ?.setAttribute(stringKey("payment.method"), "credit_card")
    ?.setAttribute(doubleKey("payment.amount"), 99.99)
    ?.setAttribute(stringKey("payment.currency"), "USD")
    ?.setAttribute(stringKey("order.id"), orderId)
    ?.startSpan()
    ?.end()

// Bad - Minimal context
tracer?.spanBuilder("payment").startSpan()?.end()
```

### 4. Don't Block Main Thread

```kotlin
// Good - Non-blocking
fun trackEvent(name: String) {
    // OpenTelemetry SDK handles async automatically
    tracer?.spanBuilder(name).startSpan()?.end()
}

// Bad - Don't do this
fun trackEvent(name: String) {
    // Don't add your own blocking operations
    val response = httpClient.post("...").execute()  // ❌ Blocking call
}
```

### 5. Handle Failures Gracefully

```kotlin
// Good - Safe tracking
fun trackFeature(name: String) {
    try {
        otelRum?.openTelemetry?.tracerProvider?.get("app")
            ?.spanBuilder(name)
            ?.startSpan()
            ?.end()
    } catch (e: Exception) {
        // Log but don't crash
        Log.w(TAG, "Failed to track: $name", e)
    }
}

// Bad - Can crash app
fun trackFeature(name: String) {
    otelRum!!.openTelemetry.tracerProvider.get("app")  // ❌ Can throw NPE
        .spanBuilder(name).startSpan().end()
}
```

### 6. Use Helper Extensions

Create reusable extensions:

```kotlin
// File: TelemetryExtensions.kt

fun Application.getOtelTracer(instrumentationName: String = "app") =
    (this as? YourApplication)?.otelRum?.openTelemetry?.tracerProvider?.get(instrumentationName)

fun Application.trackEvent(
    name: String,
    attributes: Map<String, String> = emptyMap()
) {
    val builder = getOtelTracer()?.spanBuilder(name)
    attributes.forEach { (key, value) ->
        builder?.setAttribute(stringKey(key), value)
    }
    builder?.startSpan()?.end()
}
```

**Usage:**

```kotlin
class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Simple tracking
        application.trackEvent(
            "screen.viewed",
            mapOf("screen.name" to "MainActivity")
        )
    }
}
```

### 7. Test Telemetry in CI/CD

```yaml
# .github/workflows/android-build.yml
- name: Build and Test Telemetry
  run: |
    ./gradlew assembleDebug

    # Verify OpenTelemetry classes are included
    unzip -l app/build/outputs/apk/debug/app-debug.apk | grep opentelemetry

    # Check for telemetry initialization
    grep -r "OpenTelemetryRumInitializer" app/src/main/
```

### 8. Monitor Telemetry Health

Create a dashboard for telemetry itself:

**Metrics to track:**
- Events per minute
- Failed initialization count
- Network errors during export
- Data drop rate

---

## Real-World Examples

### Example 1: E-Commerce App

```kotlin
class ShoppingApplication : Application() {
    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = initializeOpenTelemetry()
    }

    // Track product interactions
    fun trackProductViewed(product: Product) {
        getOtelTracer()?.spanBuilder("product.viewed")
            ?.setAttribute(stringKey("product.id"), product.id)
            ?.setAttribute(stringKey("product.name"), product.name)
            ?.setAttribute(stringKey("product.category"), product.category)
            ?.setAttribute(doubleKey("product.price"), product.price)
            ?.setAttribute(booleanKey("product.in_stock"), product.inStock)
            ?.startSpan()
            ?.end()
    }

    // Track cart operations
    fun trackCartAction(action: String, itemCount: Int, totalValue: Double) {
        getOtelTracer()?.spanBuilder("cart.$action")
            ?.setAttribute(longKey("cart.item_count"), itemCount.toLong())
            ?.setAttribute(doubleKey("cart.total_value"), totalValue)
            ?.startSpan()
            ?.end()
    }

    // Track checkout flow
    fun trackCheckoutStep(step: String, success: Boolean) {
        getOtelTracer()?.spanBuilder("checkout.$step")
            ?.setAttribute(booleanKey("success"), success)
            ?.startSpan()
            ?.end()
    }
}
```

### Example 2: Social Media App

```kotlin
class SocialApplication : Application() {
    var otelRum: OpenTelemetryRum? = null

    fun trackPostCreated(postType: String, hasMedia: Boolean, characterCount: Int) {
        getOtelTracer()?.spanBuilder("post.created")
            ?.setAttribute(stringKey("post.type"), postType)
            ?.setAttribute(booleanKey("post.has_media"), hasMedia)
            ?.setAttribute(longKey("post.character_count"), characterCount.toLong())
            ?.startSpan()
            ?.end()
    }

    fun trackSocialInteraction(type: String, targetType: String) {
        // Type: like, share, comment
        // TargetType: post, story, comment
        getOtelTracer()?.spanBuilder("social.$type")
            ?.setAttribute(stringKey("target.type"), targetType)
            ?.startSpan()
            ?.end()
    }
}
```

### Example 3: Fitness Tracking App

```kotlin
class FitnessApplication : Application() {
    var otelRum: OpenTelemetryRum? = null

    fun trackWorkoutStarted(workoutType: String, durationMinutes: Int) {
        getOtelTracer()?.spanBuilder("workout.started")
            ?.setAttribute(stringKey("workout.type"), workoutType)
            ?.setAttribute(longKey("workout.planned_duration"), durationMinutes.toLong())
            ?.startSpan()
            ?.end()
    }

    fun trackWorkoutCompleted(
        workoutType: String,
        durationMinutes: Int,
        caloriesBurned: Int,
        completed: Boolean
    ) {
        getOtelTracer()?.spanBuilder("workout.completed")
            ?.setAttribute(stringKey("workout.type"), workoutType)
            ?.setAttribute(longKey("workout.duration"), durationMinutes.toLong())
            ?.setAttribute(longKey("workout.calories"), caloriesBurned.toLong())
            ?.setAttribute(booleanKey("workout.completed"), completed)
            ?.startSpan()
            ?.end()
    }
}
```

---

## Summary

### What You Get

✅ **Auto-Instrumentation** - Activities, crashes, ANRs, performance (95% automatic)
✅ **Custom Events** - Track your business-specific metrics (5% manual)
✅ **Device Identification** - Track individual devices in your fleet
✅ **Production Ready** - Minimal performance impact (<1% overhead)
✅ **Backend Agnostic** - Works with OpenObserve, Jaeger, Prometheus, etc.

### Integration Effort

| Task | Time | Complexity |
|------|------|------------|
| Add dependencies | 5 min | Easy |
| Create Application class | 10 min | Easy |
| Basic configuration | 5 min | Easy |
| Test & verify | 10 min | Medium |
| Add custom events | Variable | Medium |
| **Total (minimal)** | **30 min** | **Easy** |

### Key Files Modified

For any Android app integration:

1. `app/build.gradle.kts` - Add OpenTelemetry dependency
2. `app/src/main/AndroidManifest.xml` - Add permissions + Application class
3. `app/src/main/java/.../YourApplication.kt` - Initialize OpenTelemetry
4. Activities/Fragments - Add custom tracking calls (optional)

### Comparison: Manual vs Auto-Instrumentation

| Metric | Manual Tracking | Auto-Instrumentation |
|--------|----------------|---------------------|
| **Setup Time** | 40-60 hours | 30 minutes |
| **Code to Write** | 1000+ lines | <50 lines |
| **Coverage** | 40-60% of events | 95%+ of events |
| **Maintenance** | High (update for each screen) | Low (automatic) |
| **Error Prone** | Yes (easy to forget) | No (automatic) |
| **Performance Impact** | Variable | <1% overhead |

---

## Additional Resources

### Documentation

- [OpenTelemetry Android SDK](https://github.com/open-telemetry/opentelemetry-android)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [OTLP Protocol](https://opentelemetry.io/docs/specs/otlp/)

### Backend Options

- [OpenObserve](https://openobserve.ai/) - Modern observability platform
- [Jaeger](https://www.jaegertracing.io/) - Distributed tracing
- [Prometheus](https://prometheus.io/) - Metrics & monitoring
- [Grafana](https://grafana.com/) - Visualization & dashboards

### Related Guides

- `MONITORING.md` - O2 Scanner monitoring documentation
- `ScannerApplication.kt` - Reference implementation
- `MainActivity.kt` - Custom tracking examples

---

## Support

**Questions?**
- Review the O2 Scanner app as a complete working example
- Check `ScannerApplication.kt` for real implementation
- See `MONITORING.md` for troubleshooting tips

**Issues?**
- Enable verbose logging with `adb logcat`
- Check telemetry backend for data
- Verify network connectivity and permissions

---

**Last Updated:** 2026-04-12
**OpenTelemetry Android SDK Version:** 1.2.0-alpha
**Reference Implementation:** O2 Scanner (`/Users/mdmosaraf/Documents/work/monitroing/o2Scanner/`)
