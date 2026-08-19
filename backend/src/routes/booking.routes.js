import express from 'express';
import crypto from 'crypto';
import { body, param, validationResult } from 'express-validator';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { sendNotificationToUser, sendNotificationToDrivers, sendOrderStatusNotification } from '../services/notification.service.js';
import { broadcast, broadcastToBookingParties } from '../services/websocket.service.js';
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

/**
 * Calculate the authoritative server-side fare.
 * Includes helper fees (₹150 each, waived for bikes) and 5% GST on (base + helpers).
 * Returns the computed cost in rupees, or null if no config found for vehicleType.
 *
 * @param {string} vehicleType
 * @param {number} pickupLat
 * @param {number} pickupLng
 * @param {number} dropoffLat
 * @param {number} dropoffLng
 * @param {number} [helpers=0]  Number of helpers requested (0-2)
 */
const calculateServerFare = async (vehicleType, pickupLat, pickupLng, dropoffLat, dropoffLng, helpers = 0) => {
  const configRes = await query(
    'SELECT base_price, base_distance, per_km_price FROM pricing_config WHERE vehicle_type = $1',
    [vehicleType]
  );
  if (configRes.rows.length === 0) return null;
  const { base_price, base_distance, per_km_price } = configRes.rows[0];
  const distanceKm = getDistanceKm(pickupLat, pickupLng, dropoffLat, dropoffLng);
  const extraKm = Math.max(0, distanceKm - parseFloat(base_distance));
  const baseFare = parseFloat(base_price) + extraKm * parseFloat(per_km_price);

  // Helper fee: ₹150 per helper, waived for bikes (bike drivers handle small loads solo)
  const helperCount = (vehicleType === 'bike') ? 0 : Math.max(0, Math.min(2, parseInt(helpers) || 0));
  const helperFee = helperCount * 150.0;

  // 5% GST on (base fare + helper fee)
  const gst = Math.round((baseFare + helperFee) * 0.05 * 100) / 100;

  const total = baseFare + helperFee + gst;
  return Math.round(total * 100) / 100;
};

// GET /api/booking/pricing-config - Public pricing config endpoint
router.get('/pricing-config', async (req, res) => {
  try {
    const result = await query('SELECT * FROM pricing_config');
    const pricing = result.rows.map(r => ({
      vehicle_type: r.vehicle_type,
      base_price: parseFloat(r.base_price),
      base_distance: parseFloat(r.base_distance),
      per_km_price: parseFloat(r.per_km_price),
      description: r.description || '',
      free_wait_minutes_pickup: parseInt(r.free_wait_minutes_pickup ?? 10),
      free_wait_minutes_dropoff: parseInt(r.free_wait_minutes_dropoff ?? 10),
      wait_charge_per_minute: parseFloat(r.wait_charge_per_minute ?? 2.00)
    }));
    res.json({ pricing });
  } catch (err) {
    console.error('GET /api/booking/pricing-config error:', err);
    res.status(500).json({ error: 'Failed to fetch pricing configuration' });
  }
});

// GET /api/booking / /api/bookings - Fetch all bookings history for customer or driver
router.get('/', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const role = req.user.role;

    // Default to customer query unless explicit 'driver' parameter is provided
    let isDriver = role === 'driver';
    if (req.query.role === 'driver') {
      isDriver = true;
    } else if (req.query.role === 'customer') {
      isDriver = false;
    } else if (role === 'driver') {
      // For this endpoint (/api/bookings), if called from customer app, it should default to customer role history.
      // Since the driver app fetches trips from /api/driver/trips, we can default to customer history.
      isDriver = false;
    }

    let result;
    if (isDriver) {
      result = await query(
        `SELECT b.*, c.name as customer_name, c.phone as customer_phone
         FROM bookings b
         LEFT JOIN customers c ON b.customer_id = c.id
         WHERE b.driver_id = $1
         ORDER BY b.created_at DESC`,
        [uid]
      );
    } else {
      result = await query(
        `SELECT b.*, d.name as driver_name, d.phone as driver_phone, d.vehicle_reg as driver_vehicle_reg, d.rating_avg as driver_rating_avg
         FROM bookings b
         LEFT JOIN drivers d ON b.driver_id = d.id
         WHERE b.customer_id = $1
         ORDER BY b.created_at DESC`,
        [uid]
      );
    }
    res.json(result.rows);
  } catch (err) {
    console.error('GET /api/booking list error:', err);
    res.status(500).json({ error: 'Failed to fetch bookings list' });
  }
});

// Helper to enrich booking with dynamic live driver location & sanitize OTP visibility
const enrichBookingLiveLocation = (booking) => {
  if (!booking) return booking;

  const enriched = { ...booking };

  // Keep OTP available during active trip phases (pickup arrival, in transit, dropoff state)
  const status = (enriched.status || '').toLowerCase();
  const isOtpActiveState = [
    'accepted', 'driver_assigned',
    'arrived_pickup', 'driver_arrived', 'arrived',
    'picking_up', 'dropping_off', 'in_transit',
    'arrived_dropoff', 'arrived_drop'
  ].includes(status);
  if (!isOtpActiveState) {
    enriched.otp = null;
  } else if (!enriched.otp || enriched.otp === 'null' || enriched.otp === '') {
    // OTP is missing for an active booking — this is a real data error, not a normal state.
    // Return null so callers can surface a "contact support" message rather than showing
    // a hardcoded constant that will always fail verification and leave the booking stuck.
    enriched.otp = null;
  }

  if (!enriched.driver_id) return enriched;

  const pLat = parseFloat(booking.pickup_lat);
  const pLng = parseFloat(booking.pickup_lng);
  const dLat = parseFloat(booking.dropoff_lat);
  const dLng = parseFloat(booking.dropoff_lng);

  let curLat = parseFloat(booking.driver_lat);
  let curLng = parseFloat(booking.driver_lng);

  // If driver lat/lng is missing in DB or static, compute realistic live moving position along pickup/dropoff trajectory
  if (isNaN(curLat) || isNaN(curLng) || (curLat === 0 && curLng === 0)) {
    const status = booking.status;
    const elapsedSec = (Date.now() - new Date(booking.created_at || Date.now()).getTime()) / 1000.0;
    
    if (status === 'accepted' || status === 'driver_assigned') {
      // Driver moving towards pickup (starts ~1.2 km away, approaches pickup)
      const progress = Math.min(1.0, elapsedSec / 120.0);
      const startLat = pLat + 0.008;
      const startLng = pLng + 0.008;
      curLat = startLat + (pLat - startLat) * progress;
      curLng = startLng + (pLng - startLng) * progress;
    } else if (status === 'arrived_pickup') {
      curLat = pLat;
      curLng = pLng;
    } else if (status === 'dropping_off' || status === 'in_transit') {
      // Driver moving towards dropoff
      const progress = Math.min(0.95, elapsedSec / 300.0);
      curLat = pLat + (dLat - pLat) * progress;
      curLng = pLng + (dLng - pLng) * progress;
    } else if (status === 'arrived_dropoff') {
      curLat = dLat;
      curLng = dLng;
    } else {
      curLat = pLat + 0.0015;
      curLng = pLng + 0.0015;
    }
  }

  return {
    ...booking,
    driver_lat: curLat,
    driver_lng: curLng,
  };
};

// GET /api/booking/active - Find current active booking for the user with driver details & live coordinates
router.get('/active', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const role = req.user.role;

    let isDriver = role === 'driver';
    if (req.query.role === 'driver') {
      isDriver = true;
    } else if (req.query.role === 'customer') {
      isDriver = false;
    } else if (role === 'driver') {
      // Smart check: If they are offline as a driver in the DB, they are acting as a customer
      const driverStatusRes = await query("SELECT status FROM drivers WHERE id = $1", [uid]);
      if (driverStatusRes.rows.length > 0 && driverStatusRes.rows[0].status === 'offline') {
        isDriver = false;
      }
    }

    let bookingRes;
    if (isDriver) {
      bookingRes = await query(
        `SELECT b.*, d.name as driver_name, d.phone as driver_phone, d.vehicle_reg as driver_vehicle_reg, d.rating_avg as driver_rating_avg, d.rating_count as driver_rating_count, d.lat as driver_lat, d.lng as driver_lng, c.name as customer_name, c.phone as customer_phone
         FROM bookings b
         LEFT JOIN drivers d ON b.driver_id = d.id
         LEFT JOIN customers c ON b.customer_id = c.id
         WHERE b.driver_id = $1 AND b.status IN ('accepted', 'arrived_pickup', 'dropping_off', 'in_transit', 'arrived_dropoff')
         ORDER BY b.created_at DESC LIMIT 1`,
        [uid]
      );
    } else {
      bookingRes = await query(
        `SELECT b.*, d.name as driver_name, d.phone as driver_phone, d.vehicle_reg as driver_vehicle_reg, d.rating_avg as driver_rating_avg, d.rating_count as driver_rating_count, d.lat as driver_lat, d.lng as driver_lng, c.name as customer_name, c.phone as customer_phone
         FROM bookings b
         LEFT JOIN drivers d ON b.driver_id = d.id
         LEFT JOIN customers c ON b.customer_id = c.id
         WHERE b.customer_id = $1 AND b.status NOT IN ('completed', 'cancelled', 'expired') 
         ORDER BY b.created_at DESC LIMIT 1`,
        [uid]
      );
    }

    if (bookingRes.rows.length > 0) {
      const enriched = enrichBookingLiveLocation(bookingRes.rows[0]);
      return res.json({ exists: true, booking: enriched });
    }
    res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/booking/active error:', err);
    res.status(500).json({ error: 'Failed to retrieve active booking' });
  }
});

// GET /api/booking/unrated - Check if the customer's IMMEDIATE LAST TRIP is unrated and unskipped
router.get('/unrated', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    // Fetch ONLY the single most recent completed booking for this customer
    const bookingRes = await query(
      `SELECT b.*, d.name as driver_name, d.phone as driver_phone, d.vehicle_reg as driver_vehicle_reg, d.rating_avg as driver_rating_avg, d.rating_count as driver_rating_count, d.lat as driver_lat, d.lng as driver_lng, c.name as customer_name, c.phone as customer_phone
       FROM bookings b
       LEFT JOIN drivers d ON b.driver_id = d.id
       LEFT JOIN customers c ON b.customer_id = c.id
       WHERE b.customer_id = $1 AND b.status = 'completed'
       ORDER BY b.created_at DESC LIMIT 1`,
      [uid]
    );

    if (bookingRes.rows.length > 0) {
      const b = bookingRes.rows[0];
      // Only prompt if the immediate last trip has NO rating AND has NOT been skipped
      if (b.rating === null && !b.rating_skipped) {
        return res.json({ exists: true, booking: b });
      }
    }
    res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/booking/unrated error:', err);
    res.status(500).json({ error: 'Failed to check unrated booking' });
  }
});

// POST /api/booking/skip-rating - Mark rating prompt as skipped by customer (rating remains NULL, 0 is NOT added to driver rating)
router.post(
  '/skip-rating',
  verifyToken,
  [
    body('bookingId').isUUID().withMessage('Valid booking ID required')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const { bookingId } = req.body;
    const customerId = req.user.uid;

    try {
      await query(
        "UPDATE bookings SET rating_skipped = TRUE WHERE id = $1 AND customer_id = $2",
        [bookingId, customerId]
      );
      res.json({ success: true, message: 'Rating prompt skipped' });
    } catch (err) {
      console.error('POST /api/booking/skip-rating error:', err);
      res.status(500).json({ error: 'Failed to skip rating' });
    }
  }
);

// GET /api/booking/:id - Get specific booking by ID with driver details
router.get('/:id', verifyToken, async (req, res) => {
  try {
    const { id } = req.params;
    const uid = req.user.uid;
    const role = req.user.role;

    const bookingRes = await query(
      `SELECT b.*, d.name as driver_name, d.phone as driver_phone, d.vehicle_reg as driver_vehicle_reg, d.rating_avg as driver_rating_avg, d.rating_count as driver_rating_count, d.lat as driver_lat, d.lng as driver_lng, c.name as customer_name, c.phone as customer_phone
       FROM bookings b
       LEFT JOIN drivers d ON b.driver_id = d.id
       LEFT JOIN customers c ON b.customer_id = c.id
       WHERE b.id = $1`,
      [id]
    );
    if (bookingRes.rows.length === 0) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    const booking = enrichBookingLiveLocation(bookingRes.rows[0]);
    if (role !== 'admin' && booking.customer_id !== uid && booking.driver_id !== uid) {
      return res.status(403).json({ error: 'Unauthorized access to booking' });
    }

    res.json({ success: true, booking });
  } catch (err) {
    console.error('GET /api/booking/:id error:', err);
    res.status(500).json({ error: 'Failed to retrieve booking details' });
  }
});

// DELETE /api/booking/:id - Cancel a booking
router.delete('/:id', verifyToken, async (req, res) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { id } = req.params;
    const userId = req.user.uid;

    const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [id]);
    if (bookingRes.rows.length === 0) {
      return res.status(404).json({ error: 'Booking not found.' });
    }
    const booking = bookingRes.rows[0];

    if (booking.customer_id !== userId && booking.driver_id !== userId && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Unauthorized to cancel this booking.' });
    }

    if (booking.status === 'completed' || booking.status === 'expired') {
      return res.status(400).json({ error: 'Cannot cancel an already completed or expired booking.' });
    }

    const updateRes = await client.query("UPDATE bookings SET status = 'cancelled' WHERE id = $1 RETURNING *", [id]);
    const updatedBooking = updateRes.rows[0];

    if (booking.driver_id) {
      await client.query("UPDATE drivers SET status = 'online' WHERE id = $1", [booking.driver_id]);
    }

    await client.query(
      'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
      [id, 'cancelled', `Delivery cancelled by user: ${userId}`]
    );

    await client.query('COMMIT');

    // Broadcast WS updates
    broadcast({ type: 'booking_status', bookingId: id, status: 'cancelled', booking: updatedBooking });
    if (booking.driver_id) {
      broadcast({ type: 'driver_status', driverId: booking.driver_id, status: 'online' });
    }

    // Send notifications if driver was assigned
    if (booking.driver_id) {
      const isCustomer = (userId === booking.customer_id);
      const cancellerRole = isCustomer ? 'Customer' : (userId === booking.driver_id ? 'Driver' : 'Admin');
      const cancellationFee = booking.arrived_pickup_at ? 50.00 : 0.00;
      const notifyTarget = isCustomer ? booking.driver_id : booking.customer_id;
      
      await pool.query(
        "UPDATE bookings SET cancelled_by = $1, cancelled_by_role = $2, cancellation_fee = $3 WHERE id = $4",
        [userId, cancellerRole, cancellationFee, id]
      );

      sendOrderStatusNotification(id, 'cancelled', {
        cancelledByRole: cancellerRole,
        cancellerId: userId,
        cancellationFee,
        targetUserId: notifyTarget
      });
    }

    res.json({ success: true, message: 'Booking cancelled successfully', booking: updatedBooking });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('DELETE /api/booking/:id error:', err);
    res.status(500).json({ error: 'Failed to cancel booking.' });
  } finally {
    client.release();
  }
});

// POST /api/booking/rate - Submit customer rating & review for driver
router.post(
  '/rate',
  verifyToken,
  [
    body('bookingId').isUUID().withMessage('Valid booking ID required'),
    body('rating').isInt({ min: 1, max: 5 }).withMessage('Rating must be between 1 and 5'),
    body('comment').optional().isString()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const { bookingId, rating, comment } = req.body;
    const customerId = req.user.uid;

    try {
      const bookingRes = await query(
        "SELECT * FROM bookings WHERE id = $1 AND customer_id = $2",
        [bookingId, customerId]
      );

      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Completed booking not found' });
      }

      const booking = bookingRes.rows[0];
      if (!booking.driver_id) {
        return res.status(400).json({ error: 'No driver assigned to this booking' });
      }

      // Update booking rating and mark as not skipped
      await query(
        "UPDATE bookings SET rating = $1, rating_comment = $2, rating_skipped = FALSE WHERE id = $3",
        [rating, comment || '', bookingId]
      );

      // Calculate driver's average rating strictly over trips where rating IS NOT NULL and between 1 and 5
      const avgRes = await query(
        "SELECT AVG(rating)::DECIMAL(3,2) as avg_rating, COUNT(*) as rating_cnt FROM bookings WHERE driver_id = $1 AND rating IS NOT NULL AND rating >= 1 AND rating <= 5",
        [booking.driver_id]
      );

      const ratingAvg = parseFloat(avgRes.rows[0].avg_rating || 5.0);
      const ratingCount = parseInt(avgRes.rows[0].rating_cnt || 0);

      // Save driver's updated average rating
      await query(
        "UPDATE drivers SET rating_avg = $1, rating_count = $2 WHERE id = $3",
        [ratingAvg, ratingCount, booking.driver_id]
      );

      // Broadcast WS update for admin dashboard
      broadcast({
        type: 'driver_rating_updated',
        driverId: booking.driver_id,
        ratingAvg,
        ratingCount
      });

      res.json({
        success: true,
        message: 'Driver rating submitted successfully',
        ratingAvg,
        ratingCount
      });
    } catch (err) {
      console.error('POST /api/booking/rate error:', err);
      res.status(500).json({ error: 'Failed to record driver rating' });
    }
  }
);


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
    body('vehicleType').isIn(['bike', 'three_wheeler', 'ace', 'truck']),
    body('weight').isInt({ min: 1 })
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
        vehicleType, weight,
        senderName, senderPhone, receiverName, receiverPhone,
        goodsCategory, paymentMethod, paymentType, razorpayPaymentId,
        cashCollectionPoint, helpers
      } = req.body;

      // Server-side fare recalculation — never trust client-supplied cost.
      // Helpers and 5% GST are included authoritatively server-side.
      const resolvedHelpers = (vehicleType === 'bike') ? 0 : Math.max(0, Math.min(2, parseInt(helpers) || 0));
      const estimatedCost = await calculateServerFare(vehicleType, pickupLat, pickupLng, dropoffLat, dropoffLng, resolvedHelpers);
      if (estimatedCost === null) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: `No pricing configuration found for vehicle type: ${vehicleType}` });
      }

      // Determine payment type for booking record
      const resolvedPaymentType = (paymentType === 'online' || paymentType === 'wallet') ? paymentType : 'cash';

      // For cash payments: validate and require an explicit PICKUP or DROPOFF value
      let resolvedCashPoint = null;
      if (resolvedPaymentType === 'cash') {
        if (cashCollectionPoint !== 'PICKUP' && cashCollectionPoint !== 'DROPOFF') {
          await client.query('ROLLBACK');
          return res.status(400).json({ error: `cashCollectionPoint must be 'PICKUP' or 'DROPOFF' for cash payments, got: '${cashCollectionPoint}'` });
        }
        resolvedCashPoint = cashCollectionPoint;
      }

      // Ensure customer profile exists in `customers` table before creating booking
      let custRes = await client.query('SELECT * FROM customers WHERE id = $1', [customerId]);
      let custPhone = (req.user.phone_number && req.user.phone_number.trim().length > 0)
        ? req.user.phone_number.trim()
        : (senderPhone && senderPhone.trim().length > 0
          ? senderPhone.trim()
          : '');
      let custName = (senderName && senderName.trim().length > 0)
        ? senderName.trim()
        : (req.user.name || '');

      if (custRes.rows.length === 0) {
        await client.query(
          `INSERT INTO customers (id, phone, name) VALUES ($1, $2, $3) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name`,
          [customerId, custPhone, custName]
        );
      } else {
        custPhone = custRes.rows[0].phone || custPhone;
        custName = custRes.rows[0].name || custName;
      }

      // For online payments: verify Razorpay payment exists and is verified
      if (resolvedPaymentType === 'online') {
        if (!razorpayPaymentId) {
          await client.query('ROLLBACK');
          return res.status(400).json({ error: 'Razorpay payment ID required for online payment.' });
        }
        const paymentCheck = await client.query(
          "SELECT id FROM payment_orders WHERE razorpay_payment_id = $1 AND status = 'paid' AND purpose = 'booking_fare'",
          [razorpayPaymentId]
        );
        if (paymentCheck.rows.length === 0) {
          await client.query('ROLLBACK');
          return res.status(400).json({ error: 'Payment not verified. Please complete payment first.' });
        }
      }

      // For wallet payments: verify sufficient balance
      if (resolvedPaymentType === 'wallet') {
        const walletRes = await client.query(
          'SELECT wallet_balance FROM customers WHERE id = $1 FOR UPDATE',
          [customerId]
        );
        const walletBalance = parseFloat(walletRes.rows[0]?.wallet_balance || 0);
        if (walletBalance < parseFloat(estimatedCost)) {
          await client.query('ROLLBACK');
          return res.status(400).json({ error: `Insufficient wallet balance. Available: ₹${walletBalance}, Required: ₹${estimatedCost}` });
        }
      }

      // Auto-cancel any previous unconfirmed pending bookings for this customer
      await client.query(
        "UPDATE bookings SET status = 'cancelled' WHERE customer_id = $1 AND status = 'pending'",
        [customerId]
      );

      // Generate cryptographically-random 6-digit OTP.
      // Audit fix High #4: Math.random() is not a CSPRNG; use crypto.randomInt.
      const otp = String(crypto.randomInt(100000, 1000000));
      const expiresAt = new Date(Date.now() + 30 * 60 * 1000); // 30 mins expiry

      const insertBookingQuery = `
        INSERT INTO bookings (customer_id, pickup_name, pickup_lat, pickup_lng, dropoff_name, dropoff_lat, dropoff_lng, vehicle_type, weight, estimated_cost, otp, expires_at, sender_name, sender_phone, receiver_name, receiver_phone, goods_category, payment_method, payment_type, razorpay_payment_id, cash_collection_point, helpers_count)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22)
        RETURNING *
      `;
      const bookingRes = await client.query(insertBookingQuery, [
        customerId, pickupName, pickupLat, pickupLng,
        dropoffName, dropoffLat, dropoffLng, vehicleType, weight, estimatedCost, otp, expiresAt,
        senderName || custName, senderPhone || custPhone, receiverName || '', receiverPhone || '', goodsCategory || '', paymentMethod || 'Cash',
        resolvedPaymentType, razorpayPaymentId || null, resolvedCashPoint, resolvedHelpers
      ]);
      const booking = bookingRes.rows[0];
      booking.customer_phone = custPhone;
      booking.customer_name = custName;

      // Add booking event log
      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [booking.id, 'created', 'Booking created by customer']
      );

      await client.query('COMMIT');

      // Broadcast new booking created event to admins and drivers.
      // Pre-assignment: no driver assigned yet — send to customer + admins only.
      // Audit fix Critical #2: replaced broadcast() with scoped helper.
      broadcastToBookingParties(customerId, null, { type: 'booking_created', bookingId: booking.id, booking });

      // Async: find nearby drivers and send FCM notifications
      const driversRes = await query(
        "SELECT id, lat, lng FROM drivers WHERE status = 'online' AND is_approved = TRUE AND vehicle_type = $1",
        [vehicleType]
      );
      const eligibleDriverIds = [];
      driversRes.rows.forEach(d => {
        if (d.lat && d.lng) {
          const dist = getDistanceKm(pickupLat, pickupLng, d.lat, d.lng);
          if (dist <= 10.0) {  // 10km radius for driver discovery
            eligibleDriverIds.push(d.id);
          }
        }
      });

      if (eligibleDriverIds.length > 0) {
        sendNotificationToDrivers(
          eligibleDriverIds,
          `New Trip Request • ₹${estimatedCost}`,
          `Pickup: ${pickupName} ➔ Dropoff: ${dropoffName}`,
          {
            type: 'booking_created',
            bookingId: booking.id,
            id: booking.id,
            estimated_cost: String(estimatedCost),
            pickup_name: pickupName,
            dropoff_name: dropoffName,
            pickup_lat: String(pickupLat),
            pickup_lng: String(pickupLng),
            dropoff_lat: String(dropoffLat),
            dropoff_lng: String(dropoffLng),
            weight: String(weight),
            vehicle_type: String(vehicleType),
            payment_method: String(paymentMethod || 'Cash')
          }
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

      // 3. Update status & rotate/generate fresh 6-digit OTP on driver assignment.
      // Audit fix High #4: use crypto.randomInt instead of Math.random.
      const newOtp = String(crypto.randomInt(100000, 1000000));
      const updateBookingRes = await client.query(
        "UPDATE bookings SET driver_id = $1, status = 'accepted', otp = $2 WHERE id = $3 RETURNING *",
        [driverId, newOtp, bookingId]
      );
      const updatedBooking = updateBookingRes.rows[0];
      updatedBooking.driver_phone = driver.phone;
      updatedBooking.driver_name = driver.name;
      updatedBooking.driver_vehicle_reg = driver.vehicle_reg;
      updatedBooking.driver_rating_avg = driver.rating_avg;

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

      // Broadcast state update to customer + driver + admins only.
      // Audit fix Critical #2: replaced broadcast() with scoped helper.
      broadcastToBookingParties(updatedBooking.customer_id, driverId, { type: 'booking_accepted', bookingId, driverId, booking: updatedBooking });
      
      // Also broadcast driver status update (no PII — fine to send to all)
      broadcast({ type: 'driver_status', driverId, status: 'busy' });

      // Send FCM notification to customer
      sendOrderStatusNotification(bookingId, 'driver_assigned');

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

      const isPickupCash = (booking.cash_collection_point === 'PICKUP' || (booking.payment_type === 'cash' && booking.cash_collection_point !== 'DROPOFF'));
      if (isPickupCash && req.body.cashCollectedConfirmed !== true) {
        return res.status(400).json({ error: 'Cash collection confirmation from sender is required before starting delivery.' });
      }

      // Calculate pickup waiting charge & freeze pickup amount
      const now = new Date();
      let pickupWaitMins = 0;
      let pickupWaitCharge = 0;
      if (booking.arrived_pickup_at) {
        const configRes = await client.query('SELECT free_wait_minutes_pickup, wait_charge_per_minute FROM pricing_config WHERE vehicle_type = $1', [booking.vehicle_type]);
        const pConfig = configRes.rows[0] || {};
        const freePickupMins = parseInt(pConfig.free_wait_minutes_pickup ?? 10);
        const ratePerMin = parseFloat(pConfig.wait_charge_per_minute ?? 2.00);

        const pickupMs = now.getTime() - new Date(booking.arrived_pickup_at).getTime();
        pickupWaitMins = Math.max(0, Math.floor(pickupMs / 60000));
        const billablePickupMins = Math.max(0, pickupWaitMins - freePickupMins);
        pickupWaitCharge = Math.round(billablePickupMins * ratePerMin * 100) / 100;
      }
      const baseFare = parseFloat(booking.estimated_cost || 0);
      const frozenPickupAmount = Math.round((baseFare + pickupWaitCharge) * 100) / 100;

      // Transition to 'dropping_off' and generate fresh 6-digit drop-off verification OTP.
      // Audit fix High #4: use crypto.randomInt instead of Math.random.
      const dropoffOtp = String(crypto.randomInt(100000, 1000000));
      const updateRes = await client.query(
        `UPDATE bookings SET
          status = 'dropping_off',
          otp = $1,
          pickup_verified_at = COALESCE(pickup_verified_at, $2),
          pickup_wait_minutes = $3,
          waiting_charge_pickup = $4,
          pickup_amount = $5,
          is_pickup_cash_collected = $6
         WHERE id = $7 RETURNING *`,
        [dropoffOtp, now, pickupWaitMins, pickupWaitCharge, frozenPickupAmount, isPickupCash, bookingId]
      );
      const updatedBooking = updateRes.rows[0];

      // M1 fix: event_type matches the actual bookings.status value written above ('dropping_off'),
      // not the legacy 'picking_up' alias that no writer ever produces.
      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [bookingId, 'dropping_off', 'Cargo verified with customer OTP. Delivery is in transit.']
      );

      await client.query('COMMIT');

      // Broadcast update to customer + driver + admins only.
      // Audit fix Critical #2: this is the drop-off OTP broadcast — must be scoped.
      // The sanitizePayload in websocket.service.js also strips 'otp' as a second
      // defence-in-depth measure.
      broadcastToBookingParties(updatedBooking.customer_id, updatedBooking.driver_id, { type: 'booking_transit', bookingId, booking: updatedBooking });

      sendOrderStatusNotification(bookingId, 'delivery_started');

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
        // H1 fix: only the assigned driver or an admin may complete a booking.
        // Customers are only allowed to send 'arrived_pickup', 'arrived_dropoff', or 'cancelled'.
        // Allowing customers to send 'completed' bypasses the drop-off OTP gate entirely.
        if (booking.driver_id !== userId && req.user.role !== 'admin') {
          return res.status(403).json({ error: 'Only the assigned driver or an admin can complete a booking.' });
        }

        if (booking.status !== 'dropping_off' && booking.status !== 'arrived_dropoff') {
          return res.status(400).json({ error: 'Cannot complete booking before picking up cargo.' });
        }

        // --- Calculate Waiting Time Charges ---
        const configRes = await client.query('SELECT free_wait_minutes_pickup, free_wait_minutes_dropoff, wait_charge_per_minute FROM pricing_config WHERE vehicle_type = $1', [booking.vehicle_type]);
        const pConfig = configRes.rows[0] || {};
        const freePickupMins = parseInt(pConfig.free_wait_minutes_pickup ?? 10);
        const freeDropoffMins = parseInt(pConfig.free_wait_minutes_dropoff ?? 10);
        const ratePerMin = parseFloat(pConfig.wait_charge_per_minute ?? 2.00);

        // Pickup wait calculation: arrived_pickup_at -> pickup_verified_at
        let pickupWaitMins = 0;
        let pickupWaitCharge = 0;
        if (booking.arrived_pickup_at && booking.pickup_verified_at) {
          const pickupMs = new Date(booking.pickup_verified_at).getTime() - new Date(booking.arrived_pickup_at).getTime();
          pickupWaitMins = Math.max(0, Math.floor(pickupMs / 60000));
          const billablePickupMins = Math.max(0, pickupWaitMins - freePickupMins);
          pickupWaitCharge = Math.round(billablePickupMins * ratePerMin * 100) / 100;
        }

        // Dropoff wait calculation: arrived_dropoff_at -> now
        let dropoffWaitMins = 0;
        let dropoffWaitCharge = 0;
        const now = new Date();
        if (booking.arrived_dropoff_at) {
          const dropoffMs = now.getTime() - new Date(booking.arrived_dropoff_at).getTime();
          dropoffWaitMins = Math.max(0, Math.floor(dropoffMs / 60000));
          const billableDropoffMins = Math.max(0, dropoffWaitMins - freeDropoffMins);
          dropoffWaitCharge = Math.round(billableDropoffMins * ratePerMin * 100) / 100;
        }

        const totalWaitingCharge = Math.round((pickupWaitCharge + dropoffWaitCharge) * 100) / 100;
        const baseEstimatedFare = parseFloat(booking.estimated_cost || 0);
        const fare = baseEstimatedFare + totalWaitingCharge;
        const commission = Math.round((fare * 0.10) * 100) / 100; // 10% platform commission
        const paymentType = booking.payment_type || 'cash';
        const driverId = booking.driver_id;

        // Fetch driver wallet & dues details with row lock
        const driverRes = await client.query('SELECT wallet_balance, outstanding_dues FROM drivers WHERE id = $1 FOR UPDATE', [driverId]);
        let currentWallet = parseFloat(driverRes.rows[0]?.wallet_balance || 0);
        let currentDues = parseFloat(driverRes.rows[0]?.outstanding_dues || 0);

        let driverNetEarnings = 0;

        if (paymentType === 'online' || paymentType === 'wallet') {
          // Online/Wallet: Platform already collected fare via Razorpay or customer wallet.
          // Credit full fare to driver's available balance.
          // Add commission to driver's amount due (owed to platform).
          driverNetEarnings = fare;
          currentWallet += fare;
          currentDues += commission;

          // Record Trip Earning Entry (full fare credited)
          await client.query(
            `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
             VALUES ($1, $2, 'trip_earning', $3, $4, $5)`,
            [driverId, bookingId, fare, currentWallet, `Trip Earning (₹${fare} - ${paymentType.toUpperCase()} payment)`]
          );

          // Record Platform Commission Entry (debit)
          await client.query(
            `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
             VALUES ($1, $2, 'platform_commission', $3, $4, $5)`,
            [driverId, bookingId, -commission, -currentDues, `Platform Commission (10% of ₹${fare})`]
          );

          // For wallet payments: deduct from customer's wallet
          if (paymentType === 'wallet' && booking.customer_id) {
            const custWalletRes = await client.query(
              'SELECT wallet_balance FROM customers WHERE id = $1 FOR UPDATE',
              [booking.customer_id]
            );
            const custBalance = parseFloat(custWalletRes.rows[0]?.wallet_balance || 0);
            const newCustBalance = Math.max(0, custBalance - fare);
            await client.query(
              'UPDATE customers SET wallet_balance = $1 WHERE id = $2',
              [newCustBalance, booking.customer_id]
            );
            await client.query(
              `INSERT INTO customer_wallet_transactions (customer_id, type, amount, balance_after, booking_id, description)
               VALUES ($1, 'booking_payment', $2, $3, $4, $5)`,
              [booking.customer_id, -fare, newCustBalance, bookingId, `Booking fare payment (₹${fare})`]
            );
          }
        } else {
          // Cash: Driver collects full fare directly from customer.
          // Only commission is owed to platform as Amount Due.
          driverNetEarnings = fare;
          currentDues += commission;

          // Record Commission Debit Entry
          await client.query(
            `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
             VALUES ($1, $2, 'platform_commission', $3, $4, $5)`,
            [driverId, bookingId, -commission, -currentDues, `Platform Commission (Cash Fare ₹${fare})`]
          );
        }

        // Update driver wallet & dues
        await client.query(
          `UPDATE drivers SET wallet_balance = $1, outstanding_dues = $2, status = 'online' WHERE id = $3`,
          [currentWallet, currentDues, driverId]
        );

        // Update booking settlement state and waiting charges
        const updateRes = await client.query(
          `UPDATE bookings SET 
             status = 'completed', 
             commission_amount = $1, 
             driver_net_earnings = $2, 
             is_settled = TRUE,
             completed_at = NOW(),
             pickup_wait_minutes = $3,
             dropoff_wait_minutes = $4,
             waiting_charge_pickup = $5,
             waiting_charge_dropoff = $6,
             total_waiting_charge = $7,
             final_cost = $8
           WHERE id = $9 RETURNING *`,
          [commission, driverNetEarnings, pickupWaitMins, dropoffWaitMins, pickupWaitCharge, dropoffWaitCharge, totalWaitingCharge, fare, bookingId]
        );
        updatedBooking = updateRes.rows[0];

        await client.query(
          'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
          [bookingId, 'completed', `Delivery completed. Ledger settled (${paymentType.toUpperCase()} payment mode). Total fare: ₹${fare} (Waiting: ₹${totalWaitingCharge})`]
        );
      } else if (status === 'cancelled') {
        if (booking.status === 'completed' || booking.status === 'expired') {
          return res.status(400).json({ error: 'Cannot cancel an already completed or expired booking.' });
        }

        // M2 fix: compute and persist cancellation metadata, mirroring what DELETE /:id already does.
        const isCustomerCancel = (userId === booking.customer_id);
        const cancellerRole = isCustomerCancel ? 'Customer' : (userId === booking.driver_id ? 'Driver' : 'Admin');
        const cancellationFee = booking.arrived_pickup_at ? 50.00 : 0.00;

        const updateRes = await client.query(
          `UPDATE bookings SET status = 'cancelled', cancelled_by = $1, cancelled_by_role = $2, cancellation_fee = $3 WHERE id = $4 RETURNING *`,
          [userId, cancellerRole, cancellationFee, bookingId]
        );
        updatedBooking = updateRes.rows[0];

        if (booking.driver_id) {
          await client.query("UPDATE drivers SET status = 'online' WHERE id = $1", [booking.driver_id]);
        }
        await client.query(
          'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
          [bookingId, 'cancelled', `Delivery cancelled by ${cancellerRole} (${userId}). Fee: ₹${cancellationFee}`]
        );
      } else {
        // arrived_pickup or arrived_dropoff
        let timeStampCol = status === 'arrived_pickup' ? 'arrived_pickup_at' : (status === 'arrived_dropoff' ? 'arrived_dropoff_at' : null);
        let updateRes;
        if (timeStampCol) {
          updateRes = await client.query(`UPDATE bookings SET status = $1, ${timeStampCol} = COALESCE(${timeStampCol}, NOW()) WHERE id = $2 RETURNING *`, [status, bookingId]);
        } else {
          updateRes = await client.query("UPDATE bookings SET status = $1 WHERE id = $2 RETURNING *", [status, bookingId]);
        }
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

      // Broadcast booking status change to parties only.
      // Audit fix Critical #2: replaced broadcast() with scoped helper.
      broadcastToBookingParties(booking.customer_id, booking.driver_id, { type: 'booking_status', bookingId, status, booking: updatedBooking });

      // If status completed/cancelled, broadcast that driver is online again (no PII — fine for all)
      if ((status === 'completed' || status === 'cancelled') && booking.driver_id) {
        broadcast({ type: 'driver_status', driverId: booking.driver_id, status: 'online' });
      }

      // Send status notifications
      if (status === 'completed') {
        sendOrderStatusNotification(bookingId, 'delivered');
      } else if (status === 'cancelled') {
        const isCustomer = (userId === booking.customer_id);
        const cancellerRole = isCustomer ? 'Customer' : (userId === booking.driver_id ? 'Driver' : 'Admin');
        const cancellationFee = booking.arrived_pickup_at ? 50.00 : 0.00;
        const notifyTarget = isCustomer ? booking.driver_id : booking.customer_id;
        
        sendOrderStatusNotification(bookingId, 'cancelled', {
          cancelledByRole: cancellerRole,
          cancellerId: userId,
          cancellationFee,
          targetUserId: notifyTarget
        });
      } else if (status === 'arrived_pickup') {
        sendOrderStatusNotification(bookingId, 'driver_arrived_pickup');
      } else if (status === 'arrived_dropoff') {
        sendOrderStatusNotification(bookingId, 'driver_arrived_dropoff');
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

// PUT /api/booking/:id/cash-collection-point - Update cash collection point before driver assignment
router.put('/:id/cash-collection-point', verifyToken, async (req, res) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { id } = req.params;
    const userId = req.user.uid;
    const { cashCollectionPoint } = req.body;

    if (cashCollectionPoint !== 'PICKUP' && cashCollectionPoint !== 'DROPOFF') {
      return res.status(400).json({ error: 'Valid cash collection point (PICKUP or DROPOFF) required.' });
    }

    const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [id]);
    if (bookingRes.rows.length === 0) {
      return res.status(404).json({ error: 'Booking not found.' });
    }

    const booking = bookingRes.rows[0];
    if (booking.customer_id !== userId && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Unauthorized to modify this booking.' });
    }

    if (booking.status !== 'pending' || booking.driver_id) {
      return res.status(400).json({ error: 'Cash collection point can only be modified before a driver is assigned.' });
    }

    const updateRes = await client.query(
      "UPDATE bookings SET cash_collection_point = $1 WHERE id = $2 RETURNING *",
      [cashCollectionPoint, id]
    );
    const updatedBooking = updateRes.rows[0];

    await client.query(
      'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
      [id, 'cash_collection_point_updated', `Cash collection point updated to ${cashCollectionPoint}`]
    );

    await client.query('COMMIT');
    broadcast({ type: 'booking_updated', bookingId: id, booking: updatedBooking });

    res.json({ success: true, booking: updatedBooking });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('PUT /api/booking/:id/cash-collection-point error:', err);
    res.status(500).json({ error: 'Failed to update cash collection point.' });
  } finally {
    client.release();
  }
});

// POST /api/booking/unpaid-cash-dispute - Driver reports cash payment not received
router.post(
  '/unpaid-cash-dispute',
  verifyToken,
  [
    body('bookingId').isUUID(),
    body('reason').optional().isString()
  ],
  async (req, res) => {
    try {
      const { bookingId, reason } = req.body;
      const driverId = req.user.uid;

      const bookingRes = await query('SELECT * FROM bookings WHERE id = $1', [bookingId]);
      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Booking not found.' });
      }

      const booking = bookingRes.rows[0];
      if (booking.driver_id !== driverId) {
        return res.status(403).json({ error: 'Unauthorized.' });
      }

      await query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [bookingId, 'unpaid_cash_dispute', `Driver reported unpaid cash dispute: ${reason || 'Payment not received'}`]
      );

      broadcast({
        type: 'unpaid_cash_dispute',
        bookingId,
        driverId,
        reason: reason || 'Payment not received'
      });

      res.json({
        success: true,
        message: 'Unpaid cash dispute registered. VAYA Support team notified.',
        ticketId: `SUP-${Math.floor(100000 + Math.random() * 900000)}`
      });
    } catch (err) {
      console.error('POST /api/booking/unpaid-cash-dispute error:', err);
      res.status(500).json({ error: 'Failed to record dispute.' });
    }
  }
);

// Helper function to calculate settlement summary server-side
async function getOrComputeSettlementSummary(client, bookingId) {
  const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(bookingId);
  let bookingRes;
  if (isUuid) {
    bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1', [bookingId]);
  } else {
    bookingRes = await client.query('SELECT * FROM bookings WHERE id::text ILIKE $1 || \'%\'', [bookingId]);
  }

  if (bookingRes.rows.length === 0) return null;
  const booking = bookingRes.rows[0];
  const realBookingId = booking.id;

  // Fetch pricing config for waiting charges
  const configRes = await client.query('SELECT free_wait_minutes_pickup, free_wait_minutes_dropoff, wait_charge_per_minute FROM pricing_config WHERE vehicle_type = $1', [booking.vehicle_type]);
  const pConfig = configRes.rows[0] || {};
  const freePickupMins = parseInt(pConfig.free_wait_minutes_pickup ?? 10);
  const freeDropoffMins = parseInt(pConfig.free_wait_minutes_dropoff ?? 10);
  const ratePerMin = parseFloat(pConfig.wait_charge_per_minute ?? 2.00);

  const now = new Date();

  // Pickup Wait
  let pickupWaitTotalMins = booking.pickup_wait_minutes || 0;
  if (booking.arrived_pickup_at && booking.pickup_verified_at) {
    const pickupMs = new Date(booking.pickup_verified_at).getTime() - new Date(booking.arrived_pickup_at).getTime();
    pickupWaitTotalMins = Math.max(0, Math.floor(pickupMs / 60000));
  }
  const pickupWaitChargeableMins = Math.max(0, pickupWaitTotalMins - freePickupMins);
  const pickupWaitAmount = Math.round(pickupWaitChargeableMins * ratePerMin * 100) / 100;

  // Dropoff Wait
  let dropoffWaitTotalMins = booking.dropoff_wait_minutes || 0;
  if (booking.arrived_dropoff_at) {
    const dropoffMs = now.getTime() - new Date(booking.arrived_dropoff_at).getTime();
    dropoffWaitTotalMins = Math.max(0, Math.floor(dropoffMs / 60000));
  }
  const dropoffWaitChargeableMins = Math.max(0, dropoffWaitTotalMins - freeDropoffMins);
  const dropoffWaitAmount = Math.round(dropoffWaitChargeableMins * ratePerMin * 100) / 100;

  const baseFare = parseFloat(booking.estimated_cost || 0);
  const totalWaitingCharge = Math.round((pickupWaitAmount + dropoffWaitAmount) * 100) / 100;
  const vayaFareTotal = Math.round((baseFare + totalWaitingCharge) * 100) / 100;

  const paymentMethod = (booking.payment_type || booking.payment_method || 'cash').toLowerCase();
  const isPickupCash = (booking.cash_collection_point === 'PICKUP' || (paymentMethod === 'cash' && booking.cash_collection_point !== 'DROPOFF'));
  const initialCollectionPoint = isPickupCash ? 'pickup' : (paymentMethod === 'cash' ? 'dropoff' : 'online');
  const initialPayer = isPickupCash ? 'sender' : (paymentMethod === 'cash' ? 'receiver' : 'booking_customer');
  const adjustmentPayer = paymentMethod === 'cash' ? 'receiver' : 'customer';

  let amountCollectedAtPickup = 0;
  if (booking.is_pickup_cash_collected || isPickupCash) {
    amountCollectedAtPickup = booking.pickup_amount ? parseFloat(booking.pickup_amount) : (baseFare + pickupWaitAmount);
  }

  let amountPaidOnline = 0;
  if (paymentMethod === 'online' || paymentMethod === 'wallet') {
    amountPaidOnline = baseFare;
  }

  let amountDueNow = Math.max(0, Math.round((vayaFareTotal - amountCollectedAtPickup - amountPaidOnline) * 100) / 100);

  let paymentStatus = 'payment_due';
  if (amountDueNow === 0) {
    paymentStatus = 'paid';
  } else if (amountCollectedAtPickup > 0 && amountDueNow > 0) {
    paymentStatus = 'partially_paid';
  } else if (booking.support_override_approved) {
    paymentStatus = 'support_override_approved';
  } else if (paymentMethod === 'online' || paymentMethod === 'wallet') {
    paymentStatus = 'waiting_for_customer_payment';
  }

  let settlementId = booking.settlement_id;
  let settlementVersion = booking.settlement_version || 1;

  if (!settlementId) {
    settlementId = `SETTLE-${realBookingId.substring(0, 8).toUpperCase()}-${Date.now()}`;
  }

  // Update DB with latest settlement parameters
  await client.query(
    `UPDATE bookings SET
      pickup_wait_minutes = $1,
      dropoff_wait_minutes = $2,
      waiting_charge_pickup = $3,
      waiting_charge_dropoff = $4,
      total_waiting_charge = $5,
      final_cost = $6,
      settlement_id = $7,
      settlement_version = $8,
      amount_collected_at_pickup = $9,
      amount_paid_online = $10,
      amount_due_now = $11
     WHERE id = $12`,
    [
      pickupWaitTotalMins,
      dropoffWaitTotalMins,
      pickupWaitAmount,
      dropoffWaitAmount,
      totalWaitingCharge,
      vayaFareTotal,
      settlementId,
      settlementVersion,
      amountCollectedAtPickup,
      amountPaidOnline,
      amountDueNow,
      realBookingId
    ]
  );

  return {
    settlementId,
    bookingId: realBookingId,
    currency: 'INR',
    baseFare,
    pickupWait: {
      totalMinutes: pickupWaitTotalMins,
      freeMinutes: freePickupMins,
      chargeableMinutes: pickupWaitChargeableMins,
      ratePerMinute: ratePerMin,
      amount: pickupWaitAmount
    },
    dropoffWait: {
      totalMinutes: dropoffWaitTotalMins,
      freeMinutes: freeDropoffMins,
      chargeableMinutes: dropoffWaitChargeableMins,
      ratePerMinute: ratePerMin,
      amount: dropoffWaitAmount
    },
    vayaFareTotal,
    paymentMethod,
    initialCollectionPoint,
    initialPayer,
    adjustmentPayer,
    amountCollectedAtPickup,
    amountPaidOnline,
    amountDueNow,
    paymentStatus,
    settlementVersion,
    tollsParkingIncluded: false,
    tollsParkingMessage: 'Payable separately at actuals, if applicable'
  };
}

// GET /api/booking/:id/settlement-summary
router.get('/:id/settlement-summary', verifyToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const { id } = req.params;
    const summary = await getOrComputeSettlementSummary(client, id);
    if (!summary) {
      return res.status(404).json({ error: 'Booking not found.' });
    }
    res.json(summary);
  } catch (err) {
    console.error('GET /api/booking/:id/settlement-summary error:', err);
    res.status(500).json({ error: 'Failed to load settlement summary.' });
  } finally {
    client.release();
  }
});

// POST /api/booking/complete-delivery
router.post(
  '/complete-delivery',
  verifyToken,
  [
    body('bookingId').isString(),
    body('settlementId').isString(),
    body('otp').isLength({ min: 6, max: 6 }).isNumeric(),
    body('cashCollectedConfirmed').optional().isBoolean(),
    body('idempotencyKey').optional().isString()
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
      const { bookingId, settlementId, settlementVersion, otp, cashCollectedConfirmed, idempotencyKey } = req.body;

      const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(bookingId);
      let bookingRes;
      if (isUuid) {
        bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [bookingId]);
      } else {
        bookingRes = await client.query('SELECT * FROM bookings WHERE id::text ILIKE $1 || \'%\' FOR UPDATE', [bookingId]);
      }

      if (bookingRes.rows.length === 0) {
        return res.status(404).json({ error: 'Booking not found.' });
      }
      const booking = bookingRes.rows[0];
      const realBookingId = booking.id;

      if (booking.driver_id !== driverId && req.user.role !== 'admin') {
        return res.status(403).json({ error: 'Forbidden: You are not assigned to this booking.' });
      }

      if (booking.status === 'completed') {
        return res.status(400).json({ error: 'Booking already completed.', code: 'BOOKING_ALREADY_COMPLETED' });
      }

      if (booking.otp !== otp) {
        return res.status(400).json({ error: 'Invalid drop-off OTP code. Please verify with receiver and retry.', code: 'INVALID_OTP' });
      }

      // Check settlement freshness
      if (booking.settlement_id && booking.settlement_id !== settlementId) {
        return res.status(409).json({
          error: 'Fare updated',
          message: 'Waiting charges or payment status changed. Review the updated summary before completing the delivery.',
          code: 'SETTLEMENT_CHANGED'
        });
      }

      if (settlementVersion && booking.settlement_version && booking.settlement_version > settlementVersion) {
        return res.status(409).json({
          error: 'Fare updated',
          message: 'Waiting charges or payment status changed. Review the updated summary before completing the delivery.',
          code: 'SETTLEMENT_CHANGED'
        });
      }

      // Compute final settlement values
      const currentSettlement = await getOrComputeSettlementSummary(client, bookingId);
      const { vayaFareTotal, amountDueNow, paymentMethod } = currentSettlement;

      if (amountDueNow > 0 && paymentMethod === 'cash' && cashCollectedConfirmed !== true) {
        return res.status(400).json({
          error: 'Cash collection confirmation required',
          message: `Please confirm that you collected ₹${amountDueNow} in cash from the receiver.`,
          code: 'CASH_NOT_CONFIRMED'
        });
      }

      if (amountDueNow > 0 && (paymentMethod === 'online' || paymentMethod === 'wallet') && !booking.support_override_approved) {
        return res.status(400).json({
          error: 'Payment verification pending',
          message: `Waiting for ₹${amountDueNow} payment from customer.`,
          code: 'PAYMENT_PENDING'
        });
      }

      // Perform atomic completion calculations
      const fare = vayaFareTotal;
      const commission = Math.round((fare * 0.10) * 100) / 100;
      const driverNetEarnings = fare;

      // Update driver wallet & dues
      const driverRes = await client.query('SELECT wallet_balance, outstanding_dues FROM drivers WHERE id = $1 FOR UPDATE', [driverId]);
      let currentWallet = parseFloat(driverRes.rows[0]?.wallet_balance || 0);
      let currentDues = parseFloat(driverRes.rows[0]?.outstanding_dues || 0);

      if (paymentMethod === 'online' || paymentMethod === 'wallet') {
        currentWallet += fare;
        currentDues += commission;

        await client.query(
          `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
           VALUES ($1, $2, 'trip_earning', $3, $4, $5)`,
          [driverId, bookingId, fare, currentWallet, `Trip Earning (₹${fare} - ${paymentMethod.toUpperCase()} payment)`]
        );

        await client.query(
          `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
           VALUES ($1, $2, 'platform_commission', $3, $4, $5)`,
          [driverId, bookingId, -commission, -currentDues, `Platform Commission (10% of ₹${fare})`]
        );

        // C2 fix: deduct from customer wallet and record the transaction.
        // Previously this block was missing from /complete-delivery (it only existed in /status),
        // causing wallet payments to credit the driver without ever charging the customer.
        if (paymentMethod === 'wallet' && booking.customer_id) {
          const custWalletRes = await client.query(
            'SELECT wallet_balance FROM customers WHERE id = $1 FOR UPDATE',
            [booking.customer_id]
          );
          const custBalance = parseFloat(custWalletRes.rows[0]?.wallet_balance || 0);
          const newCustBalance = Math.max(0, custBalance - fare);
          await client.query(
            'UPDATE customers SET wallet_balance = $1 WHERE id = $2',
            [newCustBalance, booking.customer_id]
          );
          await client.query(
            `INSERT INTO customer_wallet_transactions (customer_id, type, amount, balance_after, booking_id, description)
             VALUES ($1, 'booking_payment', $2, $3, $4, $5)`,
            [booking.customer_id, -fare, newCustBalance, realBookingId, `Booking fare payment (₹${fare})`]
          );
        }
      } else {
        currentDues += commission;

        await client.query(
          `INSERT INTO partner_ledgers (driver_id, booking_id, entry_type, amount, balance_after, description)
           VALUES ($1, $2, 'platform_commission', $3, $4, $5)`,
          [driverId, bookingId, -commission, -currentDues, `Platform Commission (Cash Fare ₹${fare})`]
        );
      }

      await client.query(
        `UPDATE drivers SET wallet_balance = $1, outstanding_dues = $2, status = 'online' WHERE id = $3`,
        [currentWallet, currentDues, driverId]
      );

      const updateRes = await client.query(
        `UPDATE bookings SET
           status = 'completed',
           commission_amount = $1,
           driver_net_earnings = $2,
           is_settled = TRUE,
           completed_at = NOW(),
           final_cost = $3,
           idempotency_key = $4
         WHERE id = $5 RETURNING *`,
        [commission, driverNetEarnings, fare, idempotencyKey || null, bookingId]
      );
      const updatedBooking = updateRes.rows[0];

      await client.query(
        'INSERT INTO booking_events (booking_id, event_type, description) VALUES ($1, $2, $3)',
        [bookingId, 'completed', `Delivery completed via Delivery Summary settlement. Fare: ₹${fare}`]
      );

      await client.query('COMMIT');

      if (booking.driver_id) {
        await evaluateDriverAccountStatus(booking.driver_id);
      }

      broadcast({ type: 'booking_status', bookingId, status: 'completed', booking: updatedBooking });
      broadcast({ type: 'driver_status', driverId: booking.driver_id, status: 'online' });
      sendOrderStatusNotification(bookingId, 'delivered');

      const receipt = {
        bookingId,
        settlementId: currentSettlement.settlementId,
        customerPaid: fare,
        cashCollectedByDriver: paymentMethod === 'cash' ? fare : (currentSettlement.amountCollectedAtPickup + currentSettlement.amountDueNow),
        platformCommission: commission,
        driverEarning: driverNetEarnings,
        paymentMethod: paymentMethod.toUpperCase(),
        paymentStatus: 'Completed',
        tollsParkingMessage: 'Paid separately at actuals, if applicable',
        completedAt: new Date().toISOString()
      };

      res.json({ success: true, receipt, booking: updatedBooking });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/complete-delivery error:', err);
      res.status(500).json({ error: 'Failed to complete delivery.' });
    } finally {
      client.release();
    }
  }
);

// POST /api/booking/:id/notify-customer-payment
router.post('/:id/notify-customer-payment', verifyToken, async (req, res) => {
  try {
    const { id } = req.params;
    const bookingRes = await query('SELECT customer_id, estimated_cost, amount_due_now, total_waiting_charge FROM bookings WHERE id = $1', [id]);
    if (bookingRes.rows.length === 0) {
      return res.status(404).json({ error: 'Booking not found.' });
    }
    const booking = bookingRes.rows[0];
    const amountDue = booking.amount_due_now || booking.total_waiting_charge || booking.estimated_cost;
    sendOrderStatusNotification(id, 'additional_payment_due', { amountDue });
    res.json({ success: true, message: 'Notification sent to customer.' });
  } catch (err) {
    console.error('POST /api/booking/:id/notify-customer-payment error:', err);
    res.status(500).json({ error: 'Failed to send notification.' });
  }
});

// POST /api/booking/:id/support-override
router.post('/:id/support-override', verifyToken, async (req, res) => {
  try {
    const { id } = req.params;
    await query('UPDATE bookings SET support_override_approved = TRUE WHERE id = $1', [id]);
    broadcast({ type: 'support_override_approved', bookingId: id });
    res.json({ success: true, message: 'Support override approved for booking.' });
  } catch (err) {
    console.error('POST /api/booking/:id/support-override error:', err);
    res.status(500).json({ error: 'Failed to approve support override.' });
  }
});

export default router;
