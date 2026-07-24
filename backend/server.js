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
import adminRouter from './src/routes/admin.routes.js';
import healthRouter from './src/routes/health.routes.js';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

// ── Global Middleware ────────────────────────────────────────────────────────
app.use(helmet());
app.use(express.json());

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
  max: 200, // Limit each IP to 200 requests per window
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please try again later.' }
});
app.use('/api/', limiter);

// Mount API Routes
app.use('/api/customer', customerRouter);
app.use('/api/driver', driverRouter);
app.use('/api/booking', bookingRouter);
app.use('/api/admin', adminRouter);
app.use('/api', healthRouter);

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
    try {
      if (decodedToken.uid) {
        const driverRes = await query('SELECT status FROM drivers WHERE id = $1', [decodedToken.uid]);
        if (driverRes.rows.length > 0 && driverRes.rows[0].status === 'online') {
          await query("UPDATE drivers SET status = 'offline' WHERE id = $1", [decodedToken.uid]);
          broadcast({ type: 'driver_status', driverId: decodedToken.uid, status: 'offline' });
          console.log(`🔴 Auto-set driver ${decodedToken.uid} to offline on disconnect.`);
        }
      }
    } catch (e) {
      console.error('Error setting driver offline on disconnect:', e.message);
    }
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
