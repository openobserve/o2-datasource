# Building & Installing O2 Scanner with Android Studio

Complete guide to build, configure, and install the O2 Scanner app using Android Studio.

---

## 📋 Table of Contents

1. [Prerequisites](#prerequisites)
2. [Opening the Project](#opening-the-project)
3. [Configuring OpenTelemetry (API Key)](#configuring-opentelemetry-api-key)
4. [Building the App](#building-the-app)
5. [Installing on Device](#installing-on-device)
6. [Troubleshooting](#troubleshooting)
7. [Advanced Configuration](#advanced-configuration)

---

## Prerequisites

### Required Software

| Software | Version | Download Link |
|----------|---------|---------------|
| **Android Studio** | Hedgehog (2023.1.1) or later | [Download](https://developer.android.com/studio) |
| **JDK** | 11 or later | Included with Android Studio |
| **Android SDK** | API 34 (Android 14) | Install via Android Studio SDK Manager |

### Hardware Requirements

- **Computer:** 8GB RAM minimum (16GB recommended)
- **Disk Space:** 10GB free space
- **Android Device or Emulator:**
  - Physical device: Android 6.0+ (API 23+)
  - Emulator: Android 6.0+ (API 23+)
  - Honeywell CK65: Android 8.1+ (API 27+)

### Enable USB Debugging (For Physical Devices)

1. Go to **Settings** → **About Phone**
2. Tap **Build Number** 7 times to enable Developer Mode
3. Go to **Settings** → **Developer Options**
4. Enable **USB Debugging**

---

## Opening the Project

### Step 1: Launch Android Studio

1. Open **Android Studio**
2. If prompted with "Welcome to Android Studio" screen:
   - Click **Open**
3. If Android Studio opens a previous project:
   - Click **File** → **Open**

### Step 2: Navigate to Project Directory

1. Browse to: `/Users/mdmosaraf/Documents/work/monitroing/o2Scanner`
2. Select the **o2Scanner** folder
3. Click **OK**

**Expected Result:**
- Android Studio will open the project
- Gradle sync will start automatically
- You'll see "Gradle sync finished" in the status bar

**If Gradle Sync Fails:**
```
1. Click "File" → "Sync Project with Gradle Files"
2. Wait for sync to complete
3. Check "Build" tab at bottom for any errors
```

### Step 3: Verify Project Structure

In the **Project** panel (left side), you should see:

```
o2Scanner/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/com/o2/scanner/
│   │   │   │   ├── ScannerApplication.kt
│   │   │   │   ├── MainActivity.kt
│   │   │   │   └── ...
│   │   │   ├── res/
│   │   │   └── AndroidManifest.xml
│   │   └── ...
│   └── build.gradle.kts
├── gradle/
└── build.gradle.kts
```

**If you see "Android" view instead of "Project" view:**
- Click the dropdown at top of Project panel
- Select **Project** view

---

## Configuring OpenTelemetry (API Key)

**⚠️ IMPORTANT:** The app requires an OpenObserve API token to send telemetry data.

### Step 1: Open ScannerApplication.kt

1. In **Project** panel, navigate to:
   ```
   app/src/main/java/com/o2/scanner/ScannerApplication.kt
   ```
2. Double-click to open the file

### Step 2: Locate the Configuration Section

**Find line 51** (or search for `YOUR_BASE64_ENCODED_TOKEN_HERE`):

```kotlin
httpExport {
    baseUrl = "https://introspection.dev.zinclabs.dev/api/default"
    baseHeaders = mapOf(
        "Authorization" to "Basic YOUR_BASE64_ENCODED_TOKEN_HERE",  // ← Line 51
        "stream-name" to "o2scanner"
    )
}
```

### Step 3: Add Your API Token

**Replace** `YOUR_BASE64_ENCODED_TOKEN_HERE` **with your actual Base64-encoded token.**

**Example:**
```kotlin
"Authorization" to "Basic aW50cm9zcGVjdGlvbnJvb3RAb3Blbm9ic2VydmUuYWk6WU9VUl9UT0tFTl9IRVJF"
```

**How to Get Your Token:**

1. Log in to OpenObserve
2. Go to **Settings** → **API Keys**
3. Copy your API key
4. Encode it: `username:password` → Base64
   ```bash
   echo -n "username:password" | base64
   ```
5. Use the result in the code

**Alternative: Use BuildConfig (More Secure)**

Instead of hardcoding, use BuildConfig:

**File:** `app/build.gradle.kts`

```kotlin
android {
    defaultConfig {
        buildConfigField("String", "OTEL_TOKEN", "\"YOUR_TOKEN_HERE\"")
    }
}
```

**File:** `ScannerApplication.kt`

```kotlin
"Authorization" to "Basic ${BuildConfig.OTEL_TOKEN}"
```

### Step 4: Save the File

Press **Ctrl+S** (Windows/Linux) or **Cmd+S** (Mac) to save.

---

## Building the App

### Build Variant Selection

Android Studio can build two variants:
- **debug** - For development/testing (larger APK, includes debug info)
- **release** - For production (smaller APK, optimized)

**To select build variant:**
1. Click **Build** → **Select Build Variant** (left sidebar)
2. Choose **debug** or **release**

---

### Option 1: Build Debug APK (Recommended for Testing)

#### Using Android Studio UI

1. Click **Build** → **Build Bundle(s) / APK(s)** → **Build APK(s)**
2. Wait for build to complete (status bar shows progress)
3. When complete, notification appears: **"APK(s) generated successfully"**
4. Click **locate** in the notification

**APK Location:**
```
app/build/outputs/apk/debug/app-debug.apk
```

#### Using Terminal in Android Studio

1. Click **View** → **Tool Windows** → **Terminal**
2. Run:
   ```bash
   ./gradlew assembleDebug
   ```
3. Wait for "BUILD SUCCESSFUL"

**Output:**
```
BUILD SUCCESSFUL in 1m 23s
39 actionable tasks: 25 executed, 14 up-to-date
```

---

### Option 2: Build Release APK (For Production)

**⚠️ Note:** Release builds require signing configuration.

#### Configure Signing (First Time Only)

**File:** `app/build.gradle.kts`

Add after `android {`:

```kotlin
android {
    signingConfigs {
        create("release") {
            storeFile = file("path/to/your/keystore.jks")
            storePassword = "your_store_password"
            keyAlias = "your_key_alias"
            keyPassword = "your_key_password"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // existing config...
        }
    }
}
```

#### Build Release APK

1. Click **Build** → **Generate Signed Bundle / APK**
2. Select **APK**
3. Click **Next**
4. Choose keystore or create new
5. Fill in passwords
6. Click **Next**
7. Select **release** build variant
8. Click **Finish**

**APK Location:**
```
app/release/app-release.apk
```

---

### Option 3: Build and Run Directly on Device

**Fastest way to test:**

1. Connect Android device via USB (or start emulator)
2. Select device from dropdown in toolbar
3. Click **Run** button (green play icon) or press **Shift+F10**
4. Android Studio will:
   - Build the app
   - Install on device
   - Launch automatically

---

## Installing on Device

### Method 1: Install via Android Studio (Easiest)

**Prerequisites:** Device connected via USB with USB debugging enabled

1. Open Android Studio with O2 Scanner project
2. Click **Run** → **Select Device** → Choose your device
3. Click green **Run** button (▶)
4. App installs and launches automatically

**Verify Installation:**
- App icon appears on device home screen
- Check **Settings** → **Apps** → See "O2 Scanner"

---

### Method 2: Install via ADB Command Line

**Prerequisites:**
- Android SDK Platform Tools installed
- Device connected via USB

#### Step 1: Verify Device Connection

```bash
adb devices
```

**Expected output:**
```
List of devices attached
ABC123XYZ    device
```

**If "unauthorized":**
- Check device screen for USB debugging prompt
- Click "Allow"

#### Step 2: Install APK

**For Debug Build:**
```bash
cd /Users/mdmosaraf/Documents/work/monitroing/o2Scanner
adb install app/build/outputs/apk/debug/app-debug.apk
```

**For Release Build:**
```bash
adb install app/build/outputs/apk/release/app-release.apk
```

**Expected output:**
```
Performing Streamed Install
Success
```

#### Step 3: Launch App

```bash
adb shell am start -n com.o2.scanner/.MainActivity
```

---

### Method 3: Install on Emulator

#### Create Emulator (First Time)

1. Click **Tools** → **Device Manager**
2. Click **Create Device**
3. Select **Phone** → **Pixel 6** → **Next**
4. Select System Image: **API 34 (Android 14)** → **Next**
5. Name: "O2_Scanner_Test"
6. Click **Finish**

#### Install on Emulator

1. Start emulator:
   - Click **Tools** → **Device Manager**
   - Click ▶ next to "O2_Scanner_Test"
2. Wait for emulator to boot
3. Drag and drop APK onto emulator window
4. OR use ADB:
   ```bash
   adb -e install app/build/outputs/apk/debug/app-debug.apk
   ```

---

### Method 4: Manual Install (Transfer APK)

**For CK65 or devices without USB cable:**

#### Step 1: Copy APK to Device

**Option A: Email**
1. Email APK to yourself
2. Open email on device
3. Download attachment

**Option B: Cloud Storage**
1. Upload APK to Google Drive/Dropbox
2. Download on device

**Option C: USB Transfer**
1. Connect device as USB storage
2. Copy APK to device
3. Disconnect

#### Step 2: Install Manually

1. On device, open **Files** or **Downloads**
2. Navigate to APK location
3. Tap **app-debug.apk**
4. If prompted "Install from unknown sources":
   - Click **Settings**
   - Enable "Allow from this source"
   - Go back and tap APK again
5. Click **Install**
6. Click **Open** when complete

---

### Method 5: Deploy via SOTI MobiControl (For Fleet Deployment)

**For deploying to multiple CK65 devices:**

1. **Build Release APK** (see above)
2. **Log in to SOTI MobiControl** web console
3. **Upload Application:**
   - Go to **Apps** → **Add Application**
   - Upload `app-release.apk`
   - Name: "O2 Scanner v1.0"
4. **Deploy to Device Group:**
   - Select **Device Groups** → "CK65 Warehouse"
   - Click **Assign Apps**
   - Select "O2 Scanner v1.0"
   - Click **Deploy**
5. **Monitor Installation:**
   - View deployment status
   - Check installed count

**Devices will auto-install** the app over WiFi.

---

## Troubleshooting

### Build Errors

#### Error: "SDK not found"

**Solution:**
1. Click **Tools** → **SDK Manager**
2. Install **Android 14 (API 34)**
3. Click **File** → **Sync Project with Gradle Files**

#### Error: "Kotlin version mismatch"

**Solution:**
1. Open `app/build.gradle.kts`
2. Add dependency resolution:
   ```kotlin
   configurations.all {
       resolutionStrategy {
           force("org.jetbrains.kotlin:kotlin-stdlib:1.9.20")
       }
   }
   ```
3. Sync Gradle

#### Error: "BuildConfig not found"

**Solution:**
1. Open `app/build.gradle.kts`
2. Add to `android { buildFeatures { ... } }`:
   ```kotlin
   buildConfig = true
   ```
3. Sync Gradle

---

### Installation Errors

#### Error: "INSTALL_FAILED_UPDATE_INCOMPATIBLE"

**Cause:** Previous version with different signature

**Solution:**
```bash
# Uninstall old version
adb uninstall com.o2.scanner

# Install new version
adb install app/build/outputs/apk/debug/app-debug.apk
```

#### Error: "App not installed"

**Cause:** Insufficient storage or corrupted APK

**Solution:**
1. Check device storage (need 50MB free)
2. Rebuild APK:
   ```bash
   ./gradlew clean assembleDebug
   ```
3. Try installing again

#### Error: "Unknown sources blocked"

**Cause:** Installation from unknown sources disabled

**Solution:**
1. **Settings** → **Security**
2. Enable **Unknown Sources**
3. Try installing again

---

### Runtime Errors

#### App crashes on launch

**Check logs:**
```bash
adb logcat | grep -i "o2scanner\|crash\|exception"
```

**Common causes:**
1. Missing camera permission (grant in Settings → Apps)
2. OpenTelemetry initialization failure (check API token)
3. Missing dependencies (rebuild with `./gradlew clean assembleDebug`)

#### No telemetry data in OpenObserve

**Check:**
1. **API token configured?**
   - Verify `ScannerApplication.kt` line 51
2. **Internet connection?**
   ```bash
   adb shell ping -c 3 introspection.dev.zinclabs.dev
   ```
3. **Check logs:**
   ```bash
   adb logcat | grep -i "opentelemetry"
   ```
   Should see: "OpenTelemetry initialized - sending data to OpenObserve"

#### Camera not working

**Check:**
1. **Permission granted?**
   - Settings → Apps → O2 Scanner → Permissions → Camera
2. **Camera hardware available?**
   ```bash
   adb shell dumpsys media.camera
   ```
3. **Another app using camera?**
   - Close other camera apps

---

## Advanced Configuration

### Build Variants for Different Environments

**File:** `app/build.gradle.kts`

```kotlin
android {
    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-DEBUG"
            buildConfigField("String", "OTEL_ENDPOINT", "\"http://10.0.2.2:4318\"")
        }

        create("staging") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-STAGING"
            buildConfigField("String", "OTEL_ENDPOINT", "\"https://staging.yourserver.com\"")
        }

        release {
            isMinifyEnabled = true
            buildConfigField("String", "OTEL_ENDPOINT", "\"https://introspection.dev.zinclabs.dev/api/default\"")
        }
    }
}
```

**Build specific variant:**
```bash
./gradlew assembleStaging
```

---

### Enable ProGuard for Release

**File:** `app/build.gradle.kts`

```kotlin
buildTypes {
    release {
        isMinifyEnabled = true
        isShrinkResources = true
        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )
    }
}
```

**File:** `app/proguard-rules.pro`

```proguard
# Keep OpenTelemetry classes
-keep class io.opentelemetry.** { *; }
-dontwarn io.opentelemetry.**

# Keep Application class
-keep public class * extends android.app.Application

# Keep ML Kit
-keep class com.google.mlkit.** { *; }
```

---

### Custom APK Name

**File:** `app/build.gradle.kts`

```kotlin
android {
    applicationVariants.all { variant ->
        variant.outputs.all {
            outputFileName = "O2Scanner-${variant.name}-${variant.versionName}.apk"
        }
    }
}
```

**Result:**
- `O2Scanner-debug-1.0.0.apk`
- `O2Scanner-release-1.0.0.apk`

---

## Build Commands Reference

| Command | Description | Output |
|---------|-------------|--------|
| `./gradlew clean` | Clean build cache | Deletes `build/` folders |
| `./gradlew assembleDebug` | Build debug APK | `app/build/outputs/apk/debug/` |
| `./gradlew assembleRelease` | Build release APK | `app/build/outputs/apk/release/` |
| `./gradlew installDebug` | Build + install debug | Installs on connected device |
| `./gradlew installRelease` | Build + install release | Installs on connected device |
| `./gradlew bundleRelease` | Build Android App Bundle | `app/build/outputs/bundle/` |

---

## Testing the Build

### Verify Installation

```bash
# Check if app is installed
adb shell pm list packages | grep o2.scanner

# Expected output:
# package:com.o2.scanner
```

### Launch and Test

```bash
# Launch app
adb shell am start -n com.o2.scanner/.MainActivity

# Grant camera permission (if needed)
adb shell pm grant com.o2.scanner android.permission.CAMERA

# View logs
adb logcat -c  # Clear logs
adb logcat | grep -i "o2scanner\|opentelemetry"
```

### Test Telemetry

1. **Launch app** on device
2. **Scan a QR code**
3. **Check logs:**
   ```bash
   adb logcat | grep "Scan tracked"
   ```
   Should see: "Scan tracked: format=QR Code, duration=847ms"
4. **Check OpenObserve** dashboard after 30 seconds

---

## Next Steps

After successful installation:

1. **View Monitoring Data**
   - Open https://introspection.dev.zinclabs.dev
   - Filter by stream: `o2scanner`
   - See scan events in real-time

2. **Deploy to Fleet**
   - Use SOTI MobiControl for mass deployment
   - See [Method 5](#method-5-deploy-via-soti-mobicontrol-for-fleet-deployment)

3. **Customize Tracking**
   - See [MONITORING.md](MONITORING.md) for custom events
   - Add business-specific tracking

4. **Create Dashboards**
   - Set up OpenObserve dashboards
   - Monitor device fleet health

---

## Summary

### Quick Build & Install (30 seconds)

```bash
# From project directory
cd /Users/mdmosaraf/Documents/work/monitroing/o2Scanner

# Build
./gradlew assembleDebug

# Install
adb install app/build/outputs/apk/debug/app-debug.apk

# Launch
adb shell am start -n com.o2.scanner/.MainActivity
```

### Build Checklist

- ✅ Android Studio installed
- ✅ Project opened and synced
- ✅ API token configured in `ScannerApplication.kt`
- ✅ Build variant selected (debug/release)
- ✅ APK built successfully
- ✅ Device connected (USB debugging enabled)
- ✅ App installed
- ✅ App launches without crashes
- ✅ Camera permission granted
- ✅ Telemetry data appearing in OpenObserve

---

**Build Time:** ~2 minutes (first build), ~30 seconds (subsequent builds)
**APK Size:** ~29 MB (debug), ~15 MB (release with ProGuard)

**Questions?** See [README.md](README.md) for documentation links.
