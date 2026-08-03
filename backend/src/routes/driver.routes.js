import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { auth } from '../config/firebase.js';
import { broadcast } from '../services/websocket.service.js';

const router = express.Router();

// GET /api/driver/today-earnings - Fetch sum of earnings for completed bookings today
router.get('/today-earnings', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const result = await query(
      `SELECT COALESCE(SUM(estimated_cost), 0) AS today_earnings, COUNT(*) AS today_count
       FROM bookings 
       WHERE driver_id = $1 AND status = 'completed' AND DATE(created_at) = CURRENT_DATE`,
      [uid]
    );
    const earnings = parseFloat(result.rows[0].today_earnings || 0);
    const count = parseInt(result.rows[0].today_count || 0);
    res.json({ success: true, todayEarnings: earnings, todayCount: count });
  } catch (err) {
    console.error('GET /api/driver/today-earnings error:', err);
    res.status(500).json({ error: 'Failed to fetch today earnings' });
  }
});

// GET /api/driver/trips - Fetch real trip history for the driver
router.get('/trips', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const result = await query(
      `SELECT * FROM bookings WHERE driver_id = $1 ORDER BY created_at DESC`,
      [uid]
    );
    res.json({ success: true, trips: result.rows });
  } catch (err) {
    console.error('GET /api/driver/trips error:', err);
    res.status(500).json({ error: 'Failed to fetch driver trips' });
  }
});

// GET /api/driver/earnings-stats - Fetch detailed real earnings breakdown
router.get('/earnings-stats', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const completedRes = await query(
      `SELECT COALESCE(SUM(estimated_cost), 0) AS total_gross, COUNT(*) AS completed_count
       FROM bookings 
       WHERE driver_id = $1 AND status = 'completed'`,
      [uid]
    );
    const todayRes = await query(
      `SELECT COALESCE(SUM(estimated_cost), 0) AS today_gross, COUNT(*) AS today_count
       FROM bookings 
       WHERE driver_id = $1 AND status = 'completed' AND DATE(created_at) = CURRENT_DATE`,
      [uid]
    );

    const totalGross = parseFloat(completedRes.rows[0].total_gross || 0);
    const completedCount = parseInt(completedRes.rows[0].completed_count || 0);
    const todayGross = parseFloat(todayRes.rows[0].today_gross || 0);
    const todayCount = parseInt(todayRes.rows[0].today_count || 0);

    const platformFee = totalGross * 0.10; // 10% platform fee
    const netEarnings = totalGross - platformFee;

    res.json({
      success: true,
      stats: {
        totalGross,
        completedCount,
        todayGross,
        todayCount,
        platformFee,
        netEarnings,
      }
    });
  } catch (err) {
    console.error('GET /api/driver/earnings-stats error:', err);
    res.status(500).json({ error: 'Failed to fetch earnings stats' });
  }
});

// GET /api/driver/me - Get current driver profile (Auto-creates driver if missing)
router.get('/me', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    let result = await query('SELECT * FROM drivers WHERE id = $1', [uid]);
    if (result.rows.length === 0) {
      const phone = req.user.phone_number || req.user.email || `Driver-${uid.substring(0, 8)}`;
      const name = req.user.name || 'Driver Partner';
      const defaultReg = `OD-02-VAYA-${uid.substring(0, 4).toUpperCase()}`;
      result = await query(
        `INSERT INTO drivers (id, phone, name, vehicle_type, vehicle_reg, weight_capacity, status, is_approved)
         VALUES ($1, $2, $3, 'bike', $4, 20, 'offline', TRUE)
         ON CONFLICT (id) DO UPDATE SET is_approved = TRUE
         RETURNING *`,
        [uid, phone, name, defaultReg]
      );
    }
    return res.json({ exists: true, driver: result.rows[0] });
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
      const { status, name, vehicleType, vehicleReg, weightCapacity, fcmToken } = req.body;
      
      // Check if driver profile already exists
      const existingRes = await query('SELECT * FROM drivers WHERE id = $1', [uid]);
      const driverExists = existingRes.rows.length > 0;
      const currentDriver = existingRes.rows[0];

      let driverData;

      if (driverExists) {
        // Driver profile exists - Perform UPDATE to avoid re-evaluating unique constraints on phone / vehicle_reg
        const updateFields = [];
        const updateParams = [];

        if (status !== undefined) {
          updateParams.push(status);
          updateFields.push(`status = $${updateParams.length}`);
        }
        if (name !== undefined && name.trim().length > 0) {
          updateParams.push(name.trim());
          updateFields.push(`name = $${updateParams.length}`);
        }
        if (vehicleType !== undefined) {
          updateParams.push(vehicleType);
          updateFields.push(`vehicle_type = $${updateParams.length}`);
        }
        if (vehicleReg !== undefined && vehicleReg.trim().length > 0) {
          updateParams.push(vehicleReg.trim().toUpperCase());
          updateFields.push(`vehicle_reg = $${updateParams.length}`);
        }
        if (weightCapacity !== undefined) {
          updateParams.push(parseInt(weightCapacity));
          updateFields.push(`weight_capacity = $${updateParams.length}`);
        }
        if (fcmToken !== undefined) {
          updateParams.push(fcmToken);
          updateFields.push(`fcm_token = $${updateParams.length}`);
        }

        // Always ensure is_approved is TRUE
        updateFields.push(`is_approved = TRUE`);
        updateFields.push(`last_active_at = CURRENT_TIMESTAMP`);

        updateParams.push(uid);
        const updateQuery = `
          UPDATE drivers 
          SET ${updateFields.join(', ')}
          WHERE id = $${updateParams.length}
          RETURNING *
        `;

        const updateRes = await query(updateQuery, updateParams);
        driverData = updateRes.rows[0];
      } else {
        // Driver profile does not exist - Perform INSERT with unique fallback defaults
        const phone = req.user.phone_number || req.body.phone || `Driver-${uid.substring(0, 8)}`;
        const nextName = (name && name.trim().length > 0) ? name.trim() : (req.user.name || 'Driver Partner');
        const nextVehType = vehicleType || 'bike';
        const nextVehReg = (vehicleReg && vehicleReg.trim().length > 0) ? vehicleReg.trim().toUpperCase() : `OD-02-VAYA-${uid.substring(0, 4).toUpperCase()}`;
        const nextCap = weightCapacity ? parseInt(weightCapacity) : 20;
        const nextStatus = status || 'offline';

        const insertQuery = `
          INSERT INTO drivers (id, phone, name, vehicle_type, vehicle_reg, weight_capacity, status, is_approved, fcm_token, last_active_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, TRUE, $8, CURRENT_TIMESTAMP)
          ON CONFLICT (id)
          DO UPDATE SET 
            status = EXCLUDED.status,
            is_approved = TRUE,
            last_active_at = CURRENT_TIMESTAMP,
            fcm_token = COALESCE(EXCLUDED.fcm_token, drivers.fcm_token)
          RETURNING *
        `;

        const insertRes = await query(insertQuery, [uid, phone, nextName, nextVehType, nextVehReg, nextCap, nextStatus, fcmToken || null]);
        driverData = insertRes.rows[0];
      }

      // Set custom user claim role as 'driver'
      try {
        await auth.setCustomUserClaims(uid, { role: 'driver' });
      } catch (authErr) {
        console.warn('Could not set custom user claims:', authErr.message);
      }

      // Broadcast update
      broadcast({ type: 'driver_status', driverId: uid, status: driverData.status, driver: driverData });

      res.json({ success: true, driver: driverData });
    } catch (err) {
      console.error('POST /api/driver/status error:', err);
      res.status(500).json({ error: 'Failed to update driver status' });
    }
  }
);

// POST /api/driver/heartbeat - Driver app ping to keep presence active
router.post(
  '/heartbeat',
  verifyToken,
  async (req, res) => {
    try {
      const uid = req.user.uid;
      await query("UPDATE drivers SET last_active_at = CURRENT_TIMESTAMP WHERE id = $1", [uid]);
      res.json({ success: true });
    } catch (err) {
      console.error('POST /api/driver/heartbeat error:', err);
      res.status(500).json({ error: 'Heartbeat failed' });
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
        'UPDATE drivers SET lat = $1, lng = $2, last_active_at = CURRENT_TIMESTAMP WHERE id = $3 RETURNING *',
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
        vehicleType: driverData.vehicle_type,
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

// GET /api/driver/nearby - Fetch nearby active drivers matching vehicle_type (Public / Read-only query)
router.get('/nearby', async (req, res) => {
  try {
    const { lat, lng, vehicle_type, radius } = req.query;
    const centerLat = parseFloat(lat) || 20.2961;
    const centerLng = parseFloat(lng) || 85.8245;
    const radiusKm = parseFloat(radius) || 15.0;

    let queryText = `
      SELECT id, name, vehicle_type, vehicle_reg, lat, lng, status
      FROM drivers
      WHERE status IN ('online', 'busy') AND is_approved = TRUE AND lat IS NOT NULL AND lng IS NOT NULL
    `;
    const params = [];

    if (vehicle_type) {
      params.push(vehicle_type);
      queryText += ` AND vehicle_type = $${params.length}`;
    }

    const result = await query(queryText, params);
    let drivers = result.rows;

    // Filter by Haversine distance
    drivers = drivers.filter(d => {
      const dLat = parseFloat(d.lat);
      const dLng = parseFloat(d.lng);
      if (isNaN(dLat) || isNaN(dLng)) return false;
      const R = 6371;
      const dLatRad = (dLat - centerLat) * Math.PI / 180;
      const dLngRad = (dLng - centerLng) * Math.PI / 180;
      const a = Math.sin(dLatRad / 2) * Math.sin(dLatRad / 2) +
                Math.cos(centerLat * Math.PI / 180) * Math.cos(dLatRad * Math.PI / 180) *
                Math.sin(dLngRad / 2) * Math.sin(dLngRad / 2);
      const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
      const dist = R * c;
      return dist <= radiusKm;
    });

    // Fallback simulation drivers around pickup when no online DB drivers match
    if (drivers.length === 0) {
      const vehType = vehicle_type || 'bike';
      const timeMs = Date.now();
      const jitter1 = Math.sin(timeMs / 2500) * 0.0004;
      const jitter2 = Math.cos(timeMs / 2500) * 0.0004;

      const offsets = [
        { dLat: 0.0035 + jitter1, dLng: 0.0028 + jitter2 },
        { dLat: -0.0032 - jitter2, dLng: 0.0041 + jitter1 },
        { dLat: 0.0022 + jitter2, dLng: -0.0035 - jitter1 },
        { dLat: -0.0028 - jitter1, dLng: -0.0026 + jitter2 },
      ];
      drivers = offsets.map((off, idx) => ({
        id: `sim_${vehType}_${idx + 1}`,
        name: `Nearby ${vehType.toUpperCase()} Partner ${idx + 1}`,
        vehicle_type: vehType,
        vehicle_reg: `OD-02-VAYA-${idx + 1}`,
        lat: centerLat + off.dLat,
        lng: centerLng + off.dLng,
        status: 'online',
        is_simulated: true,
      }));
    }

    res.json({ success: true, drivers });
  } catch (err) {
    console.error('GET /api/driver/nearby error:', err);
    res.status(500).json({ error: 'Failed to fetch nearby drivers' });
  }
});

// GET /api/driver/bank-details - Fetch driver's saved bank account & UPI details
router.get('/bank-details', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const result = await query(
      'SELECT upi_id, bank_account_no, bank_ifsc, bank_account_name FROM drivers WHERE id = $1',
      [uid]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Driver profile not found' });
    }
    const d = result.rows[0];
    res.json({
      success: true,
      bankDetails: {
        upiId: d.upi_id || '',
        bankAccountNo: d.bank_account_no || '',
        bankIfsc: d.bank_ifsc || '',
        bankAccountName: d.bank_account_name || ''
      }
    });
  } catch (err) {
    console.error('GET /api/driver/bank-details error:', err);
    res.status(500).json({ error: 'Failed to fetch bank details' });
  }
});

// POST /api/driver/bank-details - Update driver's bank account & UPI payout details
router.post(
  '/bank-details',
  verifyToken,
  [
    body('upiId').optional().trim(),
    body('bankAccountNo').optional().trim(),
    body('bankIfsc').optional().trim(),
    body('bankAccountName').optional().trim()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const uid = req.user.uid;
      const { upiId, bankAccountNo, bankIfsc, bankAccountName } = req.body;

      const result = await query(
        `UPDATE drivers 
         SET upi_id = COALESCE($1, upi_id),
             bank_account_no = COALESCE($2, bank_account_no),
             bank_ifsc = COALESCE($3, bank_ifsc),
             bank_account_name = COALESCE($4, bank_account_name)
         WHERE id = $5
         RETURNING upi_id, bank_account_no, bank_ifsc, bank_account_name`,
        [upiId || null, bankAccountNo || null, bankIfsc || null, bankAccountName || null, uid]
      );

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Driver profile not found' });
      }

      const d = result.rows[0];
      res.json({
        success: true,
        message: 'Bank & UPI payout details updated successfully!',
        bankDetails: {
          upiId: d.upi_id || '',
          bankAccountNo: d.bank_account_no || '',
          bankIfsc: d.bank_ifsc || '',
          bankAccountName: d.bank_account_name || ''
        }
      });
    } catch (err) {
      console.error('POST /api/driver/bank-details error:', err);
      res.status(500).json({ error: 'Failed to save bank details' });
    }
  }
);

export default router;
