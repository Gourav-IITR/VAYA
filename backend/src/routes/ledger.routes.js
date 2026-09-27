import express from 'express';
import { body, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { broadcastToUser } from '../services/websocket.service.js';

const router = express.Router();

// Helper: Evaluate and update driver's account escalation status based on dues and limits
export const evaluateDriverAccountStatus = async (driverId) => {
  const driverRes = await query(
    'SELECT outstanding_dues, max_negative_limit, account_status, dues_due_date FROM drivers WHERE id = $1',
    [driverId]
  );
  if (driverRes.rows.length === 0) return 'active';

  const driver = driverRes.rows[0];
  const dues = parseFloat(driver.outstanding_dues || 0);
  const limit = parseFloat(driver.max_negative_limit || 500);
  const dueDate = driver.dues_due_date ? new Date(driver.dues_due_date) : null;
  const now = new Date();

  let nextStatus = 'active';

  if (dues >= limit) {
    nextStatus = 'trip_paused'; // Hard block: dues at or above ₹500 → driver must clear dues to continue
  }

  if (nextStatus !== driver.account_status) {
    await query('UPDATE drivers SET account_status = $1 WHERE id = $2', [nextStatus, driverId]);
  }

  return nextStatus;
};

// GET /api/ledger/driver - Fetch driver ledger timeline & dues status
router.get('/driver', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;

    const driverRes = await query(
      'SELECT wallet_balance, outstanding_dues, max_negative_limit, account_status, dues_due_date FROM drivers WHERE id = $1',
      [uid]
    );

    if (driverRes.rows.length === 0) {
      return res.status(404).json({ error: 'Driver not found' });
    }

    const driverInfo = driverRes.rows[0];

    const ledgerRes = await query(
      `SELECT * FROM partner_ledgers WHERE driver_id = $1 ORDER BY created_at DESC LIMIT 100`,
      [uid]
    );

    const entries = ledgerRes.rows.map((row) => ({
      ...row,
      amount: parseFloat(row.amount || 0),
      balance_after: parseFloat(row.balance_after || 0)
    }));

    res.json({
      success: true,
      summary: {
        walletBalance: parseFloat(driverInfo.wallet_balance || 0),
        outstandingDues: parseFloat(driverInfo.outstanding_dues || 0),
        maxNegativeLimit: parseFloat(driverInfo.max_negative_limit || 500),
        accountStatus: driverInfo.account_status || 'active',
        duesDueDate: driverInfo.dues_due_date
      },
      entries
    });
  } catch (err) {
    console.error('GET /api/ledger/driver error:', err);
    res.status(500).json({ error: 'Failed to fetch ledger' });
  }
});

// POST /api/ledger/repay-dues - Driver direct repayment via UPI / Net banking
// This endpoint has been removed. The secure path already exists through POST /api/payment/verify -> settleDuesRepayment.

// POST /api/ledger/dispute-entry - Flag a ledger charge as disputed under review
router.post(
  '/dispute-entry',
  verifyToken,
  [
    body('ledgerId').isInt().withMessage('Invalid ledger entry ID'),
    body('reason').notEmpty().withMessage('Dispute reason is required')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const { ledgerId, reason } = req.body;

      const result = await query(
        `UPDATE partner_ledgers 
         SET is_disputed = TRUE, dispute_reason = $1 
         WHERE id = $2 AND driver_id = $3 
         RETURNING *`,
        [reason, ledgerId, uid]
      );

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Ledger entry not found or unauthorized' });
      }

      res.json({
        success: true,
        message: 'Dispute submitted. Entry placed under review and excluded from penalty calculations.',
        entry: result.rows[0]
      });
    } catch (err) {
      console.error('POST /api/ledger/dispute-entry error:', err);
      res.status(500).json({ error: 'Dispute submission failed' });
    }
  }
);

export default router;
