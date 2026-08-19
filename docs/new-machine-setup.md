# 🖥️ New Machine Setup — Complete Onboarding Checklist

This guide walks you through setting up the VAYA development environment from scratch on a brand-new machine. Follow every step in order.

---

## Prerequisites Checklist

| Tool | Version | Install Command / Link |
|------|---------|----------------------|
| **Git** | ≥2.x | `xcode-select --install` (macOS) |
| **Node.js** | ≥20.x | [nodejs.org](https://nodejs.org) or `nvm install 20` |
| **Flutter SDK** | ≥3.4.0 | [flutter.dev/get-started](https://docs.flutter.dev/get-started/install) |
| **Android Studio** | Latest | [developer.android.com/studio](https://developer.android.com/studio) |
| **Java JDK** | 17+ | `brew install openjdk@17` (macOS) |
| **Google Cloud CLI** | Latest | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| **Firebase CLI** | Latest | `npm install -g firebase-tools` |
| **Cocoapods** | Latest | `sudo gem install cocoapods` (if building iOS) |

---

## Step 1: Clone the Repository

```bash
git clone git@github.com:Gourav-IITR/VAYA.git
cd VAYA
```

> If you don't have SSH keys set up, use HTTPS instead:
> ```bash
> git clone https://github.com/Gourav-IITR/VAYA.git
> ```

---

## Step 2: Verify Flutter Installation

```bash
flutter doctor -v
```

Ensure these pass:
- ✅ Flutter (≥3.4.0)
- ✅ Android toolchain (SDK 36)
- ✅ Android Studio
- ✅ Connected device or emulator

If Android licenses need accepting:
```bash
flutter doctor --android-licenses
```

---

## Step 3: Backend Setup

```bash
cd backend
npm install
```

### Create `backend/.env`
```env
DATABASE_URL=postgresql://neondb_owner:<PASSWORD>@ep-snowy-block-az79j9ia.c-3.ap-southeast-1.aws.neon.tech/neondb?sslmode=require
PORT=5001
```

### Add Firebase Service Account
1. Go to [Firebase Console](https://console.firebase.google.com/) → Project Settings → Service Accounts
2. Click **Generate New Private Key**
3. Save as `backend/serviceAccountKey.json`

### Test Backend Locally
```bash
node server.js
# Should print:
# ✅ Connected to PostgreSQL database successfully.
# ✅ Database schema tables verified/created successfully.
# 🚀 GoodsDelivery backend running on http://localhost:5001
```

```bash
# Health check
curl http://localhost:5001/api/health
```

---

## Step 4: Customer App Setup

```bash
cd customer_app
flutter pub get
```

### Add Firebase Config
1. Go to Firebase Console → Project Settings → Your Apps → Android
2. Download `google-services.json` for package `com.vaya.customer_app`
3. Place it at: `customer_app/android/app/google-services.json`

### Add Signing Config
Create `customer_app/android/key.properties`:
```properties
storePassword=YOUR_KEYSTORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=/path/to/your/upload-keystore.jks
```

### Add Google Maps API Key
Create or edit `customer_app/android/local.properties`:
```properties
sdk.dir=/path/to/Android/sdk
flutter.sdk=/path/to/flutter
GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_MAPS_API_KEY
```

### Run Customer App
```bash
flutter run
```

---

## Step 5: Partner App Setup

```bash
cd partner_app
flutter pub get
```

### Add Firebase Config
1. Download `google-services.json` for package `com.vaya.partner_app`
2. Place it at: `partner_app/android/app/google-services.json`

### Add Signing Config
Create `partner_app/android/key.properties`:
```properties
storePassword=YOUR_KEYSTORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=/path/to/your/upload-keystore.jks
```

### Add Google Maps API Key
Create or edit `partner_app/android/local.properties`:
```properties
sdk.dir=/path/to/Android/sdk
flutter.sdk=/path/to/flutter
GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_MAPS_API_KEY
```

### Run Driver App
```bash
flutter run
```

---

## Step 6: Admin Dashboard Setup

```bash
cd web_portal
npm install
```

### Create `web_portal/.env`
```env
VITE_FIREBASE_API_KEY=your-firebase-api-key
VITE_FIREBASE_AUTH_DOMAIN=goods-delivery-platform.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=goods-delivery-platform
VITE_FIREBASE_STORAGE_BUCKET=goods-delivery-platform.firebasestorage.app
VITE_FIREBASE_MESSAGING_SENDER_ID=275777907648
VITE_FIREBASE_APP_ID=your-firebase-app-id
VITE_GOOGLE_MAPS_API_KEY=your-google-maps-key
```

### Run Admin Dashboard
```bash
npm run dev
# Opens at http://localhost:5173
```

---

## Step 7: Public Website Setup

```bash
cd public_website
npm install
cp ../web_portal/.env .env   # Same Firebase credentials
npm run dev
# Opens at http://localhost:5174
```

---

## Step 8: Google Cloud & Firebase Auth

```bash
# Authenticate with Google Cloud
gcloud auth login
gcloud config set project goods-delivery-platform

# Authenticate with Firebase
firebase login

# Verify project
firebase projects:list
```

---

## Step 9: Generate Upload Keystore (If Not Already Have One)

> ⚠️ Only do this once. Keep the `.jks` file safe — you need the same keystore for all future Play Store updates.

```bash
keytool -genkey -v \
  -keystore ~/upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

---

## Step 10: Create Deployment Config

Create `.env.deploy` at the project root:
```env
PROJECT_ID=goods-delivery-platform
DATABASE_URL=postgresql://neondb_owner:<PASSWORD>@ep-snowy-block-az79j9ia.c-3.ap-southeast-1.aws.neon.tech/neondb?sslmode=require
FB_API_KEY=your-firebase-api-key
FB_AUTH_DOMAIN=goods-delivery-platform.firebaseapp.com
FB_STORAGE_BUCKET=goods-delivery-platform.firebasestorage.app
FB_SENDER_ID=275777907648
FB_APP_ID=your-firebase-app-id
GM_API_KEY=your-google-maps-api-key
```

---

## Files You Need From Your Old Machine

These files are **git-ignored** (secrets) and must be manually transferred:

| File | Location | How to Get |
|------|----------|-----------|
| `serviceAccountKey.json` | `backend/` | Firebase Console → Service Accounts |
| `google-services.json` | `customer_app/android/app/` | Firebase Console → Android App |
| `google-services.json` | `partner_app/android/app/` | Firebase Console → Android App |
| `key.properties` | `customer_app/android/` | Create manually (see Step 4) |
| `key.properties` | `partner_app/android/` | Create manually (see Step 5) |
| `upload-keystore.jks` | `~/` | Copy from old machine or generate new |
| `.env` | `backend/` | Create manually (see Step 3) |
| `.env` | `web_portal/` | Create manually (see Step 6) |
| `.env` | `public_website/` | Create manually (see Step 7) |
| `.env.deploy` | Project root | Create manually (see Step 10) |

---

## Quick Verification Checklist

After setup, verify everything works:

- [ ] `node backend/server.js` — Backend starts without errors
- [ ] `curl http://localhost:5001/api/health` — Returns `200 OK`
- [ ] `cd customer_app && flutter run` — App launches on device/emulator
- [ ] `cd partner_app && flutter run` — App launches on device/emulator
- [ ] `cd web_portal && npm run dev` — Dashboard opens in browser
- [ ] `cd public_website && npm run dev` — Public site opens in browser

---

## Useful Commands Reference

```bash
# Build release APKs
cd customer_app && flutter build apk --release
cd partner_app && flutter build apk --release

# Build release AABs (Play Store)
cd customer_app && flutter build appbundle --release
cd partner_app && flutter build appbundle --release

# Deploy everything to production
./deploy.sh

# Deploy only web to Firebase Hosting
cd web_portal && npm run build && cd ..
cd public_website && npm run build && cd ..
npx firebase-tools deploy --only hosting --project goods-delivery-platform

# Run backend locally
cd backend && node server.js

# Check database connection
cd backend && node -e "import('./src/config/db.js').then(m => m.initDb())"
```

---

## Troubleshooting

### "SDK not found" in Flutter
```bash
flutter config --android-sdk /path/to/Android/sdk
```

### Gradle build fails
```bash
cd customer_app/android && ./gradlew clean
cd partner_app/android && ./gradlew clean
```

### Neon DB connection timeout
The Neon serverless Postgres compute can take up to 30s to wake from sleep. The backend has a 30s connection timeout configured. If you get timeouts, simply retry — the compute wakes on first connection attempt.

### Firebase Auth not working in Flutter
Ensure `google-services.json` is placed correctly and the SHA-1/SHA-256 fingerprints of your signing key are registered in Firebase Console → Project Settings → Android app.

```bash
# Get your debug signing fingerprint
keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android

# Get your release signing fingerprint
keytool -list -v -alias upload -keystore ~/upload-keystore.jks
```
