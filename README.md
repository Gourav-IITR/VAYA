# 🚛 VAYA — Vehicle At Your Address

> Hyperlocal goods delivery platform for Odisha, India. Connects customers needing to move cargo with driver-partners who own vehicles — from bikes to heavy trucks.

[![Backend](https://img.shields.io/badge/Backend-Node.js%20%2B%20Express-339933?logo=node.js&logoColor=white)]()
[![Database](https://img.shields.io/badge/Database-PostgreSQL%20(Neon)-4169E1?logo=postgresql&logoColor=white)]()
[![Mobile](https://img.shields.io/badge/Mobile-Flutter%20%2F%20Dart-02569B?logo=flutter&logoColor=white)]()
[![Web](https://img.shields.io/badge/Web-React%20%2B%20Vite-61DAFB?logo=react&logoColor=black)]()
[![Auth](https://img.shields.io/badge/Auth-Firebase-FFCA28?logo=firebase&logoColor=black)]()
[![Payments](https://img.shields.io/badge/Payments-Razorpay-0C2451?logo=razorpay&logoColor=white)]()

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Repository Structure](#repository-structure)
- [Tech Stack](#tech-stack)
- [Getting Started (New Machine Setup)](#getting-started-new-machine-setup)
- [Backend API](#backend-api)
- [Database Schema](#database-schema)
- [Mobile Apps](#mobile-apps)
- [Web Applications](#web-applications)
- [Deployment](#deployment)
- [Environment Variables](#environment-variables)
- [Key Features](#key-features)
- [Current Versions](#current-versions)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         VAYA Platform                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ Customer App │  │  Driver App  │  │ Admin Portal │  │  Public   │ │
│  │  (Flutter)   │  │  (Flutter)   │  │ (React+Vite) │  │  Website  │ │
│  │  Android     │  │  Android     │  │  Firebase    │  │(React+Vite│ │
│  └──────┬───────┘  └──────┬───────┘  │  Hosting     │  │ Firebase) │ │
│         │                  │          └──────┬───────┘  └─────┬─────┘ │
│         │    REST + WebSocket (wss://)       │                │       │
│         └──────────────┬────────────────────┘                │       │
│                        │                                      │       │
│              ┌─────────▼──────────┐                          │       │
│              │   Node.js Backend   │◄─────────────────────────┘       │
│              │   (Express + WS)    │                                  │
│              │   Google Cloud Run  │                                  │
│              └─────────┬──────────┘                                   │
│                        │                                              │
│         ┌──────────────┼──────────────┐                              │
│         ▼              ▼              ▼                              │
│  ┌─────────────┐ ┌──────────┐ ┌──────────────┐                     │
│  │ Neon Postgres│ │ Firebase │ │   Razorpay   │                     │
│  │ (Serverless) │ │ Auth+FCM │ │  Payments    │                     │
│  └─────────────┘ └──────────┘ └──────────────┘                     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
GoodsDeliveryApp/
├── backend/                    # Node.js Express API server
│   ├── server.js               # Entry point (Express + WebSocket)
│   ├── package.json            # Dependencies (express, pg, ws, razorpay, firebase-admin)
│   ├── Dockerfile              # Container config for Cloud Run
│   └── src/
│       ├── config/
│       │   ├── db.js           # PostgreSQL (Neon) connection pool
│       │   ├── firebase.js     # Firebase Admin SDK initialization
│       │   └── schema.sql      # Complete database DDL (auto-runs on startup)
│       ├── routes/
│       │   ├── admin.routes.js     # Dashboard analytics, driver approvals, pricing config
│       │   ├── booking.routes.js   # Order lifecycle (create → accept → transit → complete)
│       │   ├── customer.routes.js  # Customer profile, FCM tokens, wallet history
│       │   ├── driver.routes.js    # Driver registration, status toggle, GPS streaming
│       │   ├── health.routes.js    # Health check + DB connectivity ping
│       │   ├── ledger.routes.js    # Partner financial ledger, dues, disputes
│       │   └── payment.routes.js   # Razorpay orders, verification, webhooks
│       └── services/
│           ├── notification.service.js  # FCM push notification sender
│           └── websocket.service.js     # Real-time WS client registry + broadcast
│
├── customer_app/               # Flutter Customer Mobile App (Android)
│   ├── pubspec.yaml            # v1.0.12+13 | Dart ≥3.4.0
│   ├── lib/
│   │   ├── main.dart           # Complete app (auth, booking, maps, payments, i18n)
│   │   ├── services/
│   │   │   └── razorpay_service.dart   # Razorpay payment flow handler
│   │   ├── widgets/
│   │   │   ├── payment_method_sheet.dart  # Cash/Online/Wallet selection
│   │   │   └── vaya_loader.dart           # Branded animated loader
│   │   └── utils/
│   │       └── vehicle_icon_helper.dart   # Vehicle type icon mapper
│   ├── assets/                 # Images and SVG icons
│   └── android/                # Android platform config (build.gradle, manifests)
│
├── driver_app/                 # Flutter Driver Partner App (Android)
│   ├── pubspec.yaml            # v1.0.10+11 | Dart ≥3.4.0
│   ├── lib/
│   │   ├── main.dart           # Complete app (duty toggle, trip workflow, earnings, ledger)
│   │   ├── services/
│   │   │   └── razorpay_service.dart
│   │   ├── widgets/
│   │   │   ├── payment_method_sheet.dart
│   │   │   └── vaya_loader.dart
│   │   └── utils/
│   │       └── vehicle_icon_helper.dart
│   ├── assets/
│   └── android/
│
├── web_portal/                 # React Admin Operations Dashboard
│   ├── package.json            # Vite 5 + React 18 + Leaflet + Firebase
│   └── src/
│       ├── App.jsx             # Router and app shell
│       └── components/
│           ├── AdminDashboard.jsx   # Full ops center (drivers, bookings, pricing, ledger)
│           ├── AdminLogin.jsx       # Firebase email/password admin auth
│           ├── LeafletMap.jsx       # OSM map with driver tracking
│           └── LocationSearch.jsx   # Geocoding search widget
│
├── public_website/             # React Public Landing Page + Fare Estimator
│   ├── package.json
│   └── src/
│       ├── App.jsx             # Landing page, fare calculator, download links
│       └── components/         # Shared UI components
│
├── docs/                       # Project documentation
│   ├── deployment.md           # Cloud Run + Firebase Hosting deployment guide
│   ├── firebase-setup.md       # Firebase Auth, FCM, Custom Claims setup
│   ├── play-store-checklist.md # Google Play compliance (API 35+, permissions)
│   ├── privacy-policy.md       # Platform privacy policy
│   └── smoke-tests.md         # cURL test scripts for API validation
│
├── deploy.sh                   # One-click production deployment script
├── firebase.json               # Multi-site Firebase Hosting config
├── SIGNING_SETUP.md            # Android release signing instructions
└── README.md                   # ← You are here
```

---

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Backend** | Node.js 20+ / Express 4 | REST API + WebSocket server |
| **Database** | PostgreSQL (Neon Serverless) | Primary data store, auto-sleeping |
| **Auth** | Firebase Auth (Phone + Email) | Customer/Driver phone OTP, Admin email login |
| **Push Notifications** | Firebase Cloud Messaging (V1) | Order alerts, status updates |
| **Real-time** | WebSocket (`ws` library) | Live booking updates, driver tracking |
| **Payments** | Razorpay (Custom UI SDK) | Online payments, wallet top-ups, webhooks |
| **Customer App** | Flutter / Dart (Android) | Booking, maps, tracking, payments |
| **Driver App** | Flutter / Dart (Android) | Trip management, earnings, navigation |
| **Admin Dashboard** | React 18 + Vite 5 | Operations center, driver approvals |
| **Public Website** | React 18 + Vite 5 | Landing page, fare estimator |
| **Maps** | Google Maps (Flutter) + Leaflet (Web) | Location picking, route display |
| **Hosting (Web)** | Firebase Hosting (Multi-site) | Static SPA hosting |
| **Hosting (API)** | Google Cloud Run | Containerized backend |

---

## Getting Started (New Machine Setup)

### Prerequisites

Install these tools on your new machine:

```bash
# 1. Flutter SDK (≥3.4.0)
#    Download from https://docs.flutter.dev/get-started/install
#    Ensure `flutter doctor` passes

# 2. Node.js (≥20.x)
#    Download from https://nodejs.org/en/download/ or use nvm:
nvm install 20 && nvm use 20

# 3. Google Cloud CLI
#    https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud config set project goods-delivery-platform

# 4. Firebase CLI
npm install -g firebase-tools
firebase login

# 5. Android Studio (for Flutter Android builds)
#    Download from https://developer.android.com/studio
#    Install Android SDK 36 (API 36) via SDK Manager
#    Accept licenses: flutter doctor --android-licenses

# 6. Java JDK 17+ (for Gradle builds)
#    brew install openjdk@17  (macOS)
```

### Clone & Setup

```bash
# 1. Clone the repository
git clone git@github.com:Gourav-IITR/VAYA.git
cd VAYA

# 2. Backend setup
cd backend
npm install
# Create backend/.env with your credentials (see Environment Variables section)
cd ..

# 3. Customer app setup
cd customer_app
flutter pub get
# Place google-services.json in android/app/
# Create android/key.properties (see SIGNING_SETUP.md)
cd ..

# 4. Driver app setup
cd driver_app
flutter pub get
# Place google-services.json in android/app/
# Create android/key.properties (see SIGNING_SETUP.md)
cd ..

# 5. Web portal setup
cd web_portal
npm install
# Create .env with Firebase web credentials
cd ..

# 6. Public website setup
cd public_website
npm install
# Create .env with Firebase web credentials
cd ..
```

### Running Locally

```bash
# Backend (runs on port 5001)
cd backend && node server.js

# Customer App (connect device or start emulator first)
cd customer_app && flutter run

# Driver App
cd driver_app && flutter run

# Admin Dashboard (runs on port 5173)
cd web_portal && npm run dev

# Public Website (runs on port 5174)
cd public_website && npm run dev
```

---

## Backend API

### Base URL
- **Production**: `https://vaya-backend-275777907648.us-central1.run.app`
- **Local**: `http://localhost:5001`

### API Routes

| Route Prefix | File | Description |
|-------------|------|-------------|
| `/api/customer` | `customer.routes.js` | Profile sync, FCM token, wallet history |
| `/api/driver` | `driver.routes.js` | Registration, online/offline toggle, GPS updates |
| `/api/booking` | `booking.routes.js` | Order CRUD, status transitions, OTP, ratings |
| `/api/bookings` | `booking.routes.js` | Alias for booking queries |
| `/api/ledger` | `ledger.routes.js` | Partner financial ledger, dues, disputes |
| `/api/payment` | `payment.routes.js` | Razorpay orders, verification, webhooks |
| `/api/admin` | `admin.routes.js` | Dashboard analytics, approvals, pricing config |
| `/api/health` | `health.routes.js` | Server health + DB connectivity ping |
| `/api/pricing-config` | `server.js` (inline) | Fetch vehicle pricing table |

### WebSocket
- **Endpoint**: `wss://<host>/ws?token=<firebase_id_token>`
- **Auth**: Firebase ID token verified on upgrade
- **Events**: `booking_update`, `booking_expired`, `driver_status`, `new_booking_request`

### Background Jobs (In-Process)
1. **Booking Expiration** — Every 30s, expires pending bookings past `expires_at`
2. **Driver Presence** — Every 15s, marks drivers offline if `last_active_at > 30s ago`

---

## Database Schema

PostgreSQL (Neon Serverless) — auto-migrated from `backend/src/config/schema.sql` on startup.

### Core Tables

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `customers` | Customer profiles | `id` (Firebase UID), `phone`, `name`, `wallet_balance` |
| `drivers` | Driver-partner profiles | `id` (Firebase UID), `vehicle_type`, `status`, `lat/lng`, `wallet_balance`, `outstanding_dues`, `rating_avg` |
| `bookings` | Delivery orders | `id` (UUID), `status` (10 states), `payment_type`, `estimated_cost`, `final_cost`, `waiting_charges` |
| `booking_events` | Audit trail per booking | `event_type`, `description` |
| `pricing_config` | Per-vehicle-type rates | `base_price`, `per_km_price`, `wait_charge_per_minute` |
| `partner_ledgers` | Driver financial ledger | `entry_type`, `amount`, `balance_after` |
| `payment_orders` | Razorpay order tracking | `razorpay_order_id`, `purpose`, `status` |
| `customer_wallet_transactions` | Customer wallet log | `type` (topup/payment/refund), `amount` |
| `driver_payouts` | Admin-initiated payouts | `payout_method`, `status` |
| `audit_logs` | Admin action audit trail | `admin_uid`, `action`, `details` |

### Vehicle Types
- `bike` — Quick deliveries up to 20 kg
- `three_wheeler` — Medium cargo up to 150 kg
- `ace` — Heavy cargo up to 600 kg
- `truck` — Very heavy cargo up to 2,000 kg

### Booking Status Flow
```
pending → accepted → arrived_pickup → picking_up → in_transit → arrived_dropoff → completed
   ↓                                                                                  ↓
 expired                                                                          (rated)
   ↓
cancelled
```

---

## Mobile Apps

### Customer App (`customer_app/`)
- **Package**: `com.vaya.customer_app`
- **Version**: 1.0.12+13
- **Features**:
  - Phone OTP authentication (Firebase)
  - Google Maps location picker with current location
  - Vehicle type selection with fare estimation
  - Real-time order tracking with driver location
  - Cash / Online (Razorpay) / Wallet payment
  - Order history and ratings
  - Multilingual: English, Hindi, Odia
  - Speech-to-text address input
  - Contact picker for sender/receiver

### Driver App (`driver_app/`)
- **Package**: `com.vaya.partner_app`
- **Version**: 1.0.10+11
- **Features**:
  - Phone OTP authentication (Firebase)
  - Online/Offline duty toggle
  - Incoming order popup with Accept/Reject
  - Step-by-step trip workflow with OTP verification
  - Real-time GPS streaming to backend
  - Earnings breakdown and financial ledger
  - Dues tracking and settlement
  - Wakelock during active trips
  - Multilingual: English, Hindi, Odia

### Building Release APKs

```bash
# Customer App
cd customer_app
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk

# Driver App
cd driver_app
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### Building Release AABs (Play Store)

```bash
cd customer_app && flutter build appbundle --release
cd driver_app && flutter build appbundle --release
```

> **Important**: See `SIGNING_SETUP.md` for keystore generation and `key.properties` setup.

---

## Web Applications

### Admin Dashboard (`web_portal/`)
- **URL**: [vaya-logistics-admin.web.app](https://vaya-logistics-admin.web.app)
- **Auth**: Firebase Email/Password (requires `role: 'admin'` custom claim)
- **Features**:
  - Live driver tracking map (Leaflet + OSM)
  - Pending driver verification/approvals
  - Active bookings overview
  - Pricing configuration manager
  - Partner ledger and settlement tools
  - Audit logs viewer

### Public Website (`public_website/`)
- **URL**: [goods-delivery-platform.web.app](https://goods-delivery-platform.web.app)
- **Features**:
  - Service landing page
  - Fare estimation calculator
  - App download links

---

## Deployment

### Quick Deploy (All Services)

```bash
./deploy.sh
```

This script handles:
1. `gcloud` and `firebase` auth verification
2. Reads config from `.env.deploy` (or prompts interactively)
3. Builds web portal and public website dist bundles
4. Submits Docker build to Cloud Build and deploys to Cloud Run
5. Deploys web assets to Firebase Hosting (multi-site)

### Manual Deployment — see `docs/deployment.md`

---

## Environment Variables

### Backend (`.env`)

```env
DATABASE_URL=postgresql://user:pass@host/db?sslmode=require
PORT=5001
```

> The `serviceAccountKey.json` file must be present in `backend/` for Firebase Admin SDK.

### Web Portal & Public Website (`.env`)

```env
VITE_FIREBASE_API_KEY=...
VITE_FIREBASE_AUTH_DOMAIN=...
VITE_FIREBASE_PROJECT_ID=...
VITE_FIREBASE_STORAGE_BUCKET=...
VITE_FIREBASE_MESSAGING_SENDER_ID=...
VITE_FIREBASE_APP_ID=...
VITE_GOOGLE_MAPS_API_KEY=...
```

### Mobile Apps
- `android/app/google-services.json` — Firebase config (from Firebase Console)
- `android/key.properties` — Release signing credentials
- `android/local.properties` — `GOOGLE_MAPS_API_KEY` for native Maps SDK
- API base URL is hardcoded in `lib/main.dart` (`apiBaseUrl` constant)

### Deployment Config (`.env.deploy`)

```env
PROJECT_ID=goods-delivery-platform
DATABASE_URL=postgresql://...
FB_API_KEY=...
FB_AUTH_DOMAIN=...
FB_STORAGE_BUCKET=...
FB_SENDER_ID=...
FB_APP_ID=...
GM_API_KEY=...
```

---

## Key Features

| Feature | Status | Notes |
|---------|--------|-------|
| Phone OTP Authentication | ✅ | Firebase Auth with auto-retry |
| Google Maps Location Picker | ✅ | Pin-drop + autocomplete search |
| 4 Vehicle Types (Bike → Truck) | ✅ | Dynamic pricing per type |
| Real-time Order Tracking | ✅ | WebSocket + polling fallback |
| OTP Pickup Verification | ✅ | 6-digit code verified at pickup |
| Cash / Online / Wallet Payments | ✅ | Razorpay Custom UI integration |
| Waiting Time Charges | ✅ | Auto-calculated at pickup/dropoff |
| Driver Rating & Reviews | ✅ | Post-trip rating with skip option |
| Partner Financial Ledger | ✅ | Commission tracking, dues, disputes |
| Admin Operations Dashboard | ✅ | Live map, approvals, pricing config |
| Multilingual (EN/HI/OR) | ✅ | Full app coverage |
| Push Notifications (FCM) | ✅ | Order alerts with action buttons |
| Driver Presence Detection | ✅ | Auto-offline after 30s inactivity |
| Booking Auto-Expiry | ✅ | Pending orders expire after timeout |

---

## Current Versions

| Component | Version | Build |
|-----------|---------|-------|
| Customer App | 1.0.12 | 13 |
| Driver App | 1.0.10 | 11 |
| Backend | 1.0.0 | — |
| Flutter SDK | ≥3.4.0 | — |
| Compile SDK (Android) | 36 | — |
| Target SDK (Android) | 36 | — |

---

## Documentation Index

| Document | Path | Description |
|----------|------|-------------|
| Setup Guide | `README.md` | This file — project overview and setup |
| New Machine Setup | `docs/new-machine-setup.md` | Detailed onboarding checklist |
| Deployment Guide | `docs/deployment.md` | Cloud Run + Firebase Hosting |
| Firebase Setup | `docs/firebase-setup.md` | Auth, FCM, Custom Claims |
| API Reference | `docs/api-reference.md` | Complete REST API documentation |
| Android Signing | `SIGNING_SETUP.md` | Keystore and release signing |
| Play Store | `docs/play-store-checklist.md` | Google Play compliance |
| Privacy Policy | `docs/privacy-policy.md` | Platform privacy policy |
| Smoke Tests | `docs/smoke-tests.md` | cURL validation scripts |

---

## License

Private — All rights reserved © 2026 VAYA Logistics
