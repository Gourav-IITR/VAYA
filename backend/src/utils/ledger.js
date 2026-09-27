import { query } from '../config/db.js';

/**
 * Record a double-entry ledger transaction atomically and idempotently.
 * 
 * @param {Object} client Database client (optional for transaction context)
 * @param {Object} params Ledger entry params
 * @param {string} params.account Account identifier ('customer:{id}', 'driver:{id}', 'vaya:revenue', 'vaya:cash_in_transit', 'razorpay:clearing')
 * @param {string} params.entryType Type of transaction ('booking_settlement', 'commission', 'waiting_charge', 'cancellation_fee', 'dues_repayment', 'payout', 'refund')
 * @param {number} params.amount Amount (positive = credit, negative = debit)
 * @param {string} [params.bookingId] UUID of related booking
 * @param {string} [params.paymentId] Related payment ID
 * @param {string} params.idempotencyKey Unique idempotency key
 * @param {string} [params.description] Narrative description
 */
export async function recordLedgerEntry(clientOrPool, {
  account,
  entryType,
  amount,
  bookingId = null,
  paymentId = null,
  idempotencyKey,
  description = ''
}) {
  const db = clientOrPool || { query };

  try {
    const parsedAmount = parseFloat(amount);
    
    // Check if idempotency key already recorded
    const checkRes = await db.query(
      'SELECT id, balance_after FROM ledger_entries WHERE idempotency_key = $1',
      [idempotencyKey]
    );
    if (checkRes.rows.length > 0) {
      return checkRes.rows[0];
    }

    // Insert new ledger entry
    const insertRes = await db.query(
      `INSERT INTO ledger_entries 
       (account, entry_type, amount, booking_id, payment_id, idempotency_key, description)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (idempotency_key) DO NOTHING
       RETURNING *`,
      [account, entryType, parsedAmount, bookingId, paymentId, idempotencyKey, description]
    );

    if (insertRes.rows.length === 0) {
      const existing = await db.query('SELECT * FROM ledger_entries WHERE idempotency_key = $1', [idempotencyKey]);
      return existing.rows[0];
    }

    const entry = insertRes.rows[0];

    // Compute updated cached balance for driver or customer accounts
    if (account.startsWith('driver:')) {
      const driverId = account.replace('driver:', '');
      // Sum all ledger entries for this driver
      const sumRes = await db.query(
        `SELECT COALESCE(SUM(amount), 0) AS total_balance FROM ledger_entries WHERE account = $1`,
        [account]
      );
      const totalBalance = parseFloat(sumRes.rows[0].total_balance);

      // Separate into positive wallet balance and positive outstanding dues if negative
      let walletBalance = Math.max(0, totalBalance);
      let outstandingDues = Math.max(0, -totalBalance);

      let accountStatus = 'active';
      if (outstandingDues >= 1500) {
        accountStatus = 'trip_paused';
      } else if (outstandingDues >= 500) {
        accountStatus = 'cash_restricted';
      }

      await db.query(
        `UPDATE drivers 
         SET wallet_balance = $1, outstanding_dues = $2, account_status = $3
         WHERE id = $4`,
        [walletBalance, outstandingDues, accountStatus, driverId]
      );

      // Update balance_after on ledger entry
      await db.query('UPDATE ledger_entries SET balance_after = $1 WHERE id = $2', [totalBalance, entry.id]);
      entry.balance_after = totalBalance;
    } else if (account.startsWith('customer:')) {
      const customerId = account.replace('customer:', '');
      const sumRes = await db.query(
        `SELECT COALESCE(SUM(amount), 0) AS total_balance FROM ledger_entries WHERE account = $1`,
        [account]
      );
      const totalBalance = parseFloat(sumRes.rows[0].total_balance);

      let vayaCredits = Math.max(0, totalBalance);
      let outstandingDues = Math.max(0, -totalBalance);

      await db.query(
        `UPDATE customers 
         SET vaya_credits = $1, outstanding_dues = $2
         WHERE id = $3`,
        [vayaCredits, outstandingDues, customerId]
      );

      await db.query('UPDATE ledger_entries SET balance_after = $1 WHERE id = $2', [totalBalance, entry.id]);
      entry.balance_after = totalBalance;
    }

    return entry;
  } catch (error) {
    console.error(`Ledger entry recording failed for ${account}:`, error);
    throw error;
  }
}
