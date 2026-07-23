import express from 'express';
import { query } from '../config/db.js';

const router = express.Router();

router.get('/health', async (req, res) => {
  try {
    await query('SELECT 1');
    res.json({
      status: 'healthy',
      database: 'connected',
      timestamp: new Date().toISOString()
    });
  } catch (err) {
    res.status(500).json({
      status: 'unhealthy',
      database: 'disconnected',
      error: err.message,
      timestamp: new Date().toISOString()
    });
  }
});

router.get('/pricing-config', async (req, res) => {
  try {
    const result = await query('SELECT * FROM pricing_config');
    res.json({ pricing: result.rows });
  } catch (err) {
    console.error('GET /api/pricing-config error:', err);
    res.status(500).json({ error: 'Failed to fetch pricing configuration' });
  }
});

export default router;
