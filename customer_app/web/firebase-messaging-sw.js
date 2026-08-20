importScripts("https://www.gstatic.com/firebasejs/10.7.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.7.0/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyCYn1asbIsltGhURbsjFKmosrS_2P1WUdc",
  authDomain: "goods-delivery-platform.firebaseapp.com",
  projectId: "goods-delivery-platform",
  storageBucket: "goods-delivery-platform.firebasestorage.app",
  messagingSenderId: "275777907648",
  appId: "1:275777907648:web:d7962496a75c7981527625"
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Background message received: ', payload);
});
