# Google Play Store Compliance & Publishing Checklist

This document details the configuration requirements to publish both VAYA Customer and VAYA Driver Flutter applications to the Google Play Store, fully compliant with modern Android API requirements.

---

## 1. SDK Target & Build Optimization (API Level 35)
To publish on Google Play, applications must target Android SDK 35+.

Ensure the following configuration in both `customer_app/android/app/build.gradle` and `driver_app/android/app/build.gradle`:

```groovy
android {
    compileSdkVersion 35

    defaultConfig {
        applicationId "com.vaya.customer_app" // com.vaya.driver_app
        minSdkVersion 23
        targetSdkVersion 35
        versionCode 1
        versionName "1.0.0"
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
            minifyEnabled true // Shrinks classes and code sizing
            shrinkResources true // Shrinks unused assets
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}
```

---

## 2. Background Location Declaration (Driver App)
The driver app tracks vehicle positions even when minimized. Google Play enforces strict rules for background location access.

### Requirements
1. **AndroidManifest.xml Configuration**:
   Declare permissions in `driver_app/android/app/src/main/AndroidManifest.xml`:
   ```xml
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
   <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
   ```
2. **Foreground Service Type**:
   Associate the service with `location` inside the `<application>` tag:
   ```xml
   <service
       android:name="com.pravera.flutter_foreground_task.models.ForegroundService"
       android:foregroundServiceType="location"
       android:exported="false" />
   ```

3. **In-App Prominent Disclosure**:
   Before requesting location permission, you **MUST** show a modal/screen explaining:
   - *Why* the app is tracking location ("to match you with nearby cargo requests and display your route to the customer").
   - *When* it tracks location ("even when the app is closed or not in use").
   - **Important**: The user must click "Accept" or "Acknowledge" before the system dialog is shown.

---

## 3. Privacy Policy Requirement
Google Play requires a public link to your application's Privacy Policy. 
- You should generate a privacy policy (see `docs/privacy-policy.md`).
- Deploy this policy to Firebase Hosting alongside your admin portal (e.g. host it at `/privacy.html` or `/privacy-policy`).
- Paste the public URL into the **App Content** page in the Google Play Console.

---

## 4. Release Signing Configuration
To compile the release bundle:
1. Generate an upload keystore file:
   ```bash
   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Place `upload-keystore.jks` inside `android/app/` folder.
3. Configure `android/key.properties`:
   ```properties
   storePassword=your-keystore-password
   keyPassword=your-key-password
   keyAlias=upload
   storeFile=upload-keystore.jks
   ```
4. Build the Android App Bundle (AAB):
   ```bash
   flutter build appbundle --release
   ```
