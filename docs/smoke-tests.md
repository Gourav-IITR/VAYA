# Smoke Testing Guide

This guide provides test verification scenarios using standard terminal commands (cURL) to validate the operational health of your backend deployment.

---

## 1. Onboarding Test Scenarios
Replace `[API_URL]` with `http://localhost:5001` or your Cloud Run HTTPS URL.

### Scenario A: Customer Onboarding
1. Register a new customer profile:
   ```bash
   curl -X POST "[API_URL]/api/customer" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_CUSTOMER_TOKEN" \
     -d '{"name": "Biswanath Das"}'
   ```
2. Verify onboarding registration exists:
   ```bash
   curl -H "Authorization: Bearer TEST_CUSTOMER_TOKEN" "[API_URL]/api/customer/me"
   ```

### Scenario B: Driver Onboarding & Admin Approval
1. Register a new driver profile:
   ```bash
   curl -X POST "[API_URL]/api/driver/status" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_DRIVER_TOKEN" \
     -d '{"name": "Anil Mohapatra", "vehicleType": "bike", "vehicleReg": "OD-02-AX-8899", "weightCapacity": 20}'
   ```
2. Check driver profile:
   ```bash
   curl -H "Authorization: Bearer TEST_DRIVER_TOKEN" "[API_URL]/api/driver/me"
   ```
   *Expect: `"is_approved": false`*
3. Approve driver using Admin credentials:
   ```bash
   curl -X PUT "[API_URL]/api/admin/drivers/TEST_DRIVER_UID/approve" \
     -H "Authorization: Bearer TEST_ADMIN_TOKEN"
   ```

---

## 2. Booking Lifecycle Test Scenarios
Once a driver is approved, they can change status and accept bookings.

### Scenario A: Driver Goes Online
1. Set status to `online`:
   ```bash
   curl -X POST "[API_URL]/api/driver/status" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_DRIVER_TOKEN" \
     -d '{"status": "online"}'
   ```

### Scenario B: Customer Books Delivery
1. Post a new booking:
   ```bash
   curl -X POST "[API_URL]/api/booking" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_CUSTOMER_TOKEN" \
     -d '{
       "pickupName": "Master Canteen Square",
       "pickupLat": 20.2961,
       "pickupLng": 85.8245,
       "dropoffName": "Patia Square",
       "dropoffLat": 20.3150,
       "dropoffLng": 85.8178,
       "vehicleType": "bike",
       "weight": 10,
       "estimatedCost": 50.00
     }'
   ```
   *Expect: returns booking JSON with unique `"id"` and status `"pending"`.*

### Scenario C: Driver Position Stream & Assignment
1. Update driver GPS position:
   ```bash
   curl -X POST "[API_URL]/api/driver/position" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_DRIVER_TOKEN" \
     -d '{"lat": 20.2970, "lng": 85.8250}'
   ```
2. Driver accepts delivery offer:
   ```bash
   curl -X POST "[API_URL]/api/booking/accept" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer TEST_DRIVER_TOKEN" \
     -d '{"bookingId": "[INSERT_BOOKING_ID_HERE]"}'
   ```

---

## 3. System Audits Validation
1. Verify audit logs via admin:
   ```bash
   curl -H "Authorization: Bearer TEST_ADMIN_TOKEN" "[API_URL]/api/admin/audit-log"
   ```
   *Expect: JSON output containing logs of creation, acceptance, and approval actions.*
