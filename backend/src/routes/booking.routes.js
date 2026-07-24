import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { sendNotificationToUser, sendNotificationToDrivers } from '../services/notification.service.js';
import { broadcast } from '../services/websocket.service.js';
import { evaluateDriverAccountStatus } from './ledger.routes.js';

const router = express.Router();

// Helper to calculate distance using Haversine formula
const getDistanceKm = (lat1, lng1, lat2, lng2) => {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lng2 - lng1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
};

// GET /api/booking/active - Find current active booking for the user
router.get('/active', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const role = req.user.role;

    let bookingRes;
    if (role === 'driver') {
      bookingRes = await query(
        "SELECT * FROM bookings WHERE driver_id = $1 AND status NOT IN ('completed', 'cancelled', 'expired') ORDER BY created_at DESC LIMIT 1",
        [uid]
      );
    } else {
      bookingRes = await query(
        "SELECT * FROM bookings WHERE customer_id = $1 AND status NOT IN ('completed', 'cancelled', 'expired') ORDER BY created_at DESC LIMIT 1",
        [uid]
      );
    }

    if (bookingRes.rows.length > 0) {
      return res.json({ exists: true, booking: bookingRes.rows[0] });
    }
    res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/booking/active error:', err);
    res.status(500).json({ error: 'Failed to retrieve active booking' });
  }
});

// POST /api/booking - Create new booking
router.post(
  '/',
  verifyToken,
  [
    body('pickupName').notEmpty(),
    body('pickupLat').isFloat({ min: -90, max: 90 }),
    body('pickupLng').isFloat({ min: -180, max: 180 }),
    body('dropoffName').notEmpty(),
    body('dropoffLat').isFloat({ min: -90, max: 90 }),
    body('dropoffLng').isFloat({ min: -180, max: 180 }),
    body('vehicleType').isIn(['bike', 'mini_truck', 'large_truck']),
    body('weight').isInt({ min: 1 }),
    body('estimatedCost').isNumeric()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const customerId = req.user.uid;
      const {
        pickupName, pickupLat, pickupLng,
        dropoffName, dropoffLat, dropoffLng,
        vehicleType, weight, estimatedCost
      } = req.body;

      // Generate 6-digit OTP
      const otp = String(Math.floor(100000 + Math.random() * 900000));
      const expiresAt = new Date(Date.now() + 30 * 60 * 1000); // 30 mins expiry

      const insertBookingQuery = `
        INSERT INTO bookings (customer_id, pickup_name, pickup_lat, pickup_lng, dropoff_name, dropoff_lat, dropoff_lng, vehicle_type, weight, estimated_cost, otp, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        RETURNING *
      `;
      const bookingRes = await client.query(insertBookingQuery, [
        customerId, pickupName, pickupLat, pickupLng,
        dropoffName, dropoffLat, dropoffLng, vehicleType, weight, estimatedCost, otp, expiresAt
      ]);
      const booking = bookingRes.rows[0];

      // Add booking event log
      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [booking.id, 'created', 'Booking created by customer']
      );

      await client.query('COMMIT');

      // Broadcast new booking created event to admins and drivers
      broadcast({ type: 'booking_created', bookingId: booking.id, booking });

      // Async: find nearby drivers and send FCM notifications
      const driversRes = await query(
        "SELECT id, lat, lng FROM drivers WHERE status = 'online' AND is_approved = TRUE AND vehicle_type = $1",
        [vehicleType]
      );
      const eligibleDriverIds = [];
      driversRes.rows.forEach(d => {
        if (d.lat && d.lng) {
          const dist = getDistanceKm(pickupLat, pickupLng, d.lat, d.lng);
          if (dist <= 3.0) {
            eligibleDriverIds.push(d.id);
          }
        }
      });

      if (eligibleDriverIds.length > 0) {
        sendNotificationToDrivers(
          eligibleDriverIds,
          'New Cargo Request Available',
          `Deliver ${weight}kg for ₹${estimatedCost} from ${pickupName}`,
          { bookingId: booking.id }
        );
      }

      res.json({ success: true, booking });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking error:', err);
      res.status(500).json({ error: 'Failed to create booking' });
    } finally {
      client.release();
    }
  }
);

// POST /api/booking/accept - Driver accepts booking
router.post(
  '/accept',
  verifyToken,
  [
    body('bookingId').isUUID()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const driverId = req.user.uid;
      const { bookingId } = req.body;

      // 1. Verify driver is approved and online
      const driverRes = await client.query('SELECT * FROM drivers WHERE id = $1', [driverId]);
      if (driverRes.rows.length === 0) {
        return res.status(404).json({ error: 'Driver profile not found.' });
      }
      const driver = driverRes.rows[0];
      if (!driver.is_approved) {
        return res.status(403).json({ error: 'Driver profile is not approved by administrator.' });
      }
      if (driver.status === 'offline') {
        return res.status(400).json({ error: 'You must go online to accept bookings.' });
      }

      // 2. Lock and verify booking status
      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [bookingId]);
      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Booking not found.' });
      }
      const booking = bookingRes.rows[0];
      if (booking.status !== 'pending') {
        return res.status(400).json({ error: 'Booking is no longer pending.' });
      }
      if (new Date() > new Date(booking.expires_at)) {
        return res.status(400).json({ error: 'Booking has expired.' });
      }

      // 3. Update status
      const updateBookingRes = await client.query(
        "UPDATE bookings SET driver_id = $1, status = 'accepted' WHERE id = $2 RETURNING *",
        [driverId, bookingId]
      );
      const updatedBooking = updateBookingRes.rows[0];

      await client.query(
        "UPDATE drivers SET status = 'busy' WHERE id = $1",
        [driverId]
      );

      // 4. Log event
      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [bookingId, 'accepted', `Booking accepted by driver: ${driver.name}`]
      );

      await client.query('COMMIT');

      // Broadcast state update
      broadcast({ type: 'booking_accepted', bookingId, driverId, booking: updatedBooking });
      
      // Also broadcast driver status update
      broadcast({ type: 'driver_status', driverId, status: 'busy' });

      // Send FCM notification to customer
      sendNotificationToUser(
        booking.customer_id,
        'Delivery Partner Assigned',
        `${driver.name} is on their way to your pickup location.`,
        { bookingId }
      );

      res.json({ success: true, booking: updatedBooking });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/accept error:', err);
      res.status(500).json({ error: 'Failed to accept booking.' });
    } finally {
      client.release();
    }
  }
);

// POST /api/booking/verify-pickup - Verify OTP at pickup
router.post(
  '/verify-pickup',
  verifyToken,
  [
    body('bookingId').isUUID(),
    body('otp').isLength({ min: 6, max: 6 }).isNumeric()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const driverId = req.user.uid;
      const { bookingId, otp } = req.body;

      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [bookingId]);
      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Booking not found.' });
      }
      const booking = bookingRes.rows[0];

      if (booking.driver_id !== driverId) {
        return res.status(403).json({ error: 'Forbidden: You are not the driver assigned to this booking.' });
      }
      if (booking.status !== 'accepted' && booking.status !== 'arrived_pickup') {
        return res.status(400).json({ error: 'Invalid booking state for pickup verification.' });
      }
      if (booking.otp !== otp) {
        return res.status(400).json({ error: 'Incorrect pickup verification OTP code.' });
      }

      // Transition to 'dropping_off'
      const updateRes = await client.query("UPDATE bookings SET status = 'dropping_off' WHERE id = $1 RETURNING *", [bookingId]);
      const updatedBooking = updateRes.rows[0];

      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [bookingId, 'picking_up', 'Cargo verified with customer OTP. Delivery is in transit.']
      );

      await client.query('COMMIT');

      // Broadcast update
      broadcast({ type: 'booking_transit', bookingId, booking: updatedBooking });

      sendNotificationToUser(
        booking.customer_id,
        'Cargo Verified & In Transit',
        'Your goods are now in transit to the dropoff point.',
        { bookingId }
      );

      res.json({ success: true, booking: updatedBooking });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/verify-pickup error:', err);
      res.status(500).json({ error: 'Failed to verify cargo pickup.' });
    } finally {
      client.release();
    }
  }
);

// POST /api/booking/status - Update booking status
router.post(
  '/status',
  verifyToken,
  [
    body('bookingId').isUUID(),
    body('status').isIn(['arrived_pickup', 'arrived_dropoff', 'completed', 'cancelled'])
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const userId = req.user.uid;
      const { bookingId, status } = req.body;

      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [bookingId]);
      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Booking not found.' });
      }
      const booking = bookingRes.rows[0];

      // Security Checks
      if (booking.driver_id !== userId && booking.customer_id !== userId && req.user.role !== 'admin') {
        return res.status(403).json({ error: 'Unauthorized status modification.' });
      }

      let updatedBooking;

      // State machine logic
      if (status === 'completed') {
        if (booking.status !== 'dropping_off' && booking.status !== 'arrived_dropoff') {
          return res.status(400).json({ error: 'Cannot complete booking before picking up cargo.' });
        }

        const fare = parseFloat(booking.estimated_cost || 0);
        const commission = fare * 0.10; // 10% platform commission
        const paymentType = booking.payment_type || 'cash';
        const driverId = booking.driver_id;

        // Fetch driver wallet & dues details with row lock
        const driverRes = await client.query('SELECT wallet_balance, outstanding_dues FROM drivers WHERE id = $1 FOR UPDATE', [driverId]);
        let currentWallet = parseFloat(driverRes.rows[0]?.wallet_balance || 0);
        let currentDues = parseFloat(driverRes.rows[0]?.outstanding_dues || 0);

        let driverNetEarnings = 0;

        if (paymentType === 'online') {
          // Online Prepaid Payment: Platform collects fare
          driverNetEarnings = fare - commission;

          // Record Trip Earning Entry
          await client.query(
            `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
             VALUES ($1, $2, 'trip_earning', $3, $4, $5)`,
            [driverId, bookingId, driverNetEarnings, currentWallet + driverNetEarnings, `Net Trip Earning (Fare ₹${fare} - Commission ₹${commission.toFixed(2)})`]
          );

          // Automated Dues Offset: If driver owes outstanding dues, offset against online earnings
          let duesOffset = 0;
          if (currentDues > 0) {
            duesOffset = Math.min(currentDues, driverNetEarnings);
            currentDues -= duesOffset;
            driverNetEarnings -= duesOffset;

            await client.query(
              `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
               VALUES ($1, $2, 'dues_offset', $3, $4, $5)`,
              [driverId, bookingId, -duesOffset, -currentDues, `Auto Dues Offset against Online Trip Earnings`]
            );
          }

          currentWallet += driverNetEarnings;
        } else {
          // Cash / Direct-UPI Payment: Driver collects full fare directly
          driverNetEarnings = fare;
          currentDues += commission;

          // Record Commission Debit Entry
          await client.query(
            `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
             VALUES ($1, $2, 'platform_commission', $3, $4, $5)`,
            [driverId, bookingId, -commission, -currentDues, `Platform Commission Owed (Cash Fare ₹${fare})`]
          );
        }

        // Update driver wallet & dues
        await client.query(
          `UPDATE drivers SET wallet_balance = $1, outstanding_dues = $2, status = 'online' WHERE id = $3`,
          [currentWallet, currentDues, driverId]
        );

        // Update booking settlement state
        const updateRes = await client.query(
          `UPDATE bookings SET status = 'completed', commission_amount = $1, driver_net_earnings = $2, is_settled = TRUE WHERE id = $3 RETURNING *`,
          [commission, driverNetEarnings, bookingId]
        );
        updatedBooking = updateRes.rows[0];

        await client.query(
          'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
          [bookingId, 'completed', `Delivery completed. Ledger settled (${paymentType.toUpperCase()} payment mode).`]
        );
      } else if (status === 'cancelled') {
        if (booking.status === 'completed' || booking.status === 'expired') {
          return res.status(400).json({ error: 'Cannot cancel an already completed or expired booking.' });
        }
        const updateRes = await client.query("UPDATE bookings SET status = 'cancelled' WHERE id = $1 RETURNING *", [bookingId]);
        updatedBooking = updateRes.rows[0];

        if (booking.driver_id) {
          await client.query("UPDATE drivers SET status = 'online' WHERE id = $1", [booking.driver_id]);
        }
        await client.query(
          'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
          [bookingId, 'cancelled', `Delivery cancelled by user: ${userId}`]
        );
      } else {
        // arrived_pickup or arrived_dropoff
        const updateRes = await client.query("UPDATE bookings SET status = $1 WHERE id = $2 RETURNING *", [status, bookingId]);
        updatedBooking = updateRes.rows[0];

        await client.query(
          'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
          [bookingId, status, `Driver reached ${status.split('_')[1]} point.`]
        );
      }

      await client.query('COMMIT');

      if (status === 'completed' && booking.driver_id) {
        await evaluateDriverAccountStatus(booking.driver_id);
      }

      // Broadcast booking status change
      broadcast({ type: 'booking_status', bookingId, status, booking: updatedBooking });

      // If status completed/cancelled, broadcast that driver is online again
      if ((status === 'completed' || status === 'cancelled') && booking.driver_id) {
        broadcast({ type: 'driver_status', driverId: booking.driver_id, status: 'online' });
      }

      // Send status notifications
      if (status === 'completed') {
        sendNotificationToUser(booking.customer_id, 'Delivery Completed', 'Your shipment has been successfully delivered!', { bookingId });
      } else if (status === 'cancelled') {
        const notifyTarget = (userId === booking.customer_id) ? booking.driver_id : booking.customer_id;
        if (notifyTarget) {
          sendNotificationToUser(notifyTarget, 'Booking Cancelled', `Shipment order #${bookingId.substring(0,8)} has been cancelled.`, { bookingId });
        }
      } else if (status === 'arrived_pickup') {
        sendNotificationToUser(booking.customer_id, 'Driver Arrived at Pickup', 'Your delivery partner has arrived at the pickup location.', { bookingId });
      }

      res.json({ success: true, booking: updatedBooking });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/status error:', err);
      res.status(500).json({ error: 'Failed to update booking status.' });
    } finally {
      client.release();
    }
  }
);

export default router;
