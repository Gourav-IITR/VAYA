import express from 'express';
import { query } from '../config/db.js';

const router = express.Router();

router.get('/health', async (req, res) => {
  try {
    await query('SELECT 1');
    res.json({
      status: 'healthy',
      database: true,
      timestamp: new Date().toISOString()
    });
  } catch (_err) {
    // Audit fix Medium #2: never echo err.message \u2014 a DB failure can reveal the
    // connection string or internal schema details. Return a boolean flag only.
    res.status(500).json({
      status: 'unhealthy',
      database: false,
      timestamp: new Date().toISOString()
    });
  }
});

// M5 fix: return the same normalized shape as GET /api/booking/pricing-config so the
// web portal admin dashboard and the mobile apps always see identical pricing data.
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
    console.error('GET /api/health/pricing-config error:', err);
    res.status(500).json({ error: 'Failed to fetch pricing configuration' });
  }
});

export default router;
