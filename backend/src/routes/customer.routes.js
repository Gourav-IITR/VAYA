import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';
import { verifyToken } from '../middleware/auth.js';
import { auth } from '../config/firebase.js';

const router = express.Router();

// GET /api/customer/me - Get current customer profile (Auto-creates customer if missing)
router.get('/me', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    let result = await query('SELECT * FROM customers WHERE id = $1', [uid]);
    if (result.rows.length === 0) {
      const phone = (req.user.phone_number && req.user.phone_number.trim().length > 0)
        ? req.user.phone_number.trim()
        : (req.user.email || '');
      const name = req.user.name || '';
      result = await query(
        `INSERT INTO customers (id, phone, name)
         VALUES ($1, $2, $3)
         ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name
         RETURNING *`,
        [uid, phone, name]
      );
    }
    return res.json({ exists: true, customer: result.rows[0] });
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

// POST /api/customer - Create/Update customer profile & preferences
router.post(
  '/',
  verifyToken,
  async (req, res) => {
    try {
      const uid = req.user.uid;
      const phone = (req.user.phone_number && req.user.phone_number.trim().length > 0)
        ? req.user.phone_number.trim()
        : (req.body.phone && req.body.phone.trim().length > 0
          ? req.body.phone.trim()
          : '');
      
      const {
        name,
        email,
        companyName,
        gstin,
        billingAddress,
        gstStatus,
        notifyBookingUpdates,
        notifyLiveTracking,
        notifyOffers,
        notifyWhatsApp,
        appLanguage,
        savedAddresses,
        fcmToken
      } = req.body;

      // Check if customer exists
      const existingRes = await query('SELECT * FROM customers WHERE id = $1', [uid]);
      let customerData;

      if (existingRes.rows.length > 0) {
        const updateFields = [];
        const updateParams = [];

        if (name !== undefined) {
          updateParams.push(name.trim());
          updateFields.push(`name = $${updateParams.length}`);
        }
        if (email !== undefined) {
          updateParams.push(email.trim());
          updateFields.push(`email = $${updateParams.length}`);
        }
        if (phone.length > 0) {
          updateParams.push(phone);
          updateFields.push(`phone = $${updateParams.length}`);
        }
        if (companyName !== undefined) {
          updateParams.push(companyName.trim());
          updateFields.push(`company_name = $${updateParams.length}`);
        }
        if (gstin !== undefined) {
          updateParams.push(gstin.trim().toUpperCase());
          updateFields.push(`gstin = $${updateParams.length}`);
        }
        if (billingAddress !== undefined) {
          updateParams.push(billingAddress.trim());
          updateFields.push(`billing_address = $${updateParams.length}`);
        }
        if (gstStatus !== undefined) {
          updateParams.push(gstStatus);
          updateFields.push(`gst_status = $${updateParams.length}`);
        }
        if (notifyBookingUpdates !== undefined) {
          updateParams.push(Boolean(notifyBookingUpdates));
          updateFields.push(`notify_booking_updates = $${updateParams.length}`);
        }
        if (notifyLiveTracking !== undefined) {
          updateParams.push(Boolean(notifyLiveTracking));
          updateFields.push(`notify_live_tracking = $${updateParams.length}`);
        }
        if (notifyOffers !== undefined) {
          updateParams.push(Boolean(notifyOffers));
          updateFields.push(`notify_offers = $${updateParams.length}`);
        }
        if (notifyWhatsApp !== undefined) {
          updateParams.push(Boolean(notifyWhatsApp));
          updateFields.push(`notify_whatsapp = $${updateParams.length}`);
        }
        if (appLanguage !== undefined) {
          updateParams.push(appLanguage);
          updateFields.push(`app_language = $${updateParams.length}`);
        }
        if (savedAddresses !== undefined) {
          updateParams.push(JSON.stringify(savedAddresses));
          updateFields.push(`saved_addresses = $${updateParams.length}::jsonb`);
        }
        if (fcmToken !== undefined) {
          updateParams.push(fcmToken);
          updateFields.push(`fcm_token = $${updateParams.length}`);
        }

        if (updateFields.length > 0) {
          updateParams.push(uid);
          const updateQuery = `
            UPDATE customers
            SET ${updateFields.join(', ')}
            WHERE id = $${updateParams.length}
            RETURNING *
          `;
          const updateRes = await query(updateQuery, updateParams);
          customerData = updateRes.rows[0];
        } else {
          customerData = existingRes.rows[0];
        }
      } else {
        // Insert new customer
        const insertQuery = `
          INSERT INTO customers (
            id, phone, name, email, company_name, gstin, billing_address, gst_status,
            notify_booking_updates, notify_live_tracking, notify_offers, notify_whatsapp,
            app_language, saved_addresses, fcm_token
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::jsonb, $15)
          RETURNING *
        `;
        const insertRes = await query(insertQuery, [
          uid,
          phone,
          name || 'Customer',
          email || null,
          companyName || null,
          gstin || null,
          billingAddress || null,
          gstStatus || 'Not added',
          notifyBookingUpdates !== undefined ? Boolean(notifyBookingUpdates) : true,
          notifyLiveTracking !== undefined ? Boolean(notifyLiveTracking) : true,
          notifyOffers !== undefined ? Boolean(notifyOffers) : false,
          notifyWhatsApp !== undefined ? Boolean(notifyWhatsApp) : true,
          appLanguage || 'English',
          JSON.stringify(savedAddresses || []),
          fcmToken || null
        ]);
        customerData = insertRes.rows[0];
      }

      // Set custom user claim role as 'customer'
      try {
        await auth.setCustomUserClaims(uid, { role: 'customer' });
      } catch (authErr) {
        console.warn('Could not set custom user claims:', authErr.message);
      }

      res.json({ success: true, customer: customerData });
    } catch (err) {
      console.error('POST /api/customer error:', err);
      res.status(500).json({ error: 'Failed to save customer profile' });
    }
  }
);

// POST /api/customer/support-ticket - Create support ticket / callback / dispute / data export request
router.post('/support-ticket', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { type, details } = req.body;
    if (!type) {
      return res.status(400).json({ error: 'Ticket type is required' });
    }

    const result = await query(
      `INSERT INTO support_tickets (user_id, user_role, type, details, status)
       VALUES ($1, 'customer', $2, $3::jsonb, 'open')
       RETURNING *`,
      [uid, type, JSON.stringify(details || {})]
    );

    res.json({ success: true, ticket: result.rows[0] });
  } catch (err) {
    console.error('POST /api/customer/support-ticket error:', err);
    res.status(500).json({ error: 'Failed to create support ticket' });
  }
});

// DELETE /api/customer/me - Soft delete customer account in DB
router.delete('/me', verifyToken, async (req, res) => {
  try {
    const uid = req.user.uid;
    await query(
      `UPDATE customers SET account_status = 'deleted' WHERE id = $1`,
      [uid]
    );
    res.json({ success: true, message: 'Account deactivated and queued for deletion.' });
  } catch (err) {
    console.error('DELETE /api/customer/me error:', err);
    res.status(500).json({ error: 'Failed to deactivate account' });
  }
});

export default router;
