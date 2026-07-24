-- Production Database Schema for GoodsDeliveryApp

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Customers Table
CREATE TABLE IF NOT EXISTS customers (
    id VARCHAR(128) PRIMARY KEY, -- Firebase UID
    phone VARCHAR(15) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    fcm_token VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Drivers Table
CREATE TABLE IF NOT EXISTS drivers (
    id VARCHAR(128) PRIMARY KEY, -- Firebase UID
    phone VARCHAR(15) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    vehicle_type VARCHAR(20) NOT NULL, -- 'bike', 'mini_truck', 'large_truck'
    vehicle_reg VARCHAR(30) UNIQUE NOT NULL,
    weight_capacity INT NOT NULL,
    status VARCHAR(20) DEFAULT 'offline', -- 'offline', 'online', 'busy'
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    is_approved BOOLEAN DEFAULT FALSE,
    fcm_token VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Bookings Table
CREATE TABLE IF NOT EXISTS bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id VARCHAR(128) REFERENCES customers(id) ON DELETE SET NULL,
    driver_id VARCHAR(128) REFERENCES drivers(id) ON DELETE SET NULL,
    pickup_name VARCHAR(255) NOT NULL,
    pickup_lat DOUBLE PRECISION NOT NULL,
    pickup_lng DOUBLE PRECISION NOT NULL,
    dropoff_name VARCHAR(255) NOT NULL,
    dropoff_lat DOUBLE PRECISION NOT NULL,
    dropoff_lng DOUBLE PRECISION NOT NULL,
    vehicle_type VARCHAR(20) NOT NULL,
    weight INT NOT NULL,
    estimated_cost DECIMAL(10, 2) NOT NULL,
    status VARCHAR(30) DEFAULT 'pending', -- 'pending', 'accepted', 'arrived_pickup', 'picking_up', 'in_transit', 'arrived_dropoff', 'completed', 'cancelled', 'expired'
    otp VARCHAR(6) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- Booking Events (Audit log for order lifecycle)
CREATE TABLE IF NOT EXISTS booking_events (
    id SERIAL PRIMARY KEY,
    booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
    event_type VARCHAR(50) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Audit Logs (Admin operations tracker)
CREATE TABLE IF NOT EXISTS audit_logs (
    id SERIAL PRIMARY KEY,
    admin_uid VARCHAR(128) NOT NULL,
    action VARCHAR(100) NOT NULL,
    details TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Pricing Configurations Table
CREATE TABLE IF NOT EXISTS pricing_config (
    vehicle_type VARCHAR(50) PRIMARY KEY,
    base_price DECIMAL(10, 2) NOT NULL,
    base_distance DOUBLE PRECISION NOT NULL,
    per_km_price DECIMAL(10, 2) NOT NULL,
    description VARCHAR(255)
);

INSERT INTO pricing_config (vehicle_type, base_price, base_distance, per_km_price, description)
VALUES 
('bike', 40.00, 2.0, 10.00, 'Quick deliveries up to 20 kg'),
('three_wheeler', 120.00, 3.0, 18.00, 'Medium cargo up to 150 kg'),
('ace', 250.00, 5.0, 25.00, 'Heavy cargo up to 600 kg'),
('truck', 500.00, 5.0, 35.00, 'Very heavy cargo up to 2,000 kg')
ON CONFLICT (vehicle_type) DO NOTHING;

-- Alter drivers table for Wallet & Dues Ledger
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS wallet_balance DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS outstanding_dues DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS max_negative_limit DECIMAL(10, 2) DEFAULT 500.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS account_status VARCHAR(30) DEFAULT 'active'; -- 'active', 'cash_restricted', 'trip_paused'
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS dues_due_date TIMESTAMP WITH TIME ZONE;

-- Alter bookings table for Payment Type & Settlement Tracking
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_type VARCHAR(20) DEFAULT 'cash'; -- 'online', 'cash', 'direct_upi'
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS commission_amount DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS driver_net_earnings DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS is_settled BOOLEAN DEFAULT FALSE;

-- Partner Ledgers Table (Unified Financial Ledger)
CREATE TABLE IF NOT EXISTS partner_ledgers (
    id SERIAL PRIMARY KEY,
    driver_id VARCHAR(128) REFERENCES drivers(id) ON DELETE CASCADE,
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    entry_type VARCHAR(40) NOT NULL, -- 'trip_earning', 'platform_commission', 'dues_offset', 'direct_repayment', 'incentive', 'reimbursement', 'adjustment'
    amount DECIMAL(10, 2) NOT NULL, -- Positive for driver credit, negative for driver debit
    balance_after DECIMAL(10, 2) NOT NULL,
    description TEXT NOT NULL,
    is_disputed BOOLEAN DEFAULT FALSE,
    dispute_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
