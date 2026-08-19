import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken, requireRole } from '../middleware/auth.js';
import { broadcast } from '../services/websocket.service.js';

const router = express.Router();

// Enforce admin privileges across all admin routes
router.use(verifyToken, requireRole('admin'));

// GET /api/admin/dashboard - KPI Metrics
router.get('/dashboard', async (req, res) => {
  try {
    const totalBookings = await query('SELECT COUNT(*) FROM bookings');
    const activeBookings = await query("SELECT COUNT(*) FROM bookings WHERE status NOT IN ('completed', 'cancelled', 'expired')");
    const completedEarnings = await query("SELECT SUM(estimated_cost) FROM bookings WHERE status = 'completed'");
    
    const driverStats = await query("SELECT status, COUNT(*) FROM drivers GROUP BY status");
    const driverBreakdown = { online: 0, offline: 0, busy: 0 };
    driverStats.rows.forEach(row => {
      if (row.status in driverBreakdown) {
        driverBreakdown[row.status] = parseInt(row.count);
      }
    });

    res.json({
      metrics: {
        totalBookings: parseInt(totalBookings.rows[0].count),
        activeDeliveries: parseInt(activeBookings.rows[0].count),
        completedEarnings: parseFloat(completedEarnings.rows[0].sum || 0.00),
        driversOnline: driverBreakdown.online,
        driversBusy: driverBreakdown.busy,
        driversOffline: driverBreakdown.offline
      }
    });
  } catch (err) {
    console.error('GET /api/admin/dashboard error:', err);
    res.status(500).json({ error: 'Failed to fetch admin stats' });
  }
});

// GET /api/admin/bookings - List all bookings
router.get('/bookings', async (req, res) => {
  try {
    const result = await query(
      `SELECT b.*, c.name as customer_name, c.phone as customer_phone, d.name as driver_name, d.vehicle_reg as driver_plate 
       FROM bookings b 
       LEFT JOIN customers c ON b.customer_id = c.id 
       LEFT JOIN drivers d ON b.driver_id = d.id 
       ORDER BY b.created_at DESC`
    );
    res.json({ bookings: result.rows });
  } catch (err) {
    console.error('GET /api/admin/bookings error:', err);
    res.status(500).json({ error: 'Failed to fetch bookings list' });
  }
});

// GET /api/admin/drivers (and /api/admin/partners) - List all drivers/partners
const getPartnersHandler = async (req, res) => {
  try {
    const result = await query('SELECT * FROM drivers ORDER BY created_at DESC');
    res.json({ drivers: result.rows, partners: result.rows });
  } catch (err) {
    console.error('GET /api/admin/partners error:', err);
    res.status(500).json({ error: 'Failed to fetch partners list' });
  }
};
router.get('/drivers', getPartnersHandler);
router.get('/partners', getPartnersHandler);

// PUT /api/admin/drivers/:id/approve (and /api/admin/partners/:id/approve) - Approve registration
const approvePartnerHandler = async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ errors: errors.array() });
  }

  try {
    const driverId = req.params.id;
    const adminUid = req.user.uid;

    const checkRes = await query('SELECT name FROM drivers WHERE id = $1', [driverId]);
    if (checkRes.rows.length === 0) {
      return res.status(404).json({ error: 'Partner profile not found.' });
    }

    await query('UPDATE drivers SET is_approved = TRUE WHERE id = $1', [driverId]);

    // Log to audit log
    await query(
      'INSERT INTO audit_logs (admin_uid, action, details) VALUES ($1, $2, $3)',
      [adminUid, 'approve_driver', `Approved partner account ${checkRes.rows[0].name} (UID: ${driverId})`]
    );

    res.json({ success: true, message: 'Partner approved successfully.' });
  } catch (err) {
    console.error('PUT /api/admin/partners/:id/approve error:', err);
    res.status(500).json({ error: 'Failed to approve partner account.' });
  }
};

router.put('/drivers/:id/approve', [param('id').notEmpty().withMessage('Partner UID is required')], approvePartnerHandler);
router.put('/partners/:id/approve', [param('id').notEmpty().withMessage('Partner UID is required')], approvePartnerHandler);

// GET /api/admin/audit-log - Fetch audit logs
router.get('/audit-log', async (req, res) => {
  try {
    const result = await query('SELECT * FROM audit_logs ORDER BY created_at DESC LIMIT 200');
    res.json({ logs: result.rows });
  } catch (err) {
    console.error('GET /api/admin/audit-log error:', err);
    res.status(500).json({ error: 'Failed to retrieve audit log.' });
  }
});

// PUT /api/admin/pricing-config - Update pricing rates
router.put(
  '/pricing-config',
  [
    body('pricing').isArray().withMessage('Pricing must be an array'),
    body('pricing.*.vehicle_type').notEmpty().withMessage('vehicle_type is required'),
    body('pricing.*.base_price').isNumeric().withMessage('base_price must be numeric'),
    body('pricing.*.base_distance').isNumeric().withMessage('base_distance must be numeric'),
    body('pricing.*.per_km_price').isNumeric().withMessage('per_km_price must be numeric'),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const { pricing } = req.body;
      const adminUid = req.user.uid;

      for (const item of pricing) {
        await query(
          `INSERT INTO pricing_config (vehicle_type, base_price, base_distance, per_km_price, free_wait_minutes_pickup, free_wait_minutes_dropoff, wait_charge_per_minute)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           ON CONFLICT (vehicle_type) DO UPDATE
           SET base_price = EXCLUDED.base_price,
               base_distance = EXCLUDED.base_distance,
               per_km_price = EXCLUDED.per_km_price,
               free_wait_minutes_pickup = EXCLUDED.free_wait_minutes_pickup,
               free_wait_minutes_dropoff = EXCLUDED.free_wait_minutes_dropoff,
               wait_charge_per_minute = EXCLUDED.wait_charge_per_minute`,
          [
            item.vehicle_type,
            item.base_price,
            item.base_distance,
            item.per_km_price,
            item.free_wait_minutes_pickup ?? 10,
            item.free_wait_minutes_dropoff ?? 10,
            item.wait_charge_per_minute ?? 2.00
          ]
        );
      }

      // Fetch and return the updated pricing configuration
      const result = await query('SELECT * FROM pricing_config');
      const updatedPricing = result.rows.map(r => ({
        vehicle_type: r.vehicle_type,
        base_price: parseFloat(r.base_price),
        base_distance: parseFloat(r.base_distance),
        per_km_price: parseFloat(r.per_km_price),
        description: r.description || '',
        free_wait_minutes_pickup: parseInt(r.free_wait_minutes_pickup ?? 10),
        free_wait_minutes_dropoff: parseInt(r.free_wait_minutes_dropoff ?? 10),
        wait_charge_per_minute: parseFloat(r.wait_charge_per_minute ?? 2.00)
      }));

      // Log to audit log
      await query(
        'INSERT INTO audit_logs (admin_uid, action, details) VALUES ($1, $2, $3)',
        [adminUid, 'update_pricing', `Updated live vehicle pricing configurations`]
      );

      // Broadcast pricing update to connected apps
      broadcast({ type: 'pricing_updated', pricing: updatedPricing });

      res.json({ success: true, message: 'Pricing configuration updated successfully.', pricing: updatedPricing });
    } catch (err) {
      console.error('PUT /api/admin/pricing-config error:', err);
      res.status(500).json({ error: 'Failed to update pricing configuration.' });
    }
  }
);

// GET /api/admin/daily-payouts - Daily report of all drivers owed money (wallet_balance - outstanding_dues > 0)
router.get('/daily-payouts', async (req, res) => {
  try {
    const result = await query(
      `SELECT id, name, phone, vehicle_type, vehicle_reg, wallet_balance, outstanding_dues,
              (wallet_balance - outstanding_dues) AS net_payout_amount,
              upi_id, bank_account_no, bank_ifsc, bank_account_name
       FROM drivers
       WHERE wallet_balance > outstanding_dues
       ORDER BY (wallet_balance - outstanding_dues) DESC`
    );

    const payouts = result.rows.map(r => ({
      driverId: r.id,
      name: r.name,
      phone: r.phone,
      vehicleType: r.vehicle_type,
      vehicleReg: r.vehicle_reg,
      availableBalance: parseFloat(r.wallet_balance || 0),
      outstandingDues: parseFloat(r.outstanding_dues || 0),
      netPayoutAmount: parseFloat(r.net_payout_amount || 0),
      payoutDetails: {
        upiId: r.upi_id || '',
        bankAccountNo: r.bank_account_no || '',
        bankIfsc: r.bank_ifsc || '',
        bankAccountName: r.bank_account_name || ''
      }
    }));

    res.json({
      success: true,
      totalDriversEligible: payouts.length,
      totalPayoutSum: payouts.reduce((acc, p) => acc + p.netPayoutAmount, 0),
      payouts
    });
  } catch (err) {
    console.error('GET /api/admin/daily-payouts error:', err);
    res.status(500).json({ error: 'Failed to fetch daily payouts report' });
  }
});

export default router;
