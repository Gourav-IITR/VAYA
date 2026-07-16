import { initializeApp, cert, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getMessaging } from 'firebase-admin/messaging';
import fs from 'fs';
import path from 'path';

let adminApp = null;
let auth = null;
let messaging = null;

try {
  let credential;
  const credPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  
  if (credPath && fs.existsSync(path.resolve(credPath))) {
    const keyPath = path.resolve(credPath);
    const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
    credential = cert(serviceAccount);
    console.log('🔑 Firebase Admin: Using service account key from GOOGLE_APPLICATION_CREDENTIALS');
  } else {
    credential = applicationDefault();
    console.log('🔑 Firebase Admin: Using Application Default Credentials');
  }

  adminApp = initializeApp({
    credential,
    ...(process.env.FIREBASE_PROJECT_ID ? { projectId: process.env.FIREBASE_PROJECT_ID } : {})
  });

  auth = getAuth(adminApp);
  messaging = getMessaging(adminApp);
  console.log('✅ Firebase Admin SDK initialized successfully.');
} catch (err) {
  console.error('❌ Failed to initialize Firebase Admin SDK:', err.message);
  process.exit(1);
}

export { auth, messaging };
