# How to Build and Deploy O2 Scanner

## Quick Start

### 1. Open in Android Studio

```bash
# Open Android Studio
# File → Open → Select: /Users/mdmosaraf/Documents/work/monitroing/o2Scanner
```

### 2. Sync Gradle

Android Studio will automatically detect the project and sync Gradle dependencies.

If not automatic:
- Click "Sync Project with Gradle Files" button (elephant icon in toolbar)

### 3. Build the App

**Option A: Using Android Studio**
1. Build → Make Project (⌘F9 / Ctrl+F9)
2. Build → Build Bundle(s) / APK(s) → Build APK(s)

**Option B: Using Command Line**
```bash
cd /Users/mdmosaraf/Documents/work/monitroing/o2Scanner

# Build debug APK
./gradlew assembleDebug

# Build release APK
./gradlew assembleRelease
```

### 4. Install on Device

**Via Android Studio:**
1. Connect device via USB
2. Enable USB debugging on device
3. Click Run button (▶) or press Shift+F10

**Via ADB:**
```bash
# Find devices
adb devices

# Install debug APK
adb install app/build/outputs/apk/debug/app-debug.apk

# Or install release APK
adb install app/build/outputs/apk/release/app-release.apk
```

---

## Deploy to Honeywell CK65

### Method 1: Direct USB Installation

```bash
# Connect CK65 via USB
adb devices

# Install
adb install app/build/outputs/apk/release/app-release.apk

# Launch app
adb shell am start -n com.o2.scanner/.MainActivity
```

### Method 2: SOTI MobiControl Deployment

**Step 1: Build Release APK**
```bash
./gradlew assembleRelease
```

**Step 2: Upload to SOTI**
1. Login to SOTI web console: https://your-company.soti.net
2. Navigate to: Applications → Upload Application
3. Click "Add Application"
4. Select: `app/build/outputs/apk/release/app-release.apk`
5. Fill in details:
   - Name: O2 Scanner
   - Version: 1.0.0
   - Category: Business Tools

**Step 3: Deploy to Devices**
1. Select CK65 device group
2. Right-click → Install Application
3. Choose "O2 Scanner"
4. Click "Install Now"

**Step 4: Monitor Deployment**
- View real-time deployment status in SOTI dashboard
- Verify installation on devices

---

## Troubleshooting

### Gradle Sync Failed

**Solution:**
```bash
# Clean project
./gradlew clean

# Rebuild
./gradlew build --refresh-dependencies
```

### Build Failed - SDK Not Found

**Solution:**
1. Open Android Studio
2. Tools → SDK Manager
3. Install:
   - Android SDK Platform 34
   - Android SDK Build-Tools
   - Android SDK Command-line Tools

### Camera Permission Denied

**Solution:**
- Settings → Apps → O2 Scanner → Permissions → Enable Camera

### App Crashes on CK65

**Check:**
```bash
# View logs
adb logcat | grep O2Scanner
```

---

## Build Variants

### Debug Build (for testing)
```bash
./gradlew assembleDebug
```
- Includes debug information
- Larger APK size
- Not optimized
- Use for: Testing, development

### Release Build (for production)
```bash
./gradlew assembleRelease
```
- Optimized and minified
- Smaller APK size
- ProGuard enabled
- Use for: Production deployment via SOTI

---

## Project Structure

```
o2Scanner/
├── app/
│   ├── src/main/
│   │   ├── java/com/o2/scanner/
│   │   │   ├── MainActivity.kt              # Scanner screen
│   │   │   ├── ScanResultActivity.kt        # Results screen
│   │   │   └── ScanOverlayView.kt           # Scan overlay
│   │   ├── res/
│   │   │   ├── layout/                      # UI layouts
│   │   │   ├── drawable/                    # Icons
│   │   │   └── values/                      # Strings, colors
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts                     # App dependencies
├── build.gradle.kts                          # Project config
├── settings.gradle.kts                       # Project settings
└── gradle/                                   # Gradle wrapper
```

---

## APK Locations

After building, APKs are located at:

**Debug:**
```
app/build/outputs/apk/debug/app-debug.apk
```

**Release:**
```
app/build/outputs/apk/release/app-release.apk
```

---

## Testing on Emulator

1. **Create Emulator:**
   - Tools → Device Manager
   - Create Virtual Device
   - Select: Pixel 6 (or any device)
   - System Image: API 34 (Android 14)

2. **Run on Emulator:**
   - Click Run (▶)
   - Select emulator
   - Grant camera permission when prompted

**Note:** Emulator camera shows test patterns, not real camera feed.

---

## Signing the APK (for production)

### Create Keystore

```bash
keytool -genkey -v -keystore o2scanner.keystore \
  -alias o2scanner -keyalg RSA -keysize 2048 -validity 10000
```

### Update build.gradle.kts

```kotlin
android {
    signingConfigs {
        create("release") {
            storeFile = file("../o2scanner.keystore")
            storePassword = "your-password"
            keyAlias = "o2scanner"
            keyPassword = "your-password"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

### Build Signed APK

```bash
./gradlew assembleRelease
```

---

## Next Steps

1. ✅ **Build the app** - Follow steps above
2. ✅ **Test on one device** - Verify camera scanning works
3. ✅ **Deploy to CK65 fleet** - Use SOTI MobiControl
4. 📱 **Add monitoring** - Follow ../android/INTEGRATION_GUIDE.md
5. 📊 **Track usage** - Integrate OpenTelemetry

---

## Support

**Build Issues:**
- Check Android Studio version (2023.1.1+)
- Verify JDK 11+ installed
- Sync Gradle files

**Runtime Issues:**
- View logcat: `adb logcat | grep O2Scanner`
- Check camera permission granted
- Verify device has working camera

**Deployment Issues:**
- Ensure SOTI credentials correct
- Check device connectivity
- Verify APK not corrupted
