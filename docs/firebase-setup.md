# Firebase Setup Guide

Follow these steps to configure Firebase services for Phone Authentication, Email/Password Authentication, Cloud Messaging, and Custom Roles.

---

## 1. Firebase Project Creation
1. Go to the [Firebase Console](https://console.firebase.google.com/).
2. Click **Add Project** and name it `goods-delivery-platform` (or your preferred name).
3. Choose whether to enable Google Analytics (recommended but optional).
4. Click **Create Project**.

---

## 2. Authentication Setup
Our architecture relies on two authentication methods:
- **Phone Authentication** (for Customers & Driver Partners)
- **Email/Password Authentication** (for Dashboard Administrators)

### Enable Sign-in Providers
1. In the left-hand sidebar, navigate to **Build** → **Authentication**.
2. Click **Get Started** if you haven't initialized it.
3. Go to the **Sign-in method** tab.
4. Enable **Phone**:
   - Turn on the toggle.
   - For development, you can add phone numbers for testing (e.g. `+919999999999` with code `123456`) under **Phone numbers for testing** to avoid hitting SMS quota limits.
5. Enable **Email/Password**:
   - Click **Add new provider** → **Email/Password** and turn on the toggle.

---

## 3. Create Admin Users & Set Custom Claims
Since admins require the `role: 'admin'` custom claim on their Firebase ID token, you must provision them.

### Option A: Create Admin Script
Create a quick administrative script in your backend workspace:
```javascript
// scripts/create-admin.js
const admin = require('firebase-admin');
const serviceAccount = require('../backend/serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

async function makeAdmin(email, password) {
  const user = await admin.auth().createUser({
    email: email,
    password: password,
    emailVerified: true,
  });
  
  await admin.auth().setCustomUserClaims(user.uid, { role: 'admin' });
  console.log(`Successfully created admin user: ${email}`);
}

makeAdmin('admin@goodsdelivery.com', 'SecureAdminPassword123');
```

---

## 4. Firebase Cloud Messaging (FCM)
For pushing cargo alerts and job matching notifications:
1. In Firebase Console, click the Gear icon ⚙️ next to **Project Overview** and select **Project settings**.
2. Go to the **Cloud Messaging** tab.
3. Under **Firebase Cloud Messaging API (V1)**, copy your **Sender ID**.
4. Generate private key: Go to **Service accounts** tab, click **Generate new private key**, and download the JSON credentials file. Rename it to `serviceAccountKey.json` and place it in `backend/` config folder.

---

## 5. Web App & Android App Registrations
### Web App (for Admin Portal)
1. In **Project settings** → **General**, scroll down to **Your apps** and click the Web icon `</>`.
2. Register the app as `Admin Dashboard`.
3. Copy the configuration object and add it as environment variables to `web_portal/.env`:
   ```env
   VITE_FIREBASE_API_KEY=your-api-key
   VITE_FIREBASE_AUTH_DOMAIN=your-auth-domain
   VITE_FIREBASE_PROJECT_ID=your-project-id
   VITE_FIREBASE_STORAGE_BUCKET=your-storage-bucket
   VITE_FIREBASE_MESSAGING_SENDER_ID=your-sender-id
   VITE_FIREBASE_APP_ID=your-app-id
   ```

### Android Apps (Customer & Driver)
1. Click **Add app** → Android icon.
2. Register two separate app packages matching your Flutter files:
   - Customer app: `com.example.customer_app` (or yours)
   - Driver app: `com.example.driver_app` (or yours)
3. Download `google-services.json` for each and place them in:
   - `customer_app/android/app/google-services.json`
   - `driver_app/android/app/google-services.json`
