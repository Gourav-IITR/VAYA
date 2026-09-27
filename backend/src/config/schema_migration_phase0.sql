-- ═══════════════════════════════════════════════════════════════════
-- Phase 0 Schema Migration — Hotfixes
-- Run AFTER the base schema.sql
-- ═══════════════════════════════════════════════════════════════════

-- Refunds tracking table
CREATE TABLE IF NOT EXISTS refunds (
    id SERIAL PRIMARY KEY,
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    razorpay_payment_id VARCHAR(50) NOT NULL,
    razorpay_refund_id VARCHAR(50) UNIQUE,
    amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'initiated',  -- 'initiated', 'processed', 'failed'
    speed VARCHAR(20) DEFAULT 'optimum',
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE
);

-- Razorpay webhook event dedup table (prevents double-processing)
CREATE TABLE IF NOT EXISTS razorpay_events (
    id SERIAL PRIMARY KEY,
    event_id VARCHAR(100) UNIQUE NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    payload JSONB,
    processed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Track when a payment_orders row was consumed by a booking (Issue #1 fix)
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS consumed_at TIMESTAMP WITH TIME ZONE;

-- Customer outstanding dues for cancellation fees and pay-later (Issue #12 fix)
ALTER TABLE customers ADD COLUMN IF NOT EXISTS outstanding_dues DECIMAL(10, 2) DEFAULT 0.00;
