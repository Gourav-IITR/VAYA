import { messaging } from '../config/firebase.js';
import { query } from '../config/db.js';

export const sendNotificationToUser = async (userId, title, body, data = {}) => {
  try {
    let token = null;
    
    // Check drivers table first
    const driverRes = await query('SELECT fcm_token FROM drivers WHERE id = $1', [userId]);
    if (driverRes.rows.length > 0) {
      token = driverRes.rows[0].fcm_token;
    } else {
      const customerRes = await query('SELECT fcm_token FROM customers WHERE id = $1', [userId]);
      if (customerRes.rows.length > 0) {
        token = customerRes.rows[0].fcm_token;
      }
    }

    if (!token) {
      console.warn(`⚠️ FCM: No FCM token registered for user: ${userId}`);
      return false;
    }

    const message = {
      notification: { title, body },
      data: {
        ...data,
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      },
      token
    };

    const response = await messaging.send(message);
    console.log(`✉️ FCM: Notification sent to ${userId} successfully. ID: ${response}`);
    return true;
  } catch (err) {
    console.error(`❌ FCM: Failed to send notification to user ${userId}:`, err.message);
    return false;
  }
};

export const sendNotificationToDrivers = async (driverIds, title, body, data = {}) => {
  if (!driverIds || driverIds.length === 0) return;
  
  try {
    const res = await query(
      'SELECT id, fcm_token FROM drivers WHERE id = ANY($1) AND fcm_token IS NOT NULL',
      [driverIds]
    );
    
    const tokens = res.rows.map(r => r.fcm_token);
    if (tokens.length === 0) return;

    const message = {
      notification: { title, body },
      data: {
        ...data,
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      },
      tokens
    };

    const response = await messaging.sendEachForMulticast(message);
    console.log(`✉️ FCM: Multicast notification sent to ${tokens.length} drivers. Success: ${response.successCount}, Failure: ${response.failureCount}`);
  } catch (err) {
    console.error('❌ FCM: Multicast failed:', err.message);
  }
};
