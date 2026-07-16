import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { auth } from '../config/firebase.js';

const router = express.Router();

// GET /api/customer/me - Get current customer profile
router.get('/me', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const result = await query('SELECT * FROM customers WHERE id = $1', [uid]);
    if (result.rows.length > 0) {
      return res.json({ exists: true, customer: result.rows[0] });
    }
    return res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/customer/me error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/customer/:phone - Lookup customer profile by phone (legacy support / verify before onboarding)
router.get('/:phone', verifyToken, async (req, res) => {
  try {
    const { phone } = req.params;
    const result = await query('SELECT * FROM customers WHERE phone = $1', [phone]);
    if (result.rows.length > 0) {
      return res.json({ exists: true, customer: result.rows[0] });
    }
    return res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/customer/:phone error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/customer - Create/Update customer profile
router.post(
  '/',
  verifyToken,
  [
    body('name').trim().notEmpty().withMessage('Name is required')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const phone = req.user.phone_number; // Derived securely from Firebase token
      const { name, fcmToken } = req.body;

      if (!phone) {
        return res.status(400).json({ error: 'Firebase user has no verified phone number.' });
      }

      // Upsert query
      const upsertQuery = `
        INSERT INTO customers (id, phone, name, fcm_token)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (id) 
        DO UPDATE SET name = EXCLUDED.name, fcm_token = COALESCE(EXCLUDED.fcm_token, customers.fcm_token)
        RETURNING *
      `;
      
      const result = await query(upsertQuery, [uid, phone, name, fcmToken || null]);
      
      // Set custom user claim role as 'customer'
      await auth.setCustomUserClaims(uid, { role: 'customer' });

      res.json({ success: true, customer: result.rows[0] });
    } catch (err) {
      console.error('POST /api/customer error:', err);
      res.status(500).json({ error: 'Failed to save customer profile' });
    }
  }
);

export default router;
