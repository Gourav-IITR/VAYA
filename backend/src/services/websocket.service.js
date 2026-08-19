const wsClients = new Map(); // wsInstance -> decodedToken

export const registerClient = (ws, decodedToken) => {
  wsClients.set(ws, decodedToken);
};

export const unregisterClient = (ws) => {
  wsClients.delete(ws);
};

export const getClientsCount = () => wsClients.size;

// ── Payload sanitizer ─────────────────────────────────────────────────────────
// Strips sensitive fields that must never be sent over WebSocket to any client.
// Audit findings: Critical #2 (OTP / bank data leak via broadcast).
const SENSITIVE_FIELDS = [
  'otp',
  'fcm_token',
  'bank_account_no',
  'bank_ifsc',
  'bank_account_name',
  'upi_id',
];

const sanitizePayload = (message) => {
  if (!message || typeof message !== 'object') return message;

  const sanitized = { ...message };

  // Strip sensitive fields from the top-level object
  SENSITIVE_FIELDS.forEach((f) => {
    if (f in sanitized) delete sanitized[f];
  });

  // Strip from nested 'booking' or 'driver' sub-objects if present
  ['booking', 'driver'].forEach((key) => {
    if (sanitized[key] && typeof sanitized[key] === 'object') {
      const nested = { ...sanitized[key] };
      SENSITIVE_FIELDS.forEach((f) => {
        if (f in nested) delete nested[f];
      });
      sanitized[key] = nested;
    }
  });

  return sanitized;
};

// ── Broadcast helpers ─────────────────────────────────────────────────────────

/**
 * Broadcast to ALL connected clients.
 * Only safe for non-sensitive, public events (driver position updates,
 * booking_expired, driver presence heartbeat). Never include OTP or PII.
 */
export const broadcast = (message) => {
  const payload = JSON.stringify(sanitizePayload(message));
  wsClients.forEach((user, client) => {
    if (client.readyState === 1) { // OPEN
      client.send(payload);
    }
  });
};

/**
 * Broadcast to a specific user by uid.
 * Used for wallet updates, ledger updates, etc.
 */
export const broadcastToUser = (userId, message) => {
  const payload = JSON.stringify(sanitizePayload(message));
  wsClients.forEach((user, client) => {
    if (client.readyState === 1 && user.uid === userId) {
      client.send(payload);
    }
  });
};

/**
 * Broadcast to all clients with a specific role (+ admins always receive).
 */
export const broadcastToRole = (role, message) => {
  const payload = JSON.stringify(sanitizePayload(message));
  wsClients.forEach((user, client) => {
    if (client.readyState === 1 && (user.role === role || user.role === 'admin')) {
      client.send(payload);
    }
  });
};

/**
 * Broadcast a booking event only to the two parties involved (customer + driver)
 * and to any connected admins. This replaces the old broadcast() calls that
 * fanned every booking event out to every connected client.
 *
 * Audit fix: Critical #2 — scoped WebSocket broadcasts.
 *
 * @param {string|null} customerId  Firebase UID of the booking customer
 * @param {string|null} driverId    Firebase UID of the assigned driver (may be null pre-assignment)
 * @param {object}      message     Raw message object (sensitive fields are auto-stripped)
 */
export const broadcastToBookingParties = (customerId, driverId, message) => {
  const payload = JSON.stringify(sanitizePayload(message));
  wsClients.forEach((user, client) => {
    if (client.readyState !== 1) return;
    const isParty =
      (customerId && user.uid === customerId) ||
      (driverId && user.uid === driverId) ||
      user.role === 'admin';
    if (isParty) {
      client.send(payload);
    }
  });
};
