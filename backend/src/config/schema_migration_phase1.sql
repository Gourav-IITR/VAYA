-- Schema Migration for Phase 1 & 2: v2 Core Architecture & Money Movement

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Fare Quotes Table
CREATE TABLE IF NOT EXISTS fare_quotes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id VARCHAR(128) REFERENCES customers(id) ON DELETE SET NULL,
    vehicle_type VARCHAR(50) NOT NULL,
    pickup_lat DOUBLE PRECISION NOT NULL,
    pickup_lng DOUBLE PRECISION NOT NULL,
    dropoff_lat DOUBLE PRECISION NOT NULL,
    dropoff_lng DOUBLE PRECISION NOT NULL,
    distance_km DOUBLE PRECISION NOT NULL,
    base_price DECIMAL(10, 2) NOT NULL,
    distance_price DECIMAL(10, 2) NOT NULL,
    helper_count INT DEFAULT 0,
    helper_charge DECIMAL(10, 2) DEFAULT 0.00,
    gst_amount DECIMAL(10, 2) DEFAULT 0.00,
    total_fare DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 2. Settlements Table
CREATE TABLE IF NOT EXISTS settlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID UNIQUE REFERENCES bookings(id) ON DELETE CASCADE,
    base_fare DECIMAL(10, 2) NOT NULL,
    waiting_charge DECIMAL(10, 2) DEFAULT 0.00,
    extra_charge DECIMAL(10, 2) DEFAULT 0.00,
    cancellation_fee DECIMAL(10, 2) DEFAULT 0.00,
    discount DECIMAL(10, 2) DEFAULT 0.00,
    final_cost DECIMAL(10, 2) NOT NULL,
    commission_amount DECIMAL(10, 2) NOT NULL,
    driver_net_earnings DECIMAL(10, 2) NOT NULL,
    paid_online DECIMAL(10, 2) DEFAULT 0.00,
    cash_pickup DECIMAL(10, 2) DEFAULT 0.00,
    cash_drop DECIMAL(10, 2) DEFAULT 0.00,
    amount_due DECIMAL(10, 2) DEFAULT 0.00,
    payment_method VARCHAR(30) DEFAULT 'cash', -- 'cash', 'upi_at_drop', 'vaya_credits', 'pay_later'
    payer_type VARCHAR(20) DEFAULT 'receiver', -- 'sender', 'receiver', 'booker'
    payment_point VARCHAR(20) DEFAULT 'dropoff', -- 'pickup', 'dropoff', 'app_drop'
    state VARCHAR(20) DEFAULT 'pending', -- 'pending', 'settling', 'paid', 'pay_later', 'failed'
    frozen_at TIMESTAMP WITH TIME ZONE,
    paid_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. Double-Entry Ledger Entries Table
CREATE TABLE IF NOT EXISTS ledger_entries (
    id SERIAL PRIMARY KEY,
    account VARCHAR(100) NOT NULL, -- 'customer:{id}', 'driver:{id}', 'vaya:revenue', 'vaya:cash_in_transit', 'razorpay:clearing'
    entry_type VARCHAR(50) NOT NULL, -- 'booking_settlement', 'commission', 'waiting_charge', 'cancellation_fee', 'dues_repayment', 'payout', 'refund'
    amount DECIMAL(10, 2) NOT NULL, -- positive = credit/increase, negative = debit/decrease
    balance_after DECIMAL(10, 2),
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    payment_id VARCHAR(100),
    idempotency_key VARCHAR(150) UNIQUE,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. Payouts Table (RazorpayX)
CREATE TABLE IF NOT EXISTS payouts (
    id SERIAL PRIMARY KEY,
    driver_id VARCHAR(128) REFERENCES drivers(id) ON DELETE CASCADE,
    razorpay_payout_id VARCHAR(50) UNIQUE,
    fund_account_id VARCHAR(50),
    amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'initiated', -- 'initiated', 'processing', 'processed', 'reversed', 'failed'
    mode VARCHAR(20) DEFAULT 'UPI', -- 'UPI', 'NEFT', 'IMPS'
    utr VARCHAR(100),
    failure_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE
);

-- 5. Extend Bookings Table
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS quote_id UUID REFERENCES fare_quotes(id) ON DELETE SET NULL;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payer_type VARCHAR(20) DEFAULT 'receiver';
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_point VARCHAR(20) DEFAULT 'dropoff';
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS settlement_id UUID REFERENCES settlements(id) ON DELETE SET NULL;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancellation_fee DECIMAL(10, 2) DEFAULT 0.00;

-- 6. Extend Customers Table
ALTER TABLE customers ADD COLUMN IF NOT EXISTS vaya_credits DECIMAL(10, 2) DEFAULT 0.00;

-- 7. Extend Drivers Table
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS razorpay_contact_id VARCHAR(50);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS razorpay_fund_account_id VARCHAR(50);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS bank_name VARCHAR(100);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS account_number VARCHAR(50);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS ifsc_code VARCHAR(20);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS upi_id VARCHAR(100);
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS payout_status VARCHAR(30) DEFAULT 'unverified';
