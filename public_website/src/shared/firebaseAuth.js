import { initializeApp, getApps, getApp } from 'firebase/app';
import {
  getAuth,
  RecaptchaVerifier,
  signInWithPhoneNumber,
  signInWithEmailAndPassword,
  signOut,
  onAuthStateChanged
} from 'firebase/auth';

const firebaseConfig = {
  apiKey:            import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain:        import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId:         import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket:     import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId:             import.meta.env.VITE_FIREBASE_APP_ID,
  measurementId:     import.meta.env.VITE_FIREBASE_MEASUREMENT_ID,
};

export const FIREBASE_CONFIGURED = !!(
  firebaseConfig.apiKey &&
  firebaseConfig.authDomain &&
  firebaseConfig.projectId &&
  firebaseConfig.appId
);

let app = null;
let auth = null;

function getFirebaseAuth() {
  if (!FIREBASE_CONFIGURED) return null;
  if (!app) {
    app = getApps().length ? getApp() : initializeApp(firebaseConfig);
    auth = getAuth(app);
  }
  return auth;
}

export const getAuthInstance = getFirebaseAuth;

let recaptchaVerifier = null;

export function initRecaptcha(containerId = 'recaptcha-container') {
  const firebaseAuth = getFirebaseAuth();
  if (!firebaseAuth) return;

  cleanupRecaptcha();

  recaptchaVerifier = new RecaptchaVerifier(firebaseAuth, containerId, {
    size: 'invisible',
    callback: () => {},
    'expired-callback': () => {
      console.warn('[firebaseAuth] reCAPTCHA expired — resetting');
      cleanupRecaptcha();
    },
    'error-callback': (err) => {
      console.error('[firebaseAuth] reCAPTCHA error:', err);
      cleanupRecaptcha();
    }
  });

  recaptchaVerifier.render().catch((err) => {
    console.warn('[firebaseAuth] reCAPTCHA render error:', err);
  });
}

export function cleanupRecaptcha() {
  if (recaptchaVerifier) {
    try {
      recaptchaVerifier.clear();
    } catch (e) {
      // Ignored
    }
    recaptchaVerifier = null;
  }
  if (typeof window !== 'undefined' && window.grecaptcha) {
    try {
      window.grecaptcha.reset();
    } catch (e) {
      // Ignored
    }
  }
}

export async function sendOtp(phoneWithCountryCode, containerId = 'recaptcha-container') {
  const firebaseAuth = getFirebaseAuth();
  if (!firebaseAuth) {
    throw new Error('Firebase is not initialized/configured.');
  }

  if (!recaptchaVerifier) {
    initRecaptcha(containerId);
  }

  try {
    const confirmationResult = await signInWithPhoneNumber(
      firebaseAuth,
      phoneWithCountryCode,
      recaptchaVerifier
    );
    recaptchaVerifier = null;
    return { demo: false, confirmationResult };
  } catch (err) {
    cleanupRecaptcha();
    throw new Error(friendlyError(err));
  }
}

export async function verifyOtp(confirmationResult, code) {
  if (!confirmationResult) throw new Error('No confirmation result found. Please request OTP again.');
  try {
    return await confirmationResult.confirm(code);
  } catch (err) {
    throw new Error(friendlyError(err));
  }
}

export async function loginWithEmail(email, password) {
  const firebaseAuth = getFirebaseAuth();
  if (!firebaseAuth) throw new Error('Firebase is not configured.');
  try {
    const userCredential = await signInWithEmailAndPassword(firebaseAuth, email, password);
    return userCredential.user;
  } catch (err) {
    throw new Error(friendlyError(err));
  }
}

export async function logoutAdmin() {
  const firebaseAuth = getFirebaseAuth();
  if (!firebaseAuth) return;
  await signOut(firebaseAuth);
}

export function onAuthChange(callback) {
  const firebaseAuth = getFirebaseAuth();
  if (!firebaseAuth) return () => {};
  return onAuthStateChanged(firebaseAuth, callback);
}

function friendlyError(err) {
  const code = err?.code || '';
  const msg  = err?.message || '';

  if (code === 'auth/invalid-phone-number')
    return 'Invalid phone number. Make sure to include country code (+91).';
  if (code === 'auth/too-many-requests')
    return 'Too many attempts. Please wait a few minutes and try again.';
  if (code === 'auth/captcha-check-failed' || msg.includes('reCAPTCHA'))
    return 'reCAPTCHA verification failed. Please try again.';
  if (code === 'auth/invalid-verification-code' || code === 'auth/code-expired')
    return 'Incorrect or expired OTP. Please check the code and try again.';
  if (msg.includes('OPERATION_NOT_ALLOWED'))
    return 'Phone auth is not enabled. Please enable it in Firebase Console → Authentication → Sign-in method.';
  if (msg.includes('SMS unable to be sent'))
    return 'This phone region is not enabled. Please enable India (+91) in Firebase Console → Phone Auth settings.';
  if (msg.includes('BILLING_NOT_ENABLED'))
    return 'Billing is not enabled on this Firebase project. To send real SMS, link a Google Cloud billing account (Blaze plan) in the Firebase Console. Alternatively, use a whitelisted Test Phone Number during development.';

  console.error('[firebaseAuth]', err);
  return err?.message || 'Something went wrong. Please try again.';
}
