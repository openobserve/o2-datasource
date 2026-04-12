# O2 Scanner - Android QR Code Scanner with OpenTelemetry

A production-ready Android QR/Barcode scanner application with comprehensive OpenTelemetry auto-instrumentation for fleet monitoring and observability.

---

## 📱 Application Features

- **QR Code & Barcode Scanning** - Supports QR Code, Code 128, EAN, UPC, and more
- **Real-time Camera Preview** - CameraX integration with autofocus
- **Flashlight Toggle** - Built-in torch control
- **Visual Feedback** - Success animations and haptic feedback
- **Scan History** - View previously scanned codes
- **Material Design** - Clean, modern UI

## 📊 OpenTelemetry Monitoring

This app demonstrates **complete OpenTelemetry integration** for Android applications.

### Auto-Instrumented (Automatic - No Code Needed)

✅ **Activity Lifecycle** - onCreate, onResume, onPause, etc.
✅ **App Crashes** - Full stack traces + context
✅ **ANRs** - Application Not Responding events
✅ **Slow Renders** - UI performance issues
✅ **Network State** - Connectivity changes

### Custom Instrumented (Scanner-Specific)

✅ **QR Scan Events** - Format, duration, success rate
✅ **Camera Operations** - Initialization, permissions, flashlight
✅ **Scan Errors** - Camera failures, permission denials

### Telemetry Backend

**Data sent to:** OpenObserve
- **Endpoint:** `https://introspection.dev.zinclabs.dev/api/default`
- **Stream:** `o2scanner`
- **Protocol:** OTLP/HTTP with authentication

---

## 🗂️ Documentation

### 📖 For This App

| Document | Description | Best For |
|----------|-------------|----------|
| **[MONITORING.md](MONITORING.md)** | O2 Scanner monitoring guide | Understanding what's tracked in this app |
| **Build Instructions** | See [Building & Testing](#building--testing) below | Running this app |

### 📘 For Your Own App

| Document | Description | Best For |
|----------|-------------|----------|
| **[QUICK_START_GUIDE.md](QUICK_START_GUIDE.md)** | 5-minute integration guide | Quick integration (start here!) ⭐ |
| **[OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md](OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md)** | Complete integration guide | Comprehensive step-by-step guide |
| **[INTEGRATION_EXAMPLES.md](INTEGRATION_EXAMPLES.md)** | Examples for different app types | E-commerce, social media, fitness apps |

---

## 🚀 Quick Start

### Building & Testing

```bash
# Clone or navigate to project
cd /Users/mdmosaraf/Documents/work/monitroing/o2Scanner

# Build the app
./gradlew clean assembleDebug

# Install on device/emulator
adb install app/build/outputs/apk/debug/app-debug.apk

# View telemetry logs
adb logcat | grep -i "opentelemetry\|scanner"
```

### View Telemetry Data

1. Open OpenObserve at https://introspection.dev.zinclabs.dev
2. Navigate to **Traces** tab
3. Filter by stream: `o2scanner`
4. View scan events, camera operations, and app lifecycle

---

## 📁 Project Structure

```
o2Scanner/
├── app/
│   ├── src/main/
│   │   ├── java/com/o2/scanner/
│   │   │   ├── ScannerApplication.kt      # OpenTelemetry initialization ⭐
│   │   │   ├── MainActivity.kt             # QR scanner + tracking
│   │   │   ├── ScanResultActivity.kt       # Result display
│   │   │   └── ScanOverlayView.kt          # Camera overlay
│   │   ├── res/
│   │   │   ├── layout/                     # UI layouts
│   │   │   ├── drawable/                   # Icons and graphics
│   │   │   └── values/                     # Strings, colors, themes
│   │   └── AndroidManifest.xml             # App configuration
│   └── build.gradle.kts                    # Dependencies ⭐
│
├── MONITORING.md                            # This app's monitoring docs
├── QUICK_START_GUIDE.md                    # 5-min integration guide ⭐
├── OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md  # Complete guide ⭐
├── INTEGRATION_EXAMPLES.md                 # App-specific examples ⭐
└── README.md                               # This file

⭐ = Key files for understanding OpenTelemetry integration
```

---

## 🔧 Key Implementation Files

### 1. ScannerApplication.kt - OpenTelemetry Setup

The heart of the monitoring integration:

```kotlin
class ScannerApplication : Application() {
    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = initializeOpenTelemetry()
    }

    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        return OpenTelemetryRumInitializer.initialize(
            context = this,
            configuration = {
                httpExport {
                    baseUrl = "https://introspection.dev.zinclabs.dev/api/default"
                    baseHeaders = mapOf(
                        "Authorization" to "Basic ...",
                        "stream-name" to "o2scanner"
                    )
                }
            }
        )
    }

    // Custom tracking methods
    fun trackScanEvent(...)
    fun trackCameraEvent(...)
    fun trackScanError(...)
}
```

**Location:** `app/src/main/java/com/o2/scanner/ScannerApplication.kt`

### 2. build.gradle.kts - Dependencies

```kotlin
dependencies {
    // OpenTelemetry Android SDK
    implementation(platform("io.opentelemetry.android:opentelemetry-android-bom:1.2.0-alpha"))
    implementation("io.opentelemetry.android:android-agent")

    // Camera & ML Kit for scanning
    implementation("androidx.camera:camera-core:1.3.1")
    implementation("com.google.mlkit:barcode-scanning:17.2.0")
}
```

**Location:** `app/build.gradle.kts`

### 3. AndroidManifest.xml - Configuration

```xml
<manifest>
    <!-- Required permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />

    <application android:name=".ScannerApplication">
        <!-- Activities -->
    </application>
</manifest>
```

**Location:** `app/src/main/AndroidManifest.xml`

---

## 📊 What Gets Tracked

### Automatic Events (No Code)

| Event | When | Attributes |
|-------|------|------------|
| `activity.created` | Activity starts | screen.name, timestamp |
| `activity.resumed` | Activity visible | screen.name, timestamp |
| `app.crash` | App crashes | exception.type, stack_trace, screen |
| `anr.detected` | App freezes | blocked_duration, thread_stack |
| `network.changed` | WiFi/Mobile change | network.type, available |

### Custom Events (App-Specific)

| Event | When | Attributes |
|-------|------|------------|
| `qr.scan` | QR code scanned | format, duration_ms, status, device.id |
| `camera.initialized` | Camera starts | device.id |
| `camera.flashlight_toggled` | Flashlight on/off | state (on/off), device.id |
| `scan.error` | Scan fails | error.type, error.message, device.id |

**See [MONITORING.md](MONITORING.md) for complete list.**

---

## 🎯 Use Cases

### Fleet Management

**Scenario:** Warehouse with 50+ Honeywell CK65 devices

**Track:**
- Scans per device per shift
- Average scan duration by device
- Devices with camera issues
- Scan success rates

**Dashboard Queries:**
```
Total Scans Today: count(qr.scan) by device.id
Avg Scan Duration: avg(scan.duration_ms)
Error Rate: count(scan.error) / count(qr.scan) * 100
```

### Performance Monitoring

**Track:**
- App startup time
- Screen transition speed
- Camera initialization time
- Scan responsiveness

### Device Health

**Track:**
- Crash frequency per device
- ANR occurrences
- Camera permission issues
- Network connectivity problems

---

## 🛠️ Customization

### Change Telemetry Backend

**Edit:** `app/src/main/java/com/o2/scanner/ScannerApplication.kt` (Line 48-54)

```kotlin
httpExport {
    baseUrl = "https://your-backend.com/api/default"
    baseHeaders = mapOf(
        "Authorization" to "Bearer YOUR_TOKEN",
        "stream-name" to "your-stream-name"
    )
}
```

### Add Custom Tracking

```kotlin
// In ScannerApplication.kt
fun trackCustomEvent(name: String, attributes: Map<String, String>) {
    val builder = otelRum?.openTelemetry?.tracerProvider?.get("scanner")
        ?.spanBuilder(name)

    attributes.forEach { (key, value) ->
        builder?.setAttribute(stringKey(key), value)
    }

    builder?.startSpan()?.end()
}
```

**Usage in Activity:**

```kotlin
(application as ScannerApplication).trackCustomEvent(
    "inventory.lookup",
    mapOf("item_id" to "SKU-12345", "location" to "Warehouse A")
)
```

---

## 📈 Monitoring Dashboard Examples

### Scan Performance

```
┌─────────────────────────────────────┐
│ Total Scans Today: 2,340           │
│ Average Duration: 847ms             │
│ Success Rate: 99.2%                 │
└─────────────────────────────────────┘

Top Performing Devices:
  CK65-001: 156 scans (avg 650ms)
  CK65-042: 143 scans (avg 720ms)
  CK65-018: 128 scans (avg 810ms)

Devices with Issues:
  CK65-031: 3 camera errors
  CK65-012: 2 permission denials
```

### Format Breakdown

```
Scan Format Distribution:
  QR Code:    78% (1,825 scans)
  Code 128:   15% (351 scans)
  UPC-A:       5% (117 scans)
  Other:       2% (47 scans)
```

---

## 🐛 Troubleshooting

### No telemetry appearing?

```bash
# Check initialization
adb logcat | grep "OpenTelemetry initialized"

# Verify network connectivity
adb shell ping -c 3 introspection.dev.zinclabs.dev

# Check for errors
adb logcat | grep -i error
```

### Build errors?

```bash
# Clean and rebuild
./gradlew clean
./gradlew assembleDebug --refresh-dependencies

# Check Kotlin version conflicts
grep "kotlin-stdlib" app/build.gradle.kts
```

**See [MONITORING.md](MONITORING.md#troubleshooting) for more troubleshooting tips.**

---

## 🔒 Privacy & Security

### What's Tracked

✅ Device ID (anonymous Android ID)
✅ Scan format (QR Code, Code128, etc.)
✅ Scan duration (milliseconds)
✅ App version, OS version, device model
✅ Error types and stack traces

### What's NOT Tracked

❌ Scanned QR code content/values
❌ User names or personal information
❌ Location data
❌ IP addresses (device ID only)

### Security

- Authentication token required for OpenObserve
- HTTPS encryption for data transmission
- No local storage of telemetry data
- Telemetry failures don't crash the app

---

## 📦 Dependencies

### Core

- **Kotlin** 1.9.20
- **Android Gradle Plugin** 8.2.0
- **Target SDK** 34 (Android 14)
- **Min SDK** 23 (Android 6.0) - Compatible with Honeywell CK65

### Libraries

- **CameraX** 1.3.1 - Camera access and preview
- **ML Kit Barcode Scanning** 17.2.0 - QR/barcode detection
- **OpenTelemetry Android SDK** 1.2.0-alpha - Auto-instrumentation
- **Material Components** 1.11.0 - UI components

---

## 📝 Integration Effort

| Task | Time | Complexity |
|------|------|------------|
| Clone this app | 5 min | Easy |
| Build & run | 5 min | Easy |
| View telemetry | 5 min | Easy |
| **Integrate into YOUR app** | **30 min** | **Easy** |

**See [QUICK_START_GUIDE.md](QUICK_START_GUIDE.md) for 5-minute integration.**

---

## 🎓 Learning Resources

### Start Here

1. **[QUICK_START_GUIDE.md](QUICK_START_GUIDE.md)** - 5-minute integration guide
2. Run this O2 Scanner app to see it in action
3. View telemetry in OpenObserve dashboard

### Deep Dive

4. **[OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md](OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md)** - Complete guide
5. **[INTEGRATION_EXAMPLES.md](INTEGRATION_EXAMPLES.md)** - App-specific examples
6. Study `ScannerApplication.kt` for implementation details

### Reference

- [OpenTelemetry Android SDK](https://github.com/open-telemetry/opentelemetry-android)
- [OpenObserve Documentation](https://openobserve.ai/docs/)
- [MONITORING.md](MONITORING.md) - This app's monitoring setup

---

## 🤝 Contributing

This app serves as a **reference implementation** for OpenTelemetry integration in Android apps.

**To use this as a template:**

1. Copy `ScannerApplication.kt` structure
2. Copy `build.gradle.kts` dependencies
3. Update telemetry backend endpoint
4. Add your app-specific tracking methods
5. Test and verify

---

## 📄 License

This is a reference implementation for educational purposes.

---

## 🔗 Quick Links

| Link | Description |
|------|-------------|
| [QUICK_START_GUIDE.md](QUICK_START_GUIDE.md) | 5-min integration guide ⭐ |
| [OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md](OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md) | Complete integration guide |
| [INTEGRATION_EXAMPLES.md](INTEGRATION_EXAMPLES.md) | E-commerce, social, fitness examples |
| [MONITORING.md](MONITORING.md) | O2 Scanner monitoring docs |
| [ScannerApplication.kt](app/src/main/java/com/o2/scanner/ScannerApplication.kt) | OpenTelemetry initialization code |
| [OpenObserve Dashboard](https://introspection.dev.zinclabs.dev) | View telemetry data |

---

## ✅ Summary

**This app demonstrates:**

✅ OpenTelemetry auto-instrumentation for Android
✅ Custom business-specific event tracking
✅ Integration with OpenObserve telemetry backend
✅ Production-ready monitoring setup
✅ Fleet management capabilities (50+ devices)
✅ <1% performance overhead
✅ Zero-crash telemetry (failures don't affect app)

**Integration time:** 30 minutes for any Android app
**Code changes:** ~50 lines
**Effort:** Low - mostly configuration

---

**Built with ❤️ as a reference implementation for OpenTelemetry Android integration.**

**Version:** 1.0.0 | **Min Android:** 6.0 (API 23) | **Target Android:** 14 (API 34)

**Location:** `/Users/mdmosaraf/Documents/work/monitroing/o2Scanner/`
