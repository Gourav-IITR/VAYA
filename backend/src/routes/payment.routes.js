import express from 'express';
import { body, validationResult } from 'express-validator';
import crypto from 'crypto';
import Razorpay from 'razorpay';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { evaluateDriverAccountStatus } from './ledger.routes.js';
import { broadcastToUser } from '../services/websocket.service.js';
import { sendOrderStatusNotification } from '../services/notification.service.js';

const router = express.Router();

// ── Razorpay Instance ──────────────────────────────────────────────────────
// Audit fix High #3: removed `|| ''` fallbacks. If secrets are missing the server
// refuses to start (see server.js startup guard). An empty HMAC secret allows
// anyone to forge a valid Razorpay signature.
const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET;
const RAZORPAY_WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET;

let razorpayInstance = null;
if (RAZORPAY_KEY_ID && RAZORPAY_KEY_SECRET) {
  razorpayInstance = new Razorpay({
    key_id: RAZORPAY_KEY_ID,
    key_secret: RAZORPAY_KEY_SECRET
  });
  console.log('💳 Razorpay initialized (key:', RAZORPAY_KEY_ID.substring(0, 12) + '...)');
} else {
  console.warn('⚠️  Razorpay keys not configured. Payment features disabled.');
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/payment/create-order
// Creates a Razorpay order for booking fare, dues repayment, or wallet topup
// ═══════════════════════════════════════════════════════════════════════════
router.post(
  '/create-order',
  verifyToken,
  [
    body('amount').isFloat({ min: 1 }).withMessage('Amount must be at least ₹1'),
    body('purpose').isIn(['booking_fare', 'dues_repayment', 'wallet_topup']).withMessage('Invalid payment purpose')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    if (!razorpayInstance) {
      return res.status(503).json({ error: 'Payment service not configured. Contact support.' });
    }

    try {
      const userId = req.user.uid;
      const { amount, purpose, bookingId } = req.body;
      const amountPaise = Math.round(parseFloat(amount) * 100);

      // Create Razorpay order
      const order = await razorpayInstance.orders.create({
        amount: amountPaise,
        currency: 'INR',
        receipt: `${purpose}_${userId}_${Date.now()}`,
        notes: {
          user_id: userId,
          purpose: purpose,
          booking_id: bookingId || ''
        }
      });

      // Store order in database
      await query(
        `INSERT INTO payment_orders (razorpay_order_id, user_id, purpose, booking_id, amount, amount_paise)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [order.id, userId, purpose, bookingId || null, parseFloat(amount), amountPaise]
      );

      res.json({
        success: true,
        razorpay_order_id: order.id,
        razorpay_key_id: RAZORPAY_KEY_ID,
        amount: parseFloat(amount),
        amount_paise: amountPaise,
        currency: 'INR'
      });
    } catch (err) {
      console.error('POST /api/payment/create-order error:', err);
      res.status(500).json({ error: 'Failed to create payment order' });
    }
  }
);

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/payment/verify
// Verifies Razorpay payment signature and settles the transaction
// ═══════════════════════════════════════════════════════════════════════════
router.post(
  '/verify',
  verifyToken,
  [
    body('razorpay_payment_id').notEmpty().withMessage('Payment ID required'),
    body('razorpay_order_id').notEmpty().withMessage('Order ID required'),
    body('razorpay_signature').notEmpty().withMessage('Signature required')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      const { razorpay_payment_id, razorpay_order_id, razorpay_signature } = req.body;
      const userId = req.user.uid;

      // 1. Verify HMAC-SHA256 signature.
      // Audit fix High #5 (empty secret): RAZORPAY_KEY_SECRET is guaranteed non-empty
      // by the startup guard in server.js.
      // Audit fix Low #1 (timing-safe compare): replaced !== with timingSafeEqual.
      const expectedSignature = crypto
        .createHmac('sha256', RAZORPAY_KEY_SECRET)
        .update(`${razorpay_order_id}|${razorpay_payment_id}`)
        .digest('hex');

      const sigA = Buffer.from(expectedSignature);
      const sigB = Buffer.from(razorpay_signature);
      if (sigA.length !== sigB.length || !crypto.timingSafeEqual(sigA, sigB)) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Payment verification failed. Invalid signature.' });
      }

      // 2. Fetch and validate payment order
      const orderRes = await client.query(
        'SELECT * FROM payment_orders WHERE razorpay_order_id = $1 FOR UPDATE',
        [razorpay_order_id]
      );

      if (orderRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Payment order not found.' });
      }

      const paymentOrder = orderRes.rows[0];

      // Idempotency: already verified
      if (paymentOrder.status === 'paid') {
        await client.query('ROLLBACK');
        return res.json({ success: true, message: 'Payment already verified.', already_verified: true });
      }

      // Audit fix Medium #5 (ownership check): settle to the order's owner, not
      // the request caller. Without this check any authenticated user could POST
      // a valid Razorpay callback for someone else's order and credit their own wallet.
      if (paymentOrder.user_id !== userId) {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: 'Forbidden: payment order does not belong to you.' });
      }

      // 3. Mark payment order as paid
      await client.query(
        `UPDATE payment_orders SET status = 'paid', razorpay_payment_id = $1, verified_at = CURRENT_TIMESTAMP WHERE id = $2`,
        [razorpay_payment_id, paymentOrder.id]
      );

      // 4. Process based on purpose
      let settlementResult = {};

      if (paymentOrder.purpose === 'wallet_topup') {
        settlementResult = await settleWalletTopup(client, userId, paymentOrder, razorpay_payment_id);
      } else if (paymentOrder.purpose === 'dues_repayment') {
        settlementResult = await settleDuesRepayment(client, userId, paymentOrder, razorpay_payment_id);
      } else if (paymentOrder.purpose === 'booking_fare') {
        // For booking fare, we just mark the payment as verified.
        // The booking creation endpoint will use this verified payment.
        settlementResult = { message: 'Booking fare payment verified. Proceed with booking creation.' };
      }

      await client.query('COMMIT');

      if (paymentOrder.booking_id) {
        sendOrderStatusNotification(paymentOrder.booking_id, 'payment_confirmed', {
          amountPaid: paymentOrder.amount
        });
      }

      res.json({
        success: true,
        verified: true,
        razorpay_payment_id,
        razorpay_order_id,
        purpose: paymentOrder.purpose,
        ...settlementResult
      });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('POST /api/payment/verify error:', err);
      res.status(500).json({ error: 'Payment verification failed.' });
    } finally {
      client.release();
    }
  }
);

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/payment/webhook
// Razorpay server-to-server webhook (backup verification)
// ═══════════════════════════════════════════════════════════════════════════
router.post('/webhook', async (req, res) => {
  try {
    const webhookSignature = req.headers['x-razorpay-signature'];
    const webhookBody = req.rawBody;

    if (!webhookSignature || !webhookBody || !RAZORPAY_WEBHOOK_SECRET) {
      return res.status(400).json({ error: 'Missing webhook signature or body' });
    }

    // Verify webhook signature.
    // Audit fix Low #1 (timing-safe compare): replaced !== with timingSafeEqual.
    const expectedSignature = crypto
      .createHmac('sha256', RAZORPAY_WEBHOOK_SECRET)
      .update(webhookBody)
      .digest('hex');

    const sigA = Buffer.from(expectedSignature);
    const sigB = Buffer.from(webhookSignature);
    if (sigA.length !== sigB.length || !crypto.timingSafeEqual(sigA, sigB)) {
      console.error('⚠️ Razorpay webhook signature mismatch');
      return res.status(400).json({ error: 'Invalid webhook signature' });
    }

    const event = JSON.parse(webhookBody.toString());
    const eventType = event.event;

    console.log(`💳 Razorpay Webhook: ${eventType}`);

    if (eventType === 'payment.captured') {
      const payment = event.payload.payment.entity;
      const orderId = payment.order_id;
      const paymentId = payment.id;
      const eventId = event.account_id + '_' + paymentId + '_' + eventType;

      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        
        // Dedup event
        const dedupRes = await client.query(
          'INSERT INTO razorpay_events (event_id, event_type, payload) VALUES ($1, $2, $3) ON CONFLICT (event_id) DO NOTHING RETURNING id',
          [eventId, eventType, JSON.stringify(event)]
        );
        
        if (dedupRes.rows.length === 0) {
          // Event already processed
          await client.query('ROLLBACK');
        } else {
          // Fetch order with lock
          const orderRes = await client.query(
            "SELECT * FROM payment_orders WHERE razorpay_order_id = $1 AND status <> 'paid' FOR UPDATE",
            [orderId]
          );

          if (orderRes.rows.length > 0) {
            const paymentOrder = orderRes.rows[0];

            // Mark as paid via webhook
            await client.query(
              `UPDATE payment_orders SET status = 'paid', razorpay_payment_id = $1, verified_at = CURRENT_TIMESTAMP WHERE id = $2`,
              [paymentId, paymentOrder.id]
            );

            // Process settlement based on purpose
            if (paymentOrder.purpose === 'wallet_topup') {
              await settleWalletTopup(client, paymentOrder.user_id, paymentOrder, paymentId);
            } else if (paymentOrder.purpose === 'dues_repayment') {
              await settleDuesRepayment(client, paymentOrder.user_id, paymentOrder, paymentId);
            }

            console.log(`💳 Webhook: Settled ${paymentOrder.purpose} for user ${paymentOrder.user_id}`);
          }
          await client.query('COMMIT');
        }
      } catch (err) {
        await client.query('ROLLBACK');
        console.error('💳 Webhook captured error:', err);
      } finally {
        client.release();
      }
    } else if (eventType === 'payment.failed') {
      const payment = event.payload.payment.entity;
      const orderId = payment.order_id;

      await query(
        `UPDATE payment_orders SET status = 'failed' WHERE razorpay_order_id = $1 AND status = 'created'`,
        [orderId]
      );
      console.log(`💳 Webhook: Payment failed for order ${orderId}`);
    } else if (eventType === 'refund.processed') {
      const refund = event.payload.refund.entity;
      await query(
        `UPDATE refunds SET status = 'processed', processed_at = CURRENT_TIMESTAMP WHERE razorpay_refund_id = $1`,
        [refund.id]
      );
      console.log(`💳 Webhook: Refund processed for ${refund.id}`);
    } else if (eventType === 'refund.failed') {
      const refund = event.payload.refund.entity;
      await query(
        `UPDATE refunds SET status = 'failed', processed_at = CURRENT_TIMESTAMP WHERE razorpay_refund_id = $1`,
        [refund.id]
      );
      console.log(`💳 Webhook: Refund failed for ${refund.id}`);
    } else if (eventType === 'qr_code.credited' || eventType === 'order.paid') {
      const entity = event.payload.qr_code ? event.payload.qr_code.entity : event.payload.order.entity;
      const notes = entity.notes || {};
      if (notes.bookingId) {
        await query(
          `UPDATE settlements SET paid_online = final_cost, amount_due = 0, state = 'paid', paid_at = CURRENT_TIMESTAMP WHERE booking_id = $1`,
          [notes.bookingId]
        );
        await query(
          `UPDATE bookings SET is_settled = TRUE WHERE id = $1`,
          [notes.bookingId]
        );
        console.log(`💳 Webhook: Settlement paid via ${eventType} for booking ${notes.bookingId}`);
      }
    } else if (eventType === 'payment_link.paid') {
      const pl = event.payload.payment_link.entity;
      const notes = pl.notes || {};
      if (notes.bookingId) {
        await query(
          `UPDATE settlements SET state = 'paid', paid_at = CURRENT_TIMESTAMP WHERE booking_id = $1`,
          [notes.bookingId]
        );
        if (notes.customerId) {
          await query(
            `UPDATE customers SET outstanding_dues = 0 WHERE id = $1`,
            [notes.customerId]
          );
        }
        console.log(`💳 Webhook: Payment Link paid for booking ${notes.bookingId}`);
      }
    } else if (eventType === 'payout.processed') {
      const payout = event.payload.payout.entity;
      await query(
        `UPDATE payouts SET status = 'processed', utr = $1, processed_at = CURRENT_TIMESTAMP WHERE razorpay_payout_id = $2 OR reference_id = $3`,
        [payout.utr || null, payout.id, payout.reference_id]
      );
      console.log(`💳 Webhook: Payout processed ${payout.id}`);
    } else if (eventType === 'payout.failed' || eventType === 'payout.reversed') {
      const payout = event.payload.payout.entity;
      await query(
        `UPDATE payouts SET status = 'failed', failure_reason = $1, processed_at = CURRENT_TIMESTAMP WHERE razorpay_payout_id = $2 OR reference_id = $3`,
        [payout.failure_reason || 'Payout failed', payout.id, payout.reference_id]
      );
      console.log(`💳 Webhook: Payout failed ${payout.id}`);
    }

    // Always return 200 to acknowledge webhook
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('POST /api/payment/webhook error:', err);
    res.json({ status: 'ok' }); // Still return 200 to avoid retries
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// GET /api/payment/wallet
// Get customer wallet balance and recent transactions
// ═══════════════════════════════════════════════════════════════════════════
router.get('/wallet', verifyToken, async (req, res) => {
  try {
    const userId = req.user.uid;

    const custRes = await query('SELECT wallet_balance FROM customers WHERE id = $1', [userId]);
    if (custRes.rows.length === 0) {
      return res.status(404).json({ error: 'Customer not found' });
    }

    const txnRes = await query(
      'SELECT * FROM customer_wallet_transactions WHERE customer_id = $1 ORDER BY created_at DESC LIMIT 50',
      [userId]
    );

    res.json({
      success: true,
      wallet_balance: parseFloat(custRes.rows[0].wallet_balance || 0),
      transactions: txnRes.rows.map(t => ({
        ...t,
        amount: parseFloat(t.amount),
        balance_after: parseFloat(t.balance_after)
      }))
    });
  } catch (err) {
    console.error('GET /api/payment/wallet error:', err);
    res.status(500).json({ error: 'Failed to fetch wallet data' });
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// Settlement Helper: Wallet Top-up
// ═══════════════════════════════════════════════════════════════════════════
async function settleWalletTopup(client, userId, paymentOrder, razorpayPaymentId) {
  const amount = parseFloat(paymentOrder.amount);

  // Get current wallet balance
  const custRes = await client.query(
    'SELECT wallet_balance FROM customers WHERE id = $1 FOR UPDATE',
    [userId]
  );
  const currentBalance = parseFloat(custRes.rows[0]?.wallet_balance || 0);
  const newBalance = currentBalance + amount;

  // Update customer wallet
  await client.query(
    'UPDATE customers SET wallet_balance = $1 WHERE id = $2',
    [newBalance, userId]
  );

  // Record wallet transaction
  await client.query(
    `INSERT INTO customer_wallet_transactions (customer_id, type, amount, balance_after, razorpay_payment_id, description)
     VALUES ($1, 'topup', $2, $3, $4, $5)`,
    [userId, amount, newBalance, razorpayPaymentId, `Wallet top-up via Razorpay`]
  );

  // Notify user via websocket
  broadcastToUser(userId, {
    type: 'wallet_update',
    wallet_balance: newBalance
  });

  return { wallet_balance: newBalance, message: `₹${amount} added to wallet` };
}

// ═══════════════════════════════════════════════════════════════════════════
// Settlement Helper: Driver Dues Repayment
// ═══════════════════════════════════════════════════════════════════════════
async function settleDuesRepayment(client, userId, paymentOrder, razorpayPaymentId) {
  const amount = parseFloat(paymentOrder.amount);

  // Get current driver dues
  const driverRes = await client.query(
    'SELECT outstanding_dues FROM drivers WHERE id = $1 FOR UPDATE',
    [userId]
  );
  if (driverRes.rows.length === 0) {
    throw new Error('Driver not found');
  }

  const currentDues = parseFloat(driverRes.rows[0].outstanding_dues || 0);
  const newDues = Math.max(0, currentDues - amount);
  const overpayment = Math.max(0, amount - currentDues);

  // Update driver's outstanding dues
  await client.query(
    'UPDATE drivers SET outstanding_dues = $1, dues_due_date = NULL WHERE id = $2',
    [newDues, userId]
  );

  // Credit overpayment to driver wallet balance (Issue #11 fix)
  if (overpayment > 0) {
    await client.query(
      'UPDATE drivers SET wallet_balance = wallet_balance + $1 WHERE id = $2',
      [overpayment, userId]
    );
    // Get updated wallet balance for ledger entry
    const updatedWalletRes = await client.query(
      'SELECT wallet_balance FROM drivers WHERE id = $1',
      [userId]
    );
    const updatedWallet = parseFloat(updatedWalletRes.rows[0]?.wallet_balance || 0);
    await client.query(
      `INSERT INTO partner_ledgers (driver_id, entry_type, amount, balance_after, description)
       VALUES ($1, 'dues_offset', $2, $3, $4)`,
      [userId, overpayment, updatedWallet, `Overpayment credited to wallet (₹${overpayment} excess from dues repayment)`]
    );
  }

  // Record ledger entry
  await client.query(
    `INSERT INTO partner_ledgers (driver_id, entry_type, amount, balance_after, description)
     VALUES ($1, 'direct_repayment', $2, $3, $4)`,
    [userId, amount, -newDues, `Dues Repayment via Razorpay (${razorpayPaymentId})`]
  );

  // Re-evaluate account status
  const updatedStatus = await evaluateDriverAccountStatus(userId);

  // Notify driver via websocket
  broadcastToUser(userId, {
    type: 'ledger_update',
    dues: newDues,
    accountStatus: updatedStatus
  });

  return {
    outstanding_dues: newDues,
    account_status: updatedStatus,
    overpayment_credited: overpayment > 0 ? overpayment : 0,
    message: overpayment > 0 
      ? `₹${amount} dues repayment successful. ₹${overpayment} excess credited to wallet.`
      : `₹${amount} dues repayment successful`
  };
}

/**
 * Initiate a Razorpay refund for a captured payment.
 * @param {string} razorpayPaymentId - The Razorpay payment ID to refund
 * @param {number} amountInr - Amount to refund in INR
 * @param {object} notes - Notes object for the refund
 * @param {string|null} bookingId - Associated booking ID
 * @returns {object} The refund record
 */
export async function refundPayment(razorpayPaymentId, amountInr, notes = {}, bookingId = null) {
  if (!razorpayInstance) {
    throw new Error('Razorpay not configured');
  }

  const amountPaise = Math.round(amountInr * 100);

  // Create Razorpay refund
  const refund = await razorpayInstance.payments.refund(razorpayPaymentId, {
    amount: amountPaise,
    speed: 'optimum',
    notes: {
      ...notes,
      booking_id: bookingId || '',
      reason: notes.reason || 'booking_cancelled_or_expired'
    }
  });

  // Store refund record
  await query(
    `INSERT INTO refunds (booking_id, razorpay_payment_id, razorpay_refund_id, amount, status, speed, notes)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [bookingId, razorpayPaymentId, refund.id, amountInr, 'initiated', 'optimum', JSON.stringify(notes)]
  );

  console.log(`💳 Refund initiated: ${refund.id} for ₹${amountInr} (payment: ${razorpayPaymentId})`);
  return refund;
}

export default router;
