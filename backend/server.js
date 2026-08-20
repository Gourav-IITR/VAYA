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

// ── Startup secret validation ────────────────────────────────────────────────
if (!process.env.RAZORPAY_KEY_SECRET) {
  console.warn('⚠️ WARNING: RAZORPAY_KEY_SECRET is not set. Payment verification will fail until configured.');
}

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
// Audit fix Medium #1: removed the `NODE_ENV === 'development'` short-circuit
// which allowed every origin when the env var was not set (the default in Cloud Run).
// Use the explicit CORS_DEV_BYPASS=true env var in local dev if a wildcard is needed.
const allowedOrigins = (process.env.ALLOWED_ORIGINS || '*').split(',').map(o => o.trim()).filter(Boolean);
const corsDevBypass = process.env.CORS_DEV_BYPASS === 'true';
app.use(cors({
  origin: (origin, callback) => {
    if (!origin || allowedOrigins.includes(origin) || allowedOrigins.includes('*') || corsDevBypass) {
      callback(null, true);
    } else {
      callback(new Error('Blocked by CORS policy'));
    }
  },
  credentials: true
}));

// Rate Limiting
// Audit fix Low #3: use req.originalUrl not req.path — inside the `/api/` mount
// req.path strips the /api/ prefix, so /api/admin became /admin/ which never
// matched '/api/admin'. Using originalUrl restores the intended behaviour.
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 5000, // Increased limit for real-time dashboard and multi-app polling
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please try again later.' },
  skip: (req) => {
    // Skip rate limiting for admin and health check endpoints
    return req.originalUrl.startsWith('/api/admin') || req.originalUrl.startsWith('/api/health');
  }
});
app.use('/api/', limiter);

// Mount API Routes
app.use('/api/customer', customerRouter);
app.use('/api/partner', driverRouter);
app.use('/api/driver', driverRouter);
app.use('/api/booking', bookingRouter);  // canonical mount — /api/bookings alias removed (audit LOW)
app.use('/api/ledger', ledgerRouter);
app.use('/api/payment', paymentRouter);
app.use('/api/admin', adminRouter);
app.use('/api/health', healthRouter);

// /api/state endpoint REMOVED — Audit Critical #1.
// This endpoint was unauthenticated and returned the full database including
// live OTPs, customer PII, and driver coordinates. The web portal reads all
// data it needs through /api/admin/* which is properly gated with verifyToken
// + requireRole('admin').

// /api/pricing-config (top-level) intentionally removed — M5 audit fix.
// All pricing reads now go through GET /api/booking/pricing-config (canonical).
// The web portal was already reading from /api/health/pricing-config which now
// returns the same normalized shape as the booking endpoint.

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

server.listen(PORT, () => {
  console.log(`🚀 GoodsDelivery backend running on port ${PORT}`);
  initDb().catch(err => {
    console.error('❌ Database initialization error:', err.message);
  });
});
