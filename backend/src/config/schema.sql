-- Production Database Schema for GoodsDeliveryApp

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Customers Table
CREATE TABLE IF NOT EXISTS customers (
    id VARCHAR(128) PRIMARY KEY, -- Firebase UID
    phone VARCHAR(15) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    company_name VARCHAR(255),
    gstin VARCHAR(50),
    billing_address TEXT,
    gst_status VARCHAR(50) DEFAULT 'Not added',
    notify_booking_updates BOOLEAN DEFAULT TRUE,
    notify_live_tracking BOOLEAN DEFAULT TRUE,
    notify_offers BOOLEAN DEFAULT FALSE,
    notify_whatsapp BOOLEAN DEFAULT TRUE,
    app_language VARCHAR(50) DEFAULT 'English',
    saved_addresses JSONB DEFAULT '[]'::jsonb,
    account_status VARCHAR(30) DEFAULT 'active',
    fcm_token VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE customers ADD COLUMN IF NOT EXISTS email VARCHAR(255);
ALTER TABLE customers ADD COLUMN IF NOT EXISTS company_name VARCHAR(255);
ALTER TABLE customers ADD COLUMN IF NOT EXISTS gstin VARCHAR(50);
ALTER TABLE customers ADD COLUMN IF NOT EXISTS billing_address TEXT;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS gst_status VARCHAR(50) DEFAULT 'Not added';
ALTER TABLE customers ADD COLUMN IF NOT EXISTS notify_booking_updates BOOLEAN DEFAULT TRUE;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS notify_live_tracking BOOLEAN DEFAULT TRUE;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS notify_offers BOOLEAN DEFAULT FALSE;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS notify_whatsapp BOOLEAN DEFAULT TRUE;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS app_language VARCHAR(50) DEFAULT 'English';
ALTER TABLE customers ADD COLUMN IF NOT EXISTS saved_addresses JSONB DEFAULT '[]'::jsonb;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS account_status VARCHAR(30) DEFAULT 'active';

-- Drivers Table
CREATE TABLE IF NOT EXISTS drivers (
    id VARCHAR(128) PRIMARY KEY, -- Firebase UID
    phone VARCHAR(15) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    app_language VARCHAR(50) DEFAULT 'English',
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

ALTER TABLE drivers ADD COLUMN IF NOT EXISTS email VARCHAR(255);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS app_language VARCHAR(50) DEFAULT 'English';

-- Support Tickets & Service Requests Table
CREATE TABLE IF NOT EXISTS support_tickets (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(128) NOT NULL,
    user_role VARCHAR(20) NOT NULL, -- 'customer' or 'driver'
    type VARCHAR(50) NOT NULL,      -- 'callback_request', 'dispute_case', 'data_export', 'vehicle_change', 'account_deletion'
    details JSONB DEFAULT '{}'::jsonb,
    status VARCHAR(30) DEFAULT 'open',
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
    status VARCHAR(30) DEFAULT 'pending', -- actual states written by code: 'pending' -> 'accepted' -> 'arrived_pickup' -> 'dropping_off' -> 'arrived_dropoff' -> 'completed' (also: 'cancelled', 'expired')
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

ALTER TABLE pricing_config ADD COLUMN IF NOT EXISTS free_wait_minutes_pickup INT DEFAULT 10;
ALTER TABLE pricing_config ADD COLUMN IF NOT EXISTS free_wait_minutes_dropoff INT DEFAULT 10;
ALTER TABLE pricing_config ADD COLUMN IF NOT EXISTS wait_charge_per_minute DECIMAL(10, 2) DEFAULT 2.00;

-- Alter drivers table for Wallet & Dues Ledger
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS wallet_balance DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS outstanding_dues DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS max_negative_limit DECIMAL(10, 2) DEFAULT 500.00;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS account_status VARCHAR(30) DEFAULT 'active'; -- 'active', 'cash_restricted', 'trip_paused'
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS dues_due_date TIMESTAMP WITH TIME ZONE;

-- Alter bookings table for Payment Type & Settlement Tracking
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_type VARCHAR(20) DEFAULT 'cash'; -- 'online', 'cash', 'direct_upi'
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cash_collection_point VARCHAR(10); -- 'PICKUP', 'DROPOFF'
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS commission_amount DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS driver_net_earnings DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS is_settled BOOLEAN DEFAULT FALSE;

-- Waiting Time Charges & Timestamps for Bookings
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS arrived_pickup_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS pickup_verified_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS arrived_dropoff_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS pickup_wait_minutes INT DEFAULT 0;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS dropoff_wait_minutes INT DEFAULT 0;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS waiting_charge_pickup DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS waiting_charge_dropoff DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS total_waiting_charge DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS final_cost DECIMAL(10, 2);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS pickup_amount DECIMAL(10, 2);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS is_pickup_cash_collected BOOLEAN DEFAULT FALSE;

-- Settlement Tracking & Idempotency Columns
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS settlement_id VARCHAR(64);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS settlement_version INT DEFAULT 1;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS amount_collected_at_pickup DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS amount_paid_online DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS amount_due_now DECIMAL(10, 2) DEFAULT 0.00;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS support_override_approved BOOLEAN DEFAULT FALSE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS idempotency_key VARCHAR(128);

-- Notification State Tracking & Cancellation Metadata
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS near_pickup_notified BOOLEAN DEFAULT FALSE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS free_wait_ending_notified BOOLEAN DEFAULT FALSE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS near_dropoff_notified BOOLEAN DEFAULT FALSE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS additional_payment_notified BOOLEAN DEFAULT FALSE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_by VARCHAR(128);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_by_role VARCHAR(30);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancellation_fee DECIMAL(10, 2) DEFAULT 0.00;

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

-- Driver Rating System
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS rating_avg DECIMAL(3, 2) DEFAULT 5.0;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS rating_count INT DEFAULT 0;

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS rating INT;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS rating_comment TEXT;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS rating_skipped BOOLEAN DEFAULT FALSE;

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS sender_name VARCHAR(100);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS sender_phone VARCHAR(15);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS receiver_name VARCHAR(100);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS receiver_phone VARCHAR(15);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS goods_category VARCHAR(100);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_method VARCHAR(50);

ALTER TABLE drivers ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE customers ALTER COLUMN phone TYPE VARCHAR(50);
ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_phone_key;

-- ═══════════════════════════════════════════════════════════════════
-- Razorpay Payment Integration Schema
-- ═══════════════════════════════════════════════════════════════════

-- Customer Wallet Balance
ALTER TABLE customers ADD COLUMN IF NOT EXISTS wallet_balance DECIMAL(10, 2) DEFAULT 0.00;

-- Payment Orders Table (Razorpay order tracking)
CREATE TABLE IF NOT EXISTS payment_orders (
    id SERIAL PRIMARY KEY,
    razorpay_order_id VARCHAR(50) UNIQUE NOT NULL,
    razorpay_payment_id VARCHAR(50),
    user_id VARCHAR(128) NOT NULL,
    purpose VARCHAR(30) NOT NULL,            -- 'booking_fare', 'dues_repayment', 'wallet_topup'
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    amount DECIMAL(10, 2) NOT NULL,           -- Amount in INR
    amount_paise INT NOT NULL,                -- Amount in paise (sent to Razorpay)
    status VARCHAR(20) DEFAULT 'created',     -- 'created', 'paid', 'failed'
    verified_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Customer Wallet Transactions (top-ups, booking deductions, refunds)
CREATE TABLE IF NOT EXISTS customer_wallet_transactions (
    id SERIAL PRIMARY KEY,
    customer_id VARCHAR(128) REFERENCES customers(id) ON DELETE CASCADE,
    type VARCHAR(30) NOT NULL,                -- 'topup', 'booking_payment', 'refund'
    amount DECIMAL(10, 2) NOT NULL,           -- Positive for credit, negative for debit
    balance_after DECIMAL(10, 2) NOT NULL,
    razorpay_payment_id VARCHAR(50),
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Track Razorpay payment ID on bookings for online/wallet payments
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS razorpay_payment_id VARCHAR(50);

-- Store the number of helpers requested; server-side fare already includes helper fees
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS helpers_count INT DEFAULT 0;

-- Driver Bank Account & UPI Details for Daily Payouts
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS upi_id VARCHAR(100);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS bank_account_no VARCHAR(50);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS bank_ifsc VARCHAR(20);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS bank_account_name VARCHAR(100);

CREATE TABLE IF NOT EXISTS driver_payouts (
    id SERIAL PRIMARY KEY,
    driver_id VARCHAR(128) REFERENCES drivers(id) ON DELETE CASCADE,
    amount DECIMAL(10, 2) NOT NULL,
    payout_method VARCHAR(30) DEFAULT 'upi',  -- 'upi', 'bank_transfer'
    reference_id VARCHAR(100),
    status VARCHAR(20) DEFAULT 'pending',     -- 'pending', 'completed', 'failed'
    initiated_by VARCHAR(128),                -- admin UID
    completed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
