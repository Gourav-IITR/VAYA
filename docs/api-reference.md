# 📡 VAYA Backend API Reference

**Base URL (Production):** `https://vaya-backend-275777907648.us-central1.run.app`  
**Base URL (Local):** `http://localhost:5001`

All endpoints are prefixed with `/api/`. Authentication uses Firebase ID tokens passed as `Authorization: Bearer <token>` header unless noted otherwise.

---

## Health & System

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/health` | ❌ | Server health check + DB ping |
| `GET` | `/api/pricing-config` | ❌ | Get all vehicle pricing rates |

---

## Customer Routes (`/api/customer`)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/customer/me` | ✅ | Get/sync customer profile |
| `POST` | `/api/customer/me` | ✅ | Update customer profile (name, phone) |
| `POST` | `/api/customer` | ✅ | Register new customer |
| `POST` | `/api/customer/fcm-token` | ✅ | Update FCM push notification token |

---

## Driver Routes (`/api/driver`)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/driver/me` | ✅ | Get/sync driver profile |
| `POST` | `/api/driver/register` | ✅ | Register new driver partner |
| `POST` | `/api/driver/status` | ✅ | Toggle online/offline status |
| `POST` | `/api/driver/position` | ✅ | Stream GPS lat/lng position |
| `POST` | `/api/driver/fcm-token` | ✅ | Update FCM push notification token |
| `POST` | `/api/driver/ping` | ✅ | Heartbeat ping (updates `last_active_at`) |
| `POST` | `/api/driver/payout-account` | ✅ | Configure UPI/bank account details |

---

## Booking Routes (`/api/booking`)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/booking` | ✅ | Create new booking |
| `GET` | `/api/booking/active` | ✅ | Get customer's active booking |
| `GET` | `/api/booking/unrated` | ✅ | Get completed unrated bookings |
| `GET` | `/api/booking/:id` | ✅ | Get booking details by ID |
| `GET` | `/api/bookings` | ✅ | Get booking history |
| `POST` | `/api/booking/accept` | ✅ | Driver accepts a pending booking |
| `POST` | `/api/booking/status` | ✅ | Update booking status (driver) |
| `POST` | `/api/booking/cancel` | ✅ | Cancel booking |
| `POST` | `/api/booking/verify-otp` | ✅ | Verify pickup OTP code |
| `POST` | `/api/booking/rate` | ✅ | Submit rating and review |
| `POST` | `/api/booking/skip-rating` | ✅ | Skip rating for a booking |
| `POST` | `/api/booking/:id/cash-collection-point` | ✅ | Set cash collection point (PICKUP/DROPOFF) |
| `GET` | `/api/booking/pricing-config` | ✅ | Get vehicle pricing config |

### Booking Status Transitions (Driver)
```
pending → accepted → arrived_pickup → picking_up → in_transit → arrived_dropoff → completed
```

### Create Booking Request Body
```json
{
  "pickupName": "MG Road, Bhubaneswar",
  "pickupLat": 20.2961,
  "pickupLng": 85.8245,
  "dropoffName": "Patia Square, Bhubaneswar",
  "dropoffLat": 20.3546,
  "dropoffLng": 85.8197,
  "vehicleType": "bike",
  "weight": 10,
  "estimatedCost": 120.00,
  "paymentType": "cash",
  "senderName": "Gourav",
  "senderPhone": "+919876543210",
  "receiverName": "Rahul",
  "receiverPhone": "+919876543211",
  "goodsCategory": "Documents"
}
```

---

## Ledger Routes (`/api/ledger`)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/ledger/balance` | ✅ | Get driver wallet balance and dues |
| `GET` | `/api/ledger/history` | ✅ | Get driver ledger transaction history |
| `POST` | `/api/ledger/dispute` | ✅ | File a dispute on a ledger entry |

---

## Payment Routes (`/api/payment`)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/payment/create-order` | ✅ | Create Razorpay order |
| `POST` | `/api/payment/verify-payment` | ✅ | Verify Razorpay payment signature |
| `POST` | `/api/payment/webhook` | ❌ | Razorpay webhook receiver |
| `GET` | `/api/payment/wallet` | ✅ | Get customer wallet balance + transactions |

### Create Order Request Body
```json
{
  "amount": 500.00,
  "purpose": "booking_fare",
  "bookingId": "uuid-here"
}
```
`purpose` options: `"booking_fare"`, `"dues_repayment"`, `"wallet_topup"`

---

## Admin Routes (`/api/admin`)

> All admin routes require Firebase ID token with `role: 'admin'` custom claim.

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/admin/dashboard` | ✅🔒 | Dashboard analytics (counts, revenue) |
| `GET` | `/api/admin/drivers` | ✅🔒 | List all drivers (with filters) |
| `GET` | `/api/admin/drivers/pending` | ✅🔒 | List pending driver approvals |
| `POST` | `/api/admin/drivers/:id/approve` | ✅🔒 | Approve a driver |
| `POST` | `/api/admin/drivers/:id/reject` | ✅🔒 | Reject a driver |
| `GET` | `/api/admin/bookings` | ✅🔒 | List all bookings (with filters) |
| `GET` | `/api/admin/pricing` | ✅🔒 | Get pricing configuration |
| `PUT` | `/api/admin/pricing` | ✅🔒 | Update pricing configuration |
| `GET` | `/api/admin/ledger/:driverId` | ✅🔒 | View driver's financial ledger |
| `POST` | `/api/admin/ledger/adjustment` | ✅🔒 | Manual ledger adjustment |
| `GET` | `/api/admin/audit-logs` | ✅🔒 | View admin action audit trail |
| `POST` | `/api/admin/payout` | ✅🔒 | Initiate driver payout |
| `GET` | `/api/admin/disputes` | ✅🔒 | List disputed ledger entries |
| `POST` | `/api/admin/disputes/:id/resolve` | ✅🔒 | Resolve a dispute |

---

## WebSocket API

**Endpoint:** `wss://<host>/ws?token=<firebase_id_token>`

### Connection
1. Client connects with Firebase ID token as query parameter
2. Server verifies token on WebSocket upgrade
3. Client is registered by UID and role

### Server → Client Events

| Event Type | Payload | Description |
|-----------|---------|-------------|
| `new_booking_request` | `{ bookingId, pickup, dropoff, vehicleType, estimatedCost }` | New order available for driver |
| `booking_update` | `{ bookingId, status, driverLat, driverLng }` | Booking status change |
| `booking_expired` | `{ bookingId }` | Pending booking auto-expired |
| `driver_status` | `{ driverId, status }` | Driver online/offline change |
| `booking_accepted` | `{ bookingId, driverId }` | Driver accepted the order |

---

## Error Responses

All errors follow this format:
```json
{
  "error": "Human-readable error message"
}
```

| Status Code | Meaning |
|------------|---------|
| `400` | Bad Request — Invalid input |
| `401` | Unauthorized — Missing or invalid token |
| `403` | Forbidden — Insufficient role |
| `404` | Not Found — Resource doesn't exist |
| `409` | Conflict — Duplicate or state conflict |
| `429` | Too Many Requests — Rate limit exceeded |
| `500` | Internal Server Error |

---

## Rate Limits

- **Global**: 5,000 requests per 15 minutes per IP
- **Exempt**: `/api/admin/*` and `/api/health/*` endpoints
