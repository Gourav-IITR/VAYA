import express from 'express';
import { body, validationResult } from 'express-validator';
import crypto from 'crypto';
import Razorpay from 'razorpay';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { evaluateDriverAccountStatus } from './ledger.routes.js';
import { broadcastToUser } from '../services/websocket.service.js';

const router = express.Router();

// ── Razorpay Instance ──────────────────────────────────────────────────────
const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const RAZORPAY_WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET || '';

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

      // 1. Verify HMAC-SHA256 signature
      const expectedSignature = crypto
        .createHmac('sha256', RAZORPAY_KEY_SECRET)
        .update(`${razorpay_order_id}|${razorpay_payment_id}`)
        .digest('hex');

      if (expectedSignature !== razorpay_signature) {
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

    // Verify webhook signature
    const expectedSignature = crypto
      .createHmac('sha256', RAZORPAY_WEBHOOK_SECRET)
      .update(webhookBody)
      .digest('hex');

    if (expectedSignature !== webhookSignature) {
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

      // Check if already processed
      const orderRes = await query(
        'SELECT * FROM payment_orders WHERE razorpay_order_id = $1',
        [orderId]
      );

      if (orderRes.rows.length > 0 && orderRes.rows[0].status !== 'paid') {
        const paymentOrder = orderRes.rows[0];

        // Mark as paid via webhook
        await query(
          `UPDATE payment_orders SET status = 'paid', razorpay_payment_id = $1, verified_at = CURRENT_TIMESTAMP WHERE id = $2`,
          [paymentId, paymentOrder.id]
        );

        // Process settlement based on purpose
        const client = await pool.connect();
        try {
          await client.query('BEGIN');

          if (paymentOrder.purpose === 'wallet_topup') {
            await settleWalletTopup(client, paymentOrder.user_id, paymentOrder, paymentId);
          } else if (paymentOrder.purpose === 'dues_repayment') {
            await settleDuesRepayment(client, paymentOrder.user_id, paymentOrder, paymentId);
          }

          await client.query('COMMIT');
          console.log(`💳 Webhook: Settled ${paymentOrder.purpose} for user ${paymentOrder.user_id}`);
        } catch (settleErr) {
          await client.query('ROLLBACK');
          console.error('💳 Webhook settlement error:', settleErr);
        } finally {
          client.release();
        }
      }
    } else if (eventType === 'payment.failed') {
      const payment = event.payload.payment.entity;
      const orderId = payment.order_id;

      await query(
        `UPDATE payment_orders SET status = 'failed' WHERE razorpay_order_id = $1 AND status = 'created'`,
        [orderId]
      );
      console.log(`💳 Webhook: Payment failed for order ${orderId}`);
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

  // Update driver's outstanding dues
  await client.query(
    'UPDATE drivers SET outstanding_dues = $1, dues_due_date = NULL WHERE id = $2',
    [newDues, userId]
  );

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
    message: `₹${amount} dues repayment successful`
  };
}

export default router;
