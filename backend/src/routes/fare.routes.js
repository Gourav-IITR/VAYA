import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { query } from '../config/db.js';

const router = express.Router();

/**
 * Distance calculation helper (Haversine formula in km)
 */
function calculateDistance(lat1, lon1, lat2, lon2) {
  const R = 6371; // Earth radius in km
  const dLat = (lat2 - lat1) * (Math.PI / 180);
  const dLon = (lon2 - lon1) * (Math.PI / 180);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * (Math.PI / 180)) *
      Math.cos(lat2 * (Math.PI / 180)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c; // Distance in km
}

/**
 * POST /api/fare/quote
 * Generate a server-authoritative fare quote valid for 10 minutes.
 */
router.post(
  '/quote',
  [
    body('vehicleType').isIn(['bike', 'three_wheeler', 'ace', 'truck']),
    body('pickupLat').isFloat({ min: -90, max: 90 }),
    body('pickupLng').isFloat({ min: -180, max: 180 }),
    body('dropoffLat').isFloat({ min: -90, max: 90 }),
    body('dropoffLng').isFloat({ min: -180, max: 180 }),
    body('helperCount').optional().isInt({ min: 0, max: 4 }),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    try {
      const { vehicleType, pickupLat, pickupLng, dropoffLat, dropoffLng, helperCount = 0 } = req.body;
      const customerId = req.user ? req.user.uid : null;

      // Fetch pricing config from database
      const pricingRes = await query(
        'SELECT base_price, base_distance, per_km_price FROM pricing_config WHERE vehicle_type = $1',
        [vehicleType]
      );

      if (pricingRes.rows.length === 0) {
        return res.status(400).json({ error: `Pricing config not found for vehicle type: ${vehicleType}` });
      }

      const { base_price, base_distance, per_km_price } = pricingRes.rows[0];
      const distanceKm = Math.max(0.5, calculateDistance(pickupLat, pickupLng, dropoffLat, dropoffLng));

      const basePriceNum = parseFloat(base_price);
      const baseDistNum = parseFloat(base_distance);
      const perKmPriceNum = parseFloat(per_km_price);

      let distancePrice = 0;
      if (distanceKm > baseDistNum) {
        distancePrice = (distanceKm - baseDistNum) * perKmPriceNum;
      }

      const helperCharge = helperCount * 150.0; // ₹150 per helper
      const subtotal = basePriceNum + distancePrice + helperCharge;
      const gstAmount = subtotal * 0.05; // 5% GST
      const totalFare = Math.round((subtotal + gstAmount) * 100) / 100;

      // Expiry time set to 10 minutes from now
      const quoteRes = await query(
        `INSERT INTO fare_quotes 
         (customer_id, vehicle_type, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, 
          distance_km, base_price, distance_price, helper_count, helper_charge, gst_amount, total_fare, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, CURRENT_TIMESTAMP + INTERVAL '10 minutes')
         RETURNING id, expires_at`,
        [
          customerId,
          vehicleType,
          pickupLat,
          pickupLng,
          dropoffLat,
          dropoffLng,
          distanceKm,
          basePriceNum,
          distancePrice,
          helperCount,
          helperCharge,
          gstAmount,
          totalFare,
        ]
      );

      const quote = quoteRes.rows[0];

      return res.json({
        success: true,
        quoteId: quote.id,
        vehicleType,
        distanceKm: Math.round(distanceKm * 100) / 100,
        totalFare,
        expiresAt: quote.expires_at,
        breakdown: {
          basePrice: basePriceNum,
          distancePrice: Math.round(distancePrice * 100) / 100,
          helperCharge,
          gstAmount: Math.round(gstAmount * 100) / 100,
          totalFare,
        },
      });
    } catch (error) {
      console.error('Error generating fare quote:', error);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

/**
 * GET /api/fare/quote/:id
 * Retrieve a fare quote by ID
 */
router.get('/:id', param('id').isUUID(), async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ errors: errors.array() });
  }

  try {
    const { id } = req.params;
    const resQuote = await query(
      `SELECT *, (expires_at < CURRENT_TIMESTAMP) AS is_expired FROM fare_quotes WHERE id = $1`,
      [id]
    );

    if (resQuote.rows.length === 0) {
      return res.status(404).json({ error: 'Fare quote not found' });
    }

    const quote = resQuote.rows[0];
    if (quote.is_expired) {
      return res.status(409).json({ error: 'Fare quote expired. Please request a new quote.', isExpired: true });
    }

    return res.json({
      success: true,
      quoteId: quote.id,
      vehicleType: quote.vehicle_type,
      distanceKm: parseFloat(quote.distance_km),
      totalFare: parseFloat(quote.total_fare),
      expiresAt: quote.expires_at,
      breakdown: {
        basePrice: parseFloat(quote.base_price),
        distancePrice: parseFloat(quote.distance_price),
        helperCharge: parseFloat(quote.helper_charge),
        gstAmount: parseFloat(quote.gst_amount),
        totalFare: parseFloat(quote.total_fare),
      },
    });
  } catch (error) {
    console.error('Error fetching fare quote:', error);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;
