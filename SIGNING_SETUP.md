# Android App Signing Setup

## Step 1: Generate Upload Keystore

Run this in your terminal (only once — keep the `.jks` file safe):

```bash
keytool -genkey -v \
  -keystore ~/upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

You will be prompted for a store password and key password.

## Step 2: Fill in key.properties

Edit BOTH files:
- `customer_app/android/key.properties`  
- `partner_app/android/key.properties`

Replace placeholder values with your actual passwords:
```properties
storePassword=YOUR_ACTUAL_PASSWORD
keyPassword=YOUR_ACTUAL_PASSWORD
keyAlias=upload
storeFile=/Users/gouravmahunta/upload-keystore.jks
```

## Step 3: Add Google Maps API Key

Configure your Google Maps API key in:
- `customer_app/android/local.properties` (under `GOOGLE_MAPS_API_KEY`)
- `partner_app/android/local.properties` (under `GOOGLE_MAPS_API_KEY`)

> [!WARNING]
> If a real Google Maps API key was previously committed, ensure it has been rotated in Google Cloud Console, restricted by package name + SHA-1 fingerprint, and capped with billing quotas.

If you ever need to change the key in the future, modify `GOOGLE_MAPS_API_KEY` in these files or within `key.properties`.

## Step 4: Add google-services.json

Download `google-services.json` from your Firebase Console project and place it in the respective folders:
- `customer_app/android/app/google-services.json`
- `partner_app/android/app/google-services.json`

## Step 5: Build Release AAB

Run these commands to generate the release signed app bundle for deployment to the Google Play Store:

```bash
# Customer App
cd customer_app
flutter build appbundle --release
# Output will be generated at: build/app/outputs/bundle/release/app-release.aab

# Partner App
cd ../partner_app  
flutter build appbundle --release
# Output will be generated at: build/app/outputs/bundle/release/app-release.aab
```

## Security Checklist
- [x] `key.properties` is in `.gitignore`
- [x] `upload-keystore.jks` is stored outside the repository
- [x] `google-services.json` is added to `.gitignore`
- [x] API keys are restricted in Google Cloud Console
