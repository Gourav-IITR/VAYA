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
      console.warn(`[FCM] No FCM token registered for user: ${userId}`);
      return false;
    }

    const bookingId = data.bookingId || data.booking_id || '';
    const collapseKey = bookingId ? `booking_${bookingId}` : undefined;

    const message = {
      notification: { title, body },
      data: {
        ...data,
        bookingId,
        screen: 'active_delivery',
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      },
      android: {
        priority: 'high',
        collapseKey: collapseKey,
        notification: {
          tag: collapseKey,
          channelId: 'order_updates',
          sound: 'default'
        }
      },
      token
    };

    const response = await messaging.send(message);
    console.log(`[FCM] Notification sent to ${userId} successfully. ID: ${response}`);
    return true;
  } catch (err) {
    console.error(`[FCM] Failed to send notification to user ${userId}:`, err.message);
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

    const bookingId = data.bookingId || data.booking_id || '';
    const collapseKey = bookingId ? `booking_${bookingId}` : undefined;

    const message = {
      data: {
        ...data,
        title,
        body,
        bookingId,
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      },
      android: {
        priority: 'high',
        collapseKey: collapseKey,
      },
      tokens
    };

    const response = await messaging.sendEachForMulticast(message);
    console.log(`[FCM] Multicast notification sent to ${tokens.length} drivers. Success: ${response.successCount}, Failure: ${response.failureCount}`);
  } catch (err) {
    console.error('[FCM] Multicast failed:', err.message);
  }
};

const formatVehicleType = (type) => {
  if (!type) return 'Vehicle';
  const lower = String(type).toLowerCase();
  if (lower === 'bike') return 'Bike';
  if (lower === 'three_wheeler' || lower === '3_wheeler' || lower === 'auto') return 'Auto';
  if (lower === 'ace' || lower === 'tata_ace') return 'Tata Ace';
  if (lower === 'truck') return 'Truck';
  return type.charAt(0).toUpperCase() + type.slice(1);
};

/**
 * Server-triggered Order Status Notification Generator
 * Generates dynamic notifications with stable notification IDs (collapseKey/tag),
 * non-truncating OTP & vehicle headers, and deep-link payload data.
 */
export const sendOrderStatusNotification = async (bookingId, statusType, extraData = {}) => {
  try {
    const bookingRes = await query(
      `SELECT b.*, 
              d.name AS driver_name, d.phone AS driver_phone, d.vehicle_type AS d_vehicle_type, d.vehicle_reg AS d_vehicle_reg,
              c.name AS customer_name, c.phone AS customer_phone
       FROM bookings b
       LEFT JOIN drivers d ON b.driver_id = d.id
       LEFT JOIN customers c ON b.customer_id = c.id
       WHERE b.id = $1`,
      [bookingId]
    );

    if (bookingRes.rows.length === 0) {
      console.warn(`[FCM] Cannot send notification, booking not found: ${bookingId}`);
      return false;
    }

    const booking = bookingRes.rows[0];
    const customerId = booking.customer_id;
    const driverId = booking.driver_id;
    const otp = booking.otp || extraData.otp || '------';
    
    const rawVehicleType = booking.d_vehicle_type || booking.vehicle_type;
    const vehicleType = formatVehicleType(rawVehicleType);
    const vehicleReg = booking.d_vehicle_reg || 'OD-VAYA';
    const driverName = booking.driver_name || 'Driver Partner';
    const customerName = booking.customer_name || 'Customer';
    const shortBookingId = String(bookingId).substring(0, 8).toUpperCase();

    // Standard header formatting for collapsed view: OTP + Vehicle info right at start
    const vehicleHeader = `${vehicleType} (${vehicleReg})`;
    const titleWithOtp = `OTP: ${otp} • ${vehicleHeader}`;

    let title = '';
    let body = '';
    let targetUserId = customerId;

    switch (statusType) {
      case 'driver_assigned':
        title = titleWithOtp;
        body = `Driver Assigned: ${driverName} is on the way to your pickup location.`;
        break;

      case 'driver_near_pickup':
        title = titleWithOtp;
        body = `Driver Near Pickup: ${driverName} is within 500m of your pickup spot.`;
        break;

      case 'driver_arrived_pickup':
        title = titleWithOtp;
        body = `Driver Arrived at Pickup: ${driverName} has arrived. Free 10-min wait started.`;
        break;

      case 'free_wait_ending':
        title = titleWithOtp;
        body = `Free Pickup Wait Ending: 2 mins left before standard waiting charges (₹2/min) apply.`;
        break;

      case 'delivery_started':
        title = titleWithOtp;
        body = `Delivery Started: Cargo verified. ${driverName} is in transit to drop-off.`;
        break;

      case 'driver_near_dropoff':
        title = titleWithOtp;
        body = `Driver Near Drop-off: ${driverName} is within 500m of the drop-off spot.`;
        break;

      case 'driver_arrived_dropoff':
        title = titleWithOtp;
        body = `Driver Arrived at Drop-off: ${driverName} has arrived. Provide OTP ${otp} to unload.`;
        break;

      case 'additional_payment_due':
        {
          const amountDue = extraData.amountDue || booking.amount_due_now || booking.total_waiting_charge || 0;
          title = titleWithOtp;
          body = `Additional Payment Due: ₹${amountDue} pending for waiting/extra charges. Tap to pay now.`;
        }
        break;

      case 'payment_confirmed':
        {
          const amountPaid = extraData.amountPaid || booking.final_cost || booking.estimated_cost || 0;
          title = `Payment Confirmed • ${vehicleHeader}`;
          body = `Payment Confirmed: ₹${amountPaid} received for order #${shortBookingId}.`;
        }
        break;

      case 'delivered':
        title = `Delivered • ${vehicleHeader}`;
        body = `Delivered: Shipment successfully delivered by ${driverName}. Thank you for using VAYA!`;
        break;

      case 'cancelled':
        {
          const cancelledByRole = extraData.cancelledByRole || booking.cancelled_by_role || 'User';
          const cancelledByName = extraData.cancelledByName || (cancelledByRole === 'Customer' ? customerName : (cancelledByRole === 'Driver' ? driverName : 'Admin'));
          const fee = extraData.cancellationFee ?? booking.cancellation_fee ?? 0;
          const feeStr = fee > 0 ? `₹${fee} cancellation fee applies` : 'No cancellation fee';
          
          let nextAction = extraData.nextAction || '';
          if (!nextAction) {
            nextAction = cancelledByRole === 'Customer' 
              ? 'You can book a new vehicle anytime.' 
              : 'Our system will find you another driver.';
          }

          // Target notification to the other party or customer
          if (extraData.targetUserId) {
            targetUserId = extraData.targetUserId;
          } else if (extraData.cancellerId === customerId && driverId) {
            targetUserId = driverId;
          } else {
            targetUserId = customerId;
          }

          title = `Cancelled by ${cancelledByRole} • ${vehicleReg}`;
          body = `Order #${shortBookingId} cancelled by ${cancelledByName}. ${feeStr}. Next step: ${nextAction}`;
        }
        break;

      default:
        title = titleWithOtp;
        body = `Order #${shortBookingId} updated to ${statusType}.`;
        break;
    }

    if (!targetUserId) {
      console.warn(`[FCM] No target user ID for notification statusType: ${statusType}`);
      return false;
    }

    return await sendNotificationToUser(targetUserId, title, body, {
      bookingId,
      statusType,
      screen: 'active_delivery',
      otp: otp !== '------' ? otp : '',
      vehicleReg,
      vehicleType
    });
  } catch (err) {
    console.error(`[FCM] Error in sendOrderStatusNotification (${statusType}):`, err);
    return false;
  }
};
