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

  if (dues > limit * 2) {
    nextStatus = 'trip_paused'; // Escalation Stage 3: High negative balance -> Pause all trip allocations
  } else if (dues > limit || (dueDate && now > dueDate)) {
    nextStatus = 'cash_restricted'; // Escalation Stage 2: Over limit or past due date -> Block cash orders
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

    res.json({
      success: true,
      summary: {
        walletBalance: parseFloat(driverInfo.wallet_balance || 0),
        outstandingDues: parseFloat(driverInfo.outstanding_dues || 0),
        maxNegativeLimit: parseFloat(driverInfo.max_negative_limit || 500),
        accountStatus: driverInfo.account_status || 'active',
        duesDueDate: driverInfo.dues_due_date
      },
      entries: ledgerRes.rows
    });
  } catch (err) {
    console.error('GET /api/ledger/driver error:', err);
    res.status(500).json({ error: 'Failed to fetch ledger' });
  }
});

// POST /api/ledger/repay-dues - Driver direct repayment via UPI / Net banking
router.post(
  '/repay-dues',
  verifyToken,
  [body('amount').isFloat({ min: 1 }).withMessage('Repayment amount must be at least ₹1')],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const amount = parseFloat(req.body.amount);
      const paymentRef = req.body.paymentRef || `UPI-REP-${Date.now()}`;

      const driverRes = await query('SELECT outstanding_dues FROM drivers WHERE id = $1', [uid]);
      if (driverRes.rows.length === 0) {
        return res.status(404).json({ error: 'Driver profile not found' });
      }

      const currentDues = parseFloat(driverRes.rows[0].outstanding_dues || 0);
      const newDues = Math.max(0, currentDues - amount);

      // 1. Update driver's outstanding dues
      await query(
        'UPDATE drivers SET outstanding_dues = $1, dues_due_date = NULL WHERE id = $2',
        [newDues, uid]
      );

      // 2. Record ledger entry
      const ledgerEntry = await query(
        `INSERT INTO partner_ledgers (driver_id, entry_type, amount, balance_after, description)
         VALUES ($1, 'direct_repayment', $2, $3, $4)
         RETURNING *`,
        [uid, amount, -newDues, `Direct UPI Dues Repayment (${paymentRef})`]
      );

      // 3. Re-evaluate account status
      const updatedStatus = await evaluateDriverAccountStatus(uid);

      broadcastToUser(uid, {
        type: 'ledger_update',
        dues: newDues,
        accountStatus: updatedStatus
      });

      res.json({
        success: true,
        message: 'Dues repayment successful!',
        outstandingDues: newDues,
        accountStatus: updatedStatus,
        ledgerEntry: ledgerEntry.rows[0]
      });
    } catch (err) {
      console.error('POST /api/ledger/repay-dues error:', err);
      res.status(500).json({ error: 'Repayment failed' });
    }
  }
);

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
