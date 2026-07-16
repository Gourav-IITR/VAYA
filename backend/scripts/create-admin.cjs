const admin = require('firebase-admin');
const serviceAccount = require('../serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

async function makeAdmin(email, password) {
  try {
    const user = await admin.auth().createUser({
      email: email,
      password: password,
      emailVerified: true,
    });
    
    await admin.auth().setCustomUserClaims(user.uid, { role: 'admin' });
    console.log(`Successfully created admin user: ${email}`);
  } catch (error) {
    console.error('Failed to create admin user:', error);
  }
}

makeAdmin('admin@goodsdelivery.com', 'SecureAdminPassword123');
