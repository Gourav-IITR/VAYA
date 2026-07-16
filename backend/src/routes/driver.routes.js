import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { auth } from '../config/firebase.js';
import { broadcast } from '../services/websocket.service.js';

const router = express.Router();

// GET /api/driver/me - Get current driver profile
router.get('/me', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const result = await query('SELECT * FROM drivers WHERE id = $1', [uid]);
    if (result.rows.length > 0) {
      return res.json({ exists: true, driver: result.rows[0] });
    }
    return res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/driver/me error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/driver/by-phone/:phone - Find driver by phone (legacy support)
router.get('/by-phone/:phone', verifyToken, async (req, res) => {
  try {
    const { phone } = req.params;
    const result = await query('SELECT * FROM drivers WHERE phone = $1', [phone]);
    if (result.rows.length > 0) {
      return res.json({ exists: true, driver: result.rows[0] });
    }
    return res.json({ exists: false });
  } catch (err) {
    console.error('GET /api/driver/by-phone error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/driver/status - Register driver or update online status
router.post(
  '/status',
  verifyToken,
  [
    body('status').optional().isIn(['offline', 'online', 'busy']).withMessage('Invalid status')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const phone = req.user.phone_number;
      const { status, name, vehicleType, vehicleReg, weightCapacity, fcmToken } = req.body;

      if (!phone) {
        return res.status(400).json({ error: 'Firebase user has no verified phone number.' });
      }

      // Check if driver profile already exists
      const existingRes = await query('SELECT * FROM drivers WHERE id = $1', [uid]);
      const driverExists = existingRes.rows.length > 0;
      const currentDriver = existingRes.rows[0];

      if (status === 'online' || status === 'busy') {
        const isApproved = driverExists ? currentDriver.is_approved : false;
        if (!isApproved) {
          return res.status(403).json({ error: 'Your registration is pending manual admin approval.' });
        }
      }

      const nextStatus = status || (driverExists ? currentDriver.status : 'offline');
      const nextName = name !== undefined ? name : (driverExists ? currentDriver.name : '');
      const nextVehType = vehicleType !== undefined ? vehicleType : (driverExists ? currentDriver.vehicle_type : 'bike');
      const nextVehReg = vehicleReg !== undefined ? vehicleReg : (driverExists ? currentDriver.vehicle_reg : '');
      const nextCap = weightCapacity !== undefined ? parseInt(weightCapacity) : (driverExists ? currentDriver.weight_capacity : 20);
      const nextFcm = fcmToken !== undefined ? fcmToken : (driverExists ? currentDriver.fcm_token : null);

      const upsertQuery = `
        INSERT INTO drivers (id, phone, name, vehicle_type, vehicle_reg, weight_capacity, status, fcm_token)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (id)
        DO UPDATE SET 
          name = EXCLUDED.name,
          vehicle_type = EXCLUDED.vehicle_type,
          vehicle_reg = EXCLUDED.vehicle_reg,
          weight_capacity = EXCLUDED.weight_capacity,
          status = EXCLUDED.status,
          fcm_token = COALESCE(EXCLUDED.fcm_token, drivers.fcm_token)
        RETURNING *
      `;

      const result = await query(upsertQuery, [uid, phone, nextName, nextVehType, nextVehReg, nextCap, nextStatus, nextFcm]);

      const driverData = result.rows[0];

      // Set custom user claim role as 'driver'
      await auth.setCustomUserClaims(uid, { role: 'driver' });

      // Broadcast update
      broadcast({ type: 'driver_status', driverId: uid, status: driverData.status, driver: driverData });

      res.json({ success: true, driver: driverData });
    } catch (err) {
      console.error('POST /api/driver/status error:', err);
      res.status(500).json({ error: 'Failed to update driver status' });
    }
  }
);

// POST /api/driver/position - Update driver GPS location
router.post(
  '/position',
  verifyToken,
  [
    body('lat').isFloat({ min: -90, max: 90 }).withMessage('Invalid latitude'),
    body('lng').isFloat({ min: -180, max: 180 }).withMessage('Invalid longitude')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const { lat, lng } = req.body;

      const result = await query(
        'UPDATE drivers SET lat = $1, lng = $2 WHERE id = $3 RETURNING *',
        [parseFloat(lat), parseFloat(lng), uid]
      );

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Driver profile not found.' });
      }

      const driverData = result.rows[0];

      // Broadcast position update
      broadcast({
        type: 'driver_position',
        driverId: uid,
        lat: driverData.lat,
        lng: driverData.lng,
        status: driverData.status
      });

      res.json({ success: true, driver: driverData });
    } catch (err) {
      console.error('POST /api/driver/position error:', err);
      res.status(500).json({ error: 'Failed to update driver position' });
    }
  }
);

export default router;
