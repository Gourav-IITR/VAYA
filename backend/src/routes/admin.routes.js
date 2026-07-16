import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken, requireRole } from '../middleware/auth.js';

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

// GET /api/admin/drivers - List all drivers
router.get('/drivers', async (req, res) => {
  try {
    const result = await query('SELECT * FROM drivers ORDER BY created_at DESC');
    res.json({ drivers: result.rows });
  } catch (err) {
    console.error('GET /api/admin/drivers error:', err);
    res.status(500).json({ error: 'Failed to fetch drivers list' });
  }
});

// PUT /api/admin/drivers/:id/approve - Approve registration
router.put(
  '/drivers/:id/approve',
  [
    param('id').notEmpty().withMessage('Driver UID is required')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const driverId = req.params.id;
      const adminUid = req.user.uid;

      const checkRes = await query('SELECT name FROM drivers WHERE id = $1', [driverId]);
      if (checkRes.rows.length === 0) {
        return res.status(404).json({ error: 'Driver profile not found.' });
      }

      await query('UPDATE drivers SET is_approved = TRUE WHERE id = $1', [driverId]);

      // Log to audit log
      await query(
        'INSERT INTO audit_logs (admin_uid, action, details) VALUES ($1, $2, $3)',
        [adminUid, 'approve_driver', `Approved driver account ${checkRes.rows[0].name} (UID: ${driverId})`]
      );

      res.json({ success: true, message: 'Driver approved successfully.' });
    } catch (err) {
      console.error('PUT /api/admin/drivers/:id/approve error:', err);
      res.status(500).json({ error: 'Failed to approve driver account.' });
    }
  }
);

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

export default router;
