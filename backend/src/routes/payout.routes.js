import express from 'express';
import { body, validationResult } from 'express-validator';
import { query, pool } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { recordLedgerEntry } from '../utils/ledger.js';
import razorpayInstance from '../config/razorpay.js';

const router = express.Router();

/**
 * POST /api/driver/payout-account
 * Save bank account or UPI details for driver payouts.
 */
router.post(
  '/payout-account',
  verifyToken,
  [
    body('accountType').isIn(['bank_account', 'vpa']),
    body('accountNumber').optional().isString(),
    body('ifscCode').optional().isString(),
    body('upiId').optional().isString(),
    body('accountHolderName').notEmpty(),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const driverId = req.user.uid;
      const { accountType, accountNumber, ifscCode, upiId, accountHolderName } = req.body;

      // Update driver record
      await query(
        `UPDATE drivers 
         SET bank_name = $1, account_number = $2, ifsc_code = $3, upi_id = $4, payout_status = 'pending_verification'
         WHERE id = $5`,
        [accountType === 'bank_account' ? 'Bank Account' : 'UPI VPA', accountNumber || null, ifscCode || null, upiId || null, driverId]
      );

      // Create or update Razorpay Contact & Fund Account
      let contactId = null;
      let fundAccountId = null;

      try {
        // Create RazorpayX Contact
        const driverRes = await query('SELECT name, phone, email FROM drivers WHERE id = $1', [driverId]);
        const driver = driverRes.rows[0];

        const contact = await razorpayInstance.contacts.create({
          name: accountHolderName || driver.name,
          email: driver.email || `${driverId}@vaya.in`,
          contact: driver.phone,
          type: 'employee',
          reference_id: driverId,
        });
        contactId = contact.id;

        if (accountType === 'vpa' && upiId) {
          const fundAccount = await razorpayInstance.fundAccount.create({
            contact_id: contactId,
            account_type: 'vpa',
            vpa: { address: upiId },
          });
          fundAccountId = fundAccount.id;
        } else if (accountNumber && ifscCode) {
          const fundAccount = await razorpayInstance.fundAccount.create({
            contact_id: contactId,
            account_type: 'bank_account',
            bank_account: {
              name: accountHolderName,
              ifsc: ifscCode,
              account_number: accountNumber,
            },
          });
          fundAccountId = fundAccount.id;
        }

        if (contactId && fundAccountId) {
          await query(
            `UPDATE drivers SET razorpay_contact_id = $1, razorpay_fund_account_id = $2, payout_status = 'verified' WHERE id = $3`,
            [contactId, fundAccountId, driverId]
          );
        }
      } catch (rzpErr) {
        console.error('RazorpayX Contact/Fund Account creation warning:', rzpErr);
      }

      return res.json({
        success: true,
        message: 'Payout account updated successfully.',
        payoutStatus: fundAccountId ? 'verified' : 'pending_verification',
      });
    } catch (error) {
      console.error('POST /api/driver/payout-account error:', error);
      return res.status(500).json({ error: 'Failed to update payout account.' });
    }
  }
);

/**
 * POST /api/driver/withdraw
 * Request instant withdrawal of wallet balance (min ₹100) via RazorpayX Payout.
 */
router.post(
  '/withdraw',
  verifyToken,
  [body('amount').isFloat({ min: 100 })],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const driverId = req.user.uid;
      const amount = parseFloat(req.body.amount);

      const driverRes = await client.query(
        'SELECT wallet_balance, razorpay_fund_account_id, payout_status FROM drivers WHERE id = $1 FOR UPDATE',
        [driverId]
      );

      if (driverRes.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Driver profile not found.' });
      }

      const driver = driverRes.rows[0];
      const availableBalance = parseFloat(driver.wallet_balance || 0);

      if (availableBalance < amount) {
        await client.query('ROLLBACK');
        return res.status(400).json({
          error: `Insufficient wallet balance. Available: ₹${availableBalance.toFixed(2)}, Requested: ₹${amount.toFixed(2)}`,
        });
      }

      if (!driver.razorpay_fund_account_id) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Please setup and verify your payout account before withdrawing.' });
      }

      // Record payout request in `payouts` table
      const payoutRes = await client.query(
        `INSERT INTO payouts (driver_id, fund_account_id, amount, status, mode)
         VALUES ($1, $2, $3, 'processing', 'UPI')
         RETURNING *`,
        [driverId, driver.razorpay_fund_account_id, amount]
      );
      const dbPayout = payoutRes.rows[0];

      // Record double-entry ledger entry debiting driver balance
      await recordLedgerEntry(client, {
        account: `driver:${driverId}`,
        entryType: 'payout',
        amount: -amount,
        paymentId: `payout_${dbPayout.id}`,
        idempotencyKey: `payout_${dbPayout.id}`,
        description: `Instant payout withdrawal of ₹${amount}`,
      });

      // Call RazorpayX Payouts API
      let rzpPayoutId = null;
      let utr = null;
      let payoutStatus = 'processing';

      try {
        const rzpPayout = await razorpayInstance.payouts.create({
          account_number: process.env.RAZORPAYX_ACCOUNT_NUMBER || '233445566778899',
          fund_account_id: driver.razorpay_fund_account_id,
          amount: Math.round(amount * 100), // in paise
          currency: 'INR',
          mode: 'UPI',
          purpose: 'payout',
          queue_if_low_balance: true,
          reference_id: `payout_${dbPayout.id}`,
          narration: 'VAYA Driver Payout',
        });

        rzpPayoutId = rzpPayout.id;
        utr = rzpPayout.utr || null;
        payoutStatus = rzpPayout.status || 'processing';

        await client.query(
          `UPDATE payouts SET razorpay_payout_id = $1, utr = $2, status = $3 WHERE id = $4`,
          [rzpPayoutId, utr, payoutStatus, dbPayout.id]
        );
      } catch (rzpErr) {
        console.error('RazorpayX Payout API error:', rzpErr);
        // Fallback: keep payout marked processing for manual or batch retry
      }

      await client.query('COMMIT');

      // Fetch updated balance
      const updatedDriverRes = await query('SELECT wallet_balance FROM drivers WHERE id = $1', [driverId]);

      return res.json({
        success: true,
        message: 'Payout request initiated successfully.',
        payoutId: dbPayout.id,
        razorpayPayoutId: rzpPayoutId,
        amount,
        status: payoutStatus,
        utr,
        remainingWalletBalance: parseFloat(updatedDriverRes.rows[0].wallet_balance),
      });
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('POST /api/driver/withdraw error:', error);
      return res.status(500).json({ error: 'Failed to process withdrawal.' });
    } finally {
      client.release();
    }
  }
);

/**
 * GET /api/driver/payouts
 * Fetch driver payout history.
 */
router.get('/history', verifyToken, async (req, res) => {
  try {
    const driverId = req.user.uid;
    const payoutsRes = await query(
      `SELECT * FROM payouts WHERE driver_id = $1 ORDER BY created_at DESC LIMIT 50`,
      [driverId]
    );

    return res.json({
      success: true,
      payouts: payoutsRes.rows.map((p) => ({
        id: p.id,
        amount: parseFloat(p.amount),
        status: p.status,
        mode: p.mode,
        utr: p.utr,
        createdAt: p.created_at,
        processedAt: p.processed_at,
      })),
    });
  } catch (error) {
    console.error('GET /api/driver/payouts history error:', error);
    return res.status(500).json({ error: 'Failed to fetch payout history.' });
  }
});

export default router;
