import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import url from 'url';

import { initDb, query } from './src/config/db.js';
import { auth } from './src/config/firebase.js';
import { registerClient, unregisterClient, broadcast } from './src/services/websocket.service.js';

// Route Imports
import customerRouter from './src/routes/customer.routes.js';
import driverRouter from './src/routes/driver.routes.js';
import bookingRouter from './src/routes/booking.routes.js';
import ledgerRouter from './src/routes/ledger.routes.js';
import paymentRouter from './src/routes/payment.routes.js';
import adminRouter from './src/routes/admin.routes.js';
import healthRouter from './src/routes/health.routes.js';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

// ── Global Middleware ────────────────────────────────────────────────────────
app.use(helmet());
// Parse JSON with raw body capture for Razorpay webhook signature verification
app.use(express.json({
  verify: (req, res, buf) => {
    if (req.originalUrl === '/api/payment/webhook') {
      req.rawBody = buf;
    }
  }
}));

// CORS Configuration
const allowedOrigins = (process.env.ALLOWED_ORIGINS || '*').split(',').map(o => o.trim()).filter(Boolean);
app.use(cors({
  origin: (origin, callback) => {
    if (!origin || allowedOrigins.includes(origin) || allowedOrigins.includes('*') || process.env.NODE_ENV === 'development') {
      callback(null, true);
    } else {
      callback(new Error('Blocked by CORS policy'));
    }
  },
  credentials: true
}));

// Rate Limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 5000, // Increased limit for real-time dashboard and multi-app polling
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please try again later.' },
  skip: (req) => {
    // Skip rate limiting for admin and health check endpoints
    return req.path.startsWith('/api/admin') || req.path.startsWith('/api/health');
  }
});
app.use('/api/', limiter);

// Mount API Routes
app.use('/api/customer', customerRouter);
app.use('/api/driver', driverRouter);
app.use('/api/booking', bookingRouter);
app.use('/api/bookings', bookingRouter);
app.use('/api/ledger', ledgerRouter);
app.use('/api/payment', paymentRouter);
app.use('/api/admin', adminRouter);
app.use('/api/health', healthRouter);

// Top-level state endpoint for web portal & public web dynamic synchronization
app.get('/api/state', async (req, res) => {
  try {
    const driversRes = await query('SELECT id, name, phone, vehicle_type AS "vehicleType", vehicle_reg AS "vehicleReg", weight_capacity AS "weightCapacity", status, lat, lng FROM drivers');
    const bookingsRes = await query('SELECT * FROM bookings ORDER BY created_at DESC LIMIT 50');
    const customersRes = await query('SELECT * FROM customers');
    res.json({
      drivers: driversRes.rows,
      bookings: bookingsRes.rows,
      customers: customersRes.rows
    });
  } catch (err) {
    console.error('GET /api/state error:', err);
    res.status(500).json({ error: 'Failed to fetch state' });
  }
});

// Direct top-level pricing config endpoint
app.get('/api/pricing-config', async (req, res) => {
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
    console.error('GET /api/pricing-config error:', err);
    res.status(500).json({ error: 'Failed to fetch pricing configuration' });
  }
});

// Global Error Handler
app.use((err, req, res, next) => {
  console.error('Unhandled Server Error:', err.stack || err.message);
  res.status(err.status || 500).json({
    error: process.env.NODE_ENV === 'production' ? 'Internal server error' : err.message
  });
});

// ── WebSocket Connection Manager ─────────────────────────────────────────────
server.on('upgrade', async (request, socket, head) => {
  const pathname = url.parse(request.url).pathname;
  if (pathname !== '/ws') {
    socket.destroy();
    return;
  }

  const queryParams = url.parse(request.url, true).query;
  const token = queryParams.token;

  if (!token) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  try {
    const decodedToken = await auth.verifyIdToken(token);
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request, decodedToken);
    });
  } catch (err) {
    console.error('WebSocket upgrade auth failed:', err.message);
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
  }
});

wss.on('connection', (ws, request, decodedToken) => {
  registerClient(ws, decodedToken);
  console.log(`🔌 WS Client Connected: ${decodedToken.uid} (${decodedToken.role || 'no-role'})`);

  ws.on('close', async () => {
    unregisterClient(ws);
    console.log(`🔌 WS Client Disconnected: ${decodedToken.uid}`);
  });

  ws.on('error', (err) => {
    console.error(`🔌 WS Client Error for ${decodedToken.uid}:`, err.message);
    unregisterClient(ws);
  });
});

// Periodic expirations check (Expires pending bookings older than 30 mins)
const checkPendingExpirations = async () => {
  try {
    const res = await query(
      "UPDATE bookings SET status = 'expired' WHERE status = 'pending' AND expires_at < CURRENT_TIMESTAMP RETURNING id"
    );
    if (res.rows.length > 0) {
      console.log(`⏳ Auto-expired ${res.rows.length} pending bookings.`);
      res.rows.forEach(b => {
        broadcast({ type: 'booking_expired', bookingId: b.id });
      });
    }
  } catch (err) {
    console.error('Failed to run pending expirations task:', err.message);
  }
};
setInterval(checkPendingExpirations, 30000); // Run every 30 seconds

// Periodic driver presence check (Auto-marks drivers offline if app force-closed / no ping for >30s)
const checkDriverPresence = async () => {
  try {
    const res = await query(
      `UPDATE drivers 
       SET status = 'offline' 
       WHERE status = 'online' 
         AND (last_active_at IS NULL OR last_active_at < NOW() - INTERVAL '30 seconds')
       RETURNING id, name`
    );
    if (res.rows.length > 0) {
      res.rows.forEach(d => {
        console.log(`📡 [PRESENCE] Driver ${d.name || d.id} auto-marked OFFLINE (App force-closed / backgrounded)`);
        broadcast({ type: 'driver_status', driverId: d.id, status: 'offline' });
      });
    }
  } catch (err) {
    console.error('Failed to run driver presence check:', err.message);
  }
};
setInterval(checkDriverPresence, 15000); // Check presence every 15 seconds

// ── Startup & Initialization ────────────────────────────────────────────────
const PORT = process.env.PORT || 5001;

const startServer = async () => {
  await initDb();
  server.listen(PORT, () => {
    console.log(`🚀 GoodsDelivery backend running on http://localhost:${PORT}`);
  });
};

startServer().catch(err => {
  console.error('❌ Server startup failure:', err.message);
  process.exit(1);
});
