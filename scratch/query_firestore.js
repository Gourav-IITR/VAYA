import { initializeApp, cert } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'fs';
import path from 'path';

const keyPath = path.resolve('../backend/serviceAccountKey.json');
const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));

const app = initializeApp({
  credential: cert(serviceAccount),
  projectId: 'goodsdeliveryapp-bcf5f'
});

const db = getFirestore(app);

async function testQuery() {
  console.log('Querying Firestore...');
  const driversSnap = await db.collection('drivers').get();
  console.log(`Found ${driversSnap.size} drivers in Firestore:`);
  driversSnap.forEach(doc => {
    console.log(` - ID: ${doc.id}, Name: ${doc.data().name}, Status: ${doc.data().status}`);
  });

  const bookingsSnap = await db.collection('bookings').get();
  console.log(`Found ${bookingsSnap.size} bookings in Firestore.`);
}

testQuery().catch(console.error);
