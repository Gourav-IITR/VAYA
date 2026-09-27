import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { recordLedgerEntry } from '../utils/ledger.js';
import razorpayInstance from '../config/razorpay.js';
import { broadcastToBookingParties } from '../services/websocket.service.js';

const router = express.Router();

/**
 * POST /api/booking/:id/settle
 * Freeze final fare, compute waiting charges, create settlement entity and Razorpay order/QR if UPI.
 */
router.post(
  '/:id/settle',
  verifyToken,
  [
    param('id').isUUID(),
    body('paymentMethod').optional().isIn(['cash', 'upi_at_drop', 'vaya_credits', 'pay_later']),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { id } = req.params;
      const driverId = req.user.uid;
      const requestedPaymentMethod = req.body.paymentMethod;

      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [id]);
      if (bookingRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Booking not found.' });
      }

      const booking = bookingRes.rows[0];

      // Fetch pricing config for waiting charge calculation
      const pricingRes = await client.query(
        'SELECT free_wait_minutes_pickup, free_wait_minutes_dropoff, wait_charge_per_minute FROM pricing_config WHERE vehicle_type = $1',
        [booking.vehicle_type]
      );
      const pConfig = pricingRes.rows[0] || {};
      const freePickupMins = parseInt(pConfig.free_wait_minutes_pickup ?? 10);
      const freeDropoffMins = parseInt(pConfig.free_wait_minutes_dropoff ?? 10);
      const ratePerMin = parseFloat(pConfig.wait_charge_per_minute ?? 2.00);

      const now = new Date();

      // Pickup wait calculation
      let pickupWaitTotalMins = booking.pickup_wait_minutes || 0;
      if (booking.arrived_pickup_at && booking.pickup_verified_at) {
        const pickupMs = new Date(booking.pickup_verified_at).getTime() - new Date(booking.arrived_pickup_at).getTime();
        pickupWaitTotalMins = Math.max(0, Math.floor(pickupMs / 60000));
      }
      const pickupWaitChargeableMins = Math.max(0, pickupWaitTotalMins - freePickupMins);
      const pickupWaitAmount = Math.round(pickupWaitChargeableMins * ratePerMin * 100) / 100;

      // Dropoff wait calculation
      let dropoffWaitTotalMins = booking.dropoff_wait_minutes || 0;
      if (booking.arrived_dropoff_at) {
        const dropoffMs = now.getTime() - new Date(booking.arrived_dropoff_at).getTime();
        dropoffWaitTotalMins = Math.max(0, Math.floor(dropoffMs / 60000));
      }
      const dropoffWaitChargeableMins = Math.max(0, dropoffWaitTotalMins - freeDropoffMins);
      const dropoffWaitAmount = Math.round(dropoffWaitChargeableMins * ratePerMin * 100) / 100;

      const baseFare = parseFloat(booking.estimated_cost || 0);
      const totalWaitingCharge = Math.round((pickupWaitAmount + dropoffWaitAmount) * 100) / 100;
      const finalCost = Math.round((baseFare + totalWaitingCharge) * 100) / 100;
      const commissionAmount = Math.round((finalCost * 0.10) * 100) / 100;
      const driverNetEarnings = Math.round((finalCost - commissionAmount) * 100) / 100;

      const paymentMethod = requestedPaymentMethod || booking.payment_type || 'cash';
      const amountPaidOnline = (paymentMethod === 'online' || paymentMethod === 'wallet') ? baseFare : 0;
      const amountDue = Math.max(0, Math.round((finalCost - amountPaidOnline) * 100) / 100);

      // Create or update settlement record
      const settlementRes = await client.query(
        `INSERT INTO settlements 
         (booking_id, base_fare, waiting_charge, final_cost, commission_amount, driver_net_earnings, paid_online, amount_due, payment_method, payer_type, payment_point, state, frozen_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'settling', CURRENT_TIMESTAMP)
         ON CONFLICT (booking_id) DO UPDATE SET
           waiting_charge = EXCLUDED.waiting_charge,
           final_cost = EXCLUDED.final_cost,
           commission_amount = EXCLUDED.commission_amount,
           driver_net_earnings = EXCLUDED.driver_net_earnings,
           amount_due = EXCLUDED.amount_due,
           payment_method = EXCLUDED.payment_method,
           state = 'settling',
           frozen_at = CURRENT_TIMESTAMP
         RETURNING *`,
        [
          booking.id,
          baseFare,
          totalWaitingCharge,
          finalCost,
          commissionAmount,
          driverNetEarnings,
          amountPaidOnline,
          amountDue,
          paymentMethod,
          booking.payer_type || 'receiver',
          booking.payment_point || 'dropoff',
        ]
      );

      const settlement = settlementRes.rows[0];

      // Update booking table with frozen settlement reference & costs
      await client.query(
        `UPDATE bookings SET
           total_waiting_charge = $1,
           final_cost = $2,
           commission_amount = $3,
           driver_net_earnings = $4,
           settlement_id = $5,
           payment_type = $6
         WHERE id = $7`,
        [totalWaitingCharge, finalCost, commissionAmount, driverNetEarnings, settlement.id, paymentMethod, booking.id]
      );

      let razorpayOrder = null;
      let upiString = null;
      let qrImageUrl = null;
      // If payment method is upi_at_drop and amount_due > 0, generate Razorpay Order for single-use QR / in-app intent
      if (paymentMethod === 'upi_at_drop' && amountDue > 0) {
        const orderReceipt = `settle_${booking.id.substring(0, 8)}_${Date.now()}`;
        razorpayOrder = await razorpayInstance.orders.create({
          amount: Math.round(amountDue * 100), // in paise
          currency: 'INR',
          receipt: orderReceipt,
          notes: {
            bookingId: booking.id,
            customerId: booking.customer_id,
            purpose: 'settlement',
          },
        });

        upiString = `upi://pay?pa=vaya.logistics@razorpay&pn=VAYA%20Logistics&tr=${razorpayOrder.id}&am=${amountDue.toFixed(2)}&cu=INR&tn=VAYA%20Booking%20${booking.id.substring(0, 8)}`;
        qrImageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=280x280&data=${encodeURIComponent(upiString)}`;

        // Store payment order record
        await client.query(
          `INSERT INTO payment_orders (user_id, booking_id, razorpay_order_id, amount, status, purpose)
           VALUES ($1, $2, $3, $4, 'created', 'settlement')`,
          [booking.customer_id, booking.id, razorpayOrder.id, amountDue]
        );
      }

      await client.query('COMMIT');

      // Notify customer app & driver app via WebSocket
      broadcastToBookingParties(booking.customer_id, booking.driver_id, {
        type: 'settlement_frozen',
        bookingId: booking.id,
        settlementId: settlement.id,
        finalCost,
        amountDue,
        paymentMethod,
        razorpayOrderId: razorpayOrder ? razorpayOrder.id : null,
      });

      return res.json({
        success: true,
        settlementId: settlement.id,
        bookingId: booking.id,
        baseFare,
        waitingCharge: totalWaitingCharge,
        finalCost,
        amountDue,
        commissionAmount,
        driverNetEarnings,
        paymentMethod,
        state: settlement.state,
        razorpayOrder: razorpayOrder
          ? {
              orderId: razorpayOrder.id,
              amount: amountDue,
              currency: 'INR',
              key: process.env.RAZORPAY_KEY_ID || 'rzp_test_placeholder',
              upiString,
              qrImageUrl,
            }
          : null,
      });
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/:id/settle error:', error);
      return res.status(500).json({ error: 'Failed to freeze settlement.' });
    } finally {
      client.release();
    }
  }
);

/**
 * GET /api/booking/:id/qr-status
 * Check payment status of Razorpay QR order for a settlement.
 */
router.get('/:id/qr-status', verifyToken, async (req, res) => {
  try {
    const { id } = req.params;
    const orderRes = await query(
      `SELECT status, razorpay_order_id, razorpay_payment_id FROM payment_orders WHERE booking_id = $1 AND purpose = 'settlement' ORDER BY created_at DESC LIMIT 1`,
      [id]
    );
    if (orderRes.rows.length === 0) {
      return res.json({ success: true, isPaid: false, status: 'not_found' });
    }
    const order = orderRes.rows[0];
    const isPaid = order.status === 'paid' || order.status === 'captured';

    if (isPaid) {
      // Ensure booking is marked settled if paid
      await query(`UPDATE bookings SET is_settled = TRUE WHERE id = $1`, [id]);
    }

    return res.json({
      success: true,
      isPaid,
      status: order.status,
      orderId: order.razorpay_order_id,
      paymentId: order.razorpay_payment_id,
    });
  } catch (err) {
    console.error('GET /api/booking/:id/qr-status error:', err);
    return res.status(500).json({ error: 'Failed to check QR payment status.' });
  }
});

/**
 * POST /api/booking/:id/confirm-cash
 * Driver confirms cash collection at drop-off.
 */
router.post(
  '/:id/confirm-cash',
  verifyToken,
  [
    param('id').isUUID(),
    body('cashCollectedAmount').isFloat({ min: 0 }),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { id } = req.params;
      const driverId = req.user.uid;
      const cashCollected = parseFloat(req.body.cashCollectedAmount);

      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [id]);
      if (bookingRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Booking not found.' });
      }

      const booking = bookingRes.rows[0];
      if (booking.driver_id !== driverId && req.user.role !== 'admin') {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: 'Unauthorized.' });
      }

      const settlementRes = await client.query('SELECT * FROM settlements WHERE booking_id = $1 FOR UPDATE', [id]);
      if (settlementRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Settlement not frozen. Call /settle first.' });
      }

      const settlement = settlementRes.rows[0];
      const finalCost = parseFloat(settlement.final_cost);
      const commission = parseFloat(settlement.commission_amount);

      // Record double-entry ledger entries for driver & platform
      // Driver keeps cash collected, owes platform commission
      await recordLedgerEntry(client, {
        account: `driver:${driverId}`,
        entryType: 'commission',
        amount: -commission,
        bookingId: booking.id,
        idempotencyKey: `cash_comm_${booking.id}`,
        description: `Commission (10%) for cash booking ${booking.id}`,
      });

      await recordLedgerEntry(client, {
        account: 'vaya:revenue',
        entryType: 'commission',
        amount: commission,
        bookingId: booking.id,
        idempotencyKey: `rev_comm_${booking.id}`,
        description: `Platform commission for booking ${booking.id}`,
      });

      // Handle short payment if driver collected less than final cost
      let shortage = 0;
      if (cashCollected < finalCost) {
        shortage = Math.round((finalCost - cashCollected) * 100) / 100;
        
        // Add shortage to customer outstanding dues
        await recordLedgerEntry(client, {
          account: `customer:${booking.customer_id}`,
          entryType: 'booking_settlement',
          amount: -shortage,
          bookingId: booking.id,
          idempotencyKey: `shortage_cust_${booking.id}`,
          description: `Short payment due for booking ${booking.id}`,
        });

        // Credit driver for the shortage
        await recordLedgerEntry(client, {
          account: `driver:${driverId}`,
          entryType: 'booking_settlement',
          amount: shortage,
          bookingId: booking.id,
          idempotencyKey: `shortage_drv_${booking.id}`,
          description: `Shortage credit for booking ${booking.id}`,
        });
      }

      // Update settlement record state to paid
      await client.query(
        `UPDATE settlements 
         SET cash_drop = $1, state = 'paid', paid_at = CURRENT_TIMESTAMP 
         WHERE id = $2`,
        [cashCollected, settlement.id]
      );

      await client.query(
        `UPDATE bookings SET is_settled = TRUE WHERE id = $1`,
        [booking.id]
      );

      await client.query('COMMIT');

      broadcastToBookingParties(booking.customer_id, booking.driver_id, {
        type: 'cash_payment_confirmed',
        bookingId: booking.id,
        cashCollected,
        shortage,
      });

      return res.json({
        success: true,
        message: 'Cash payment confirmed and settled successfully.',
        cashCollected,
        shortage,
        isSettled: true,
      });
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/:id/confirm-cash error:', error);
      return res.status(500).json({ error: 'Failed to confirm cash payment.' });
    } finally {
      client.release();
    }
  }
);

/**
 * POST /api/booking/:id/pay-later
 * Customer cannot pay at drop point; mark settlement pay-later & credit driver.
 */
router.post(
  '/:id/pay-later',
  verifyToken,
  param('id').isUUID(),
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { id } = req.params;
      const driverId = req.user.uid;

      const bookingRes = await client.query('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [id]);
      if (bookingRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Booking not found.' });
      }

      const booking = bookingRes.rows[0];
      const settlementRes = await client.query('SELECT * FROM settlements WHERE booking_id = $1 FOR UPDATE', [id]);
      if (settlementRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Settlement not frozen.' });
      }

      const settlement = settlementRes.rows[0];
      const finalCost = parseFloat(settlement.final_cost);
      const driverNet = parseFloat(settlement.driver_net_earnings);

      // Record customer due in ledger
      await recordLedgerEntry(client, {
        account: `customer:${booking.customer_id}`,
        entryType: 'booking_settlement',
        amount: -finalCost,
        bookingId: booking.id,
        idempotencyKey: `pay_later_cust_${booking.id}`,
        description: `Unpaid booking due for ${booking.id}`,
      });

      // Credit driver net earnings in full
      await recordLedgerEntry(client, {
        account: `driver:${driverId}`,
        entryType: 'booking_settlement',
        amount: driverNet,
        bookingId: booking.id,
        idempotencyKey: `pay_later_drv_${booking.id}`,
        description: `Driver net earnings for pay-later booking ${booking.id}`,
      });

      // Create Razorpay Payment Link for customer to clear dues
      let paymentLinkUrl = null;
      try {
        const paymentLink = await razorpayInstance.paymentLink.create({
          amount: Math.round(finalCost * 100),
          currency: 'INR',
          accept_partial: false,
          description: `VAYA Delivery Payment Due - Booking #${booking.id.substring(0, 8)}`,
          customer: {
            name: booking.sender_name || 'Customer',
            contact: booking.sender_phone || '+919000000000',
          },
          notify: {
            sms: true,
            email: false,
          },
          reminder_enable: true,
          notes: {
            bookingId: booking.id,
            customerId: booking.customer_id,
            purpose: 'pay_later',
          },
        });
        paymentLinkUrl = paymentLink.short_url;
      } catch (plErr) {
        console.error('Razorpay Payment Link creation error:', plErr);
      }

      // Update settlement state to pay_later
      await client.query(
        `UPDATE settlements SET state = 'pay_later' WHERE id = $1`,
        [settlement.id]
      );

      await client.query(
        `UPDATE bookings SET is_settled = TRUE WHERE id = $1`,
        [booking.id]
      );

      await client.query('COMMIT');

      broadcastToBookingParties(booking.customer_id, booking.driver_id, {
        type: 'pay_later_marked',
        bookingId: booking.id,
        paymentLinkUrl,
      });

      return res.json({
        success: true,
        message: 'Pay-later marked. Driver credited and payment link generated for customer.',
        paymentLinkUrl,
        isSettled: true,
      });
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('POST /api/booking/:id/pay-later error:', error);
      return res.status(500).json({ error: 'Failed to process pay-later.' });
    } finally {
      client.release();
    }
  }
);

export default router;
