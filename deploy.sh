#!/bin/bash

# VAYA Unified Production Deployer Script
# This script automates compiling the web portal, public website, and deploying client and server layers.

set -e

echo "============================================="
echo "       VAYA PRODUCTION DEPLOYMENT ENGINE      "
echo "============================================="
echo ""

# 1. Verification of login status
echo ">>> Checking Google Cloud authentication..."
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
  echo "Error: You are not logged into gcloud CLI."
  echo "Please run: gcloud auth login"
  exit 1
fi
echo ">>> Checking Firebase CLI authentication..."
if ! npx -y firebase-tools projects:list >/dev/null 2>&1; then
  echo ">>> Firebase session expired or not authenticated. Logging in..."
  npx -y firebase-tools login --no-localhost
fi

# Load from .env.deploy if it exists
if [ -f .env.deploy ]; then
  echo ">>> Loading deployment configuration from .env.deploy..."
  export $(grep -v '^#' .env.deploy | xargs)
fi

# 2. Gather deployment details
if [ -z "$PROJECT_ID" ]; then
  read -p "Enter your Google Cloud / Firebase Project ID: " PROJECT_ID
else
  echo ">>> Using Project ID: $PROJECT_ID"
fi

if [ -z "$PROJECT_ID" ]; then
  echo "Project ID is required."
  exit 1
fi

gcloud config set project "$PROJECT_ID"

if [ -z "$DATABASE_URL" ]; then
  read -p "Enter your Neon Postgres Connection URL: " DATABASE_URL
else
  echo ">>> Using Database Connection URL from configuration"
fi

if [ -z "$DATABASE_URL" ]; then
  echo "Database Connection URL is required."
  exit 1
fi

# 3. Configure Web Portal Environment Variables
echo ""
echo ">>> Setting up environment configurations for Web Portal & Public Site..."
if [ -z "$FB_API_KEY" ]; then read -p "Enter VITE_FIREBASE_API_KEY: " FB_API_KEY; fi
if [ -z "$FB_AUTH_DOMAIN" ]; then read -p "Enter VITE_FIREBASE_AUTH_DOMAIN: " FB_AUTH_DOMAIN; fi
if [ -z "$FB_STORAGE_BUCKET" ]; then read -p "Enter VITE_FIREBASE_STORAGE_BUCKET: " FB_STORAGE_BUCKET; fi
if [ -z "$FB_SENDER_ID" ]; then read -p "Enter VITE_FIREBASE_MESSAGING_SENDER_ID: " FB_SENDER_ID; fi
if [ -z "$FB_APP_ID" ]; then read -p "Enter VITE_FIREBASE_APP_ID: " FB_APP_ID; fi
if [ -z "$GM_API_KEY" ]; then read -p "Enter VITE_GOOGLE_MAPS_API_KEY (or press Enter to configure later): " GM_API_KEY; fi

cat <<EOT > web_portal/.env
VITE_FIREBASE_API_KEY=$FB_API_KEY
VITE_FIREBASE_AUTH_DOMAIN=$FB_AUTH_DOMAIN
VITE_FIREBASE_PROJECT_ID=$PROJECT_ID
VITE_FIREBASE_STORAGE_BUCKET=$FB_STORAGE_BUCKET
VITE_FIREBASE_MESSAGING_SENDER_ID=$FB_SENDER_ID
VITE_FIREBASE_APP_ID=$FB_APP_ID
VITE_GOOGLE_MAPS_API_KEY=$GM_API_KEY
EOT

# Sync same credentials to public website if needed
cp web_portal/.env public_website/.env

# 4. Build and Compile static assets & Flutter Web Apps
echo ""
echo ">>> Building VAYA Web Portal distribution files..."
cd web_portal
npm install
npm run build
cd ..

echo ""
echo ">>> Building VAYA Public Website distribution files..."
cd public_website
npm install
npm run build
cd ..

echo ""
echo ">>> Building VAYA Customer Flutter Web App..."
cd customer_app
flutter build web --release
cd ..

echo ""
echo ">>> Building VAYA Partner Flutter Web App..."
cd partner_app
flutter build web --release
cd ..

# 5. Build & Deploy Backend on Google Cloud Run
echo ""
echo ">>> Deploying VAYA Backend Node.js service to Google Cloud Run..."
cd backend

# Enable APIs
gcloud services enable run.googleapis.com containerregistry.googleapis.com

# Submit build to Cloud Build
gcloud builds submit --tag gcr.io/"$PROJECT_ID"/vaya-backend

# Deploy the image
# Audit fix High #2: use --update-env-vars instead of --set-env-vars.
# --set-env-vars REPLACES the entire env on every deploy, which wipes secrets
# like RAZORPAY_KEY_SECRET that were set separately. --update-env-vars only
# touches the variables listed here, leaving all others intact.
#
# Secrets (RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET) should be stored in
# Google Secret Manager and referenced via --set-secrets, e.g.:
#   --set-secrets RAZORPAY_KEY_SECRET=razorpay-key-secret:latest
#   --set-secrets RAZORPAY_WEBHOOK_SECRET=razorpay-webhook-secret:latest
# Set NODE_ENV=production so the global error handler redacts err.message (Medium #2 fix).
gcloud run deploy vaya-backend \
  --image gcr.io/"$PROJECT_ID"/vaya-backend \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --update-env-vars NODE_ENV=production,DATABASE_URL="$DATABASE_URL"

cd ..

echo ">>> Ensuring Firebase Hosting sites and targets are configured..."
npx -y firebase-tools hosting:sites:create vaya-customer-app --project "$PROJECT_ID" 2>/dev/null || true
npx -y firebase-tools hosting:sites:create vaya-partner-app --project "$PROJECT_ID" 2>/dev/null || true

npx -y firebase-tools target:apply hosting public goods-delivery-platform --project "$PROJECT_ID" 2>/dev/null || true
npx -y firebase-tools target:apply hosting admin vaya-logistics-admin --project "$PROJECT_ID" 2>/dev/null || true
npx -y firebase-tools target:apply hosting customer vaya-customer-app --project "$PROJECT_ID" 2>/dev/null || true
npx -y firebase-tools target:apply hosting partner vaya-partner-app --project "$PROJECT_ID" 2>/dev/null || true

echo ">>> Deploying Customer Web App to Firebase Hosting..."
npx -y firebase-tools deploy --only hosting:customer --project "$PROJECT_ID"

echo ">>> Deploying Partner Web App to Firebase Hosting..."
npx -y firebase-tools deploy --only hosting:partner --project "$PROJECT_ID"

echo ">>> Deploying Admin Portal to Firebase Hosting..."
npx -y firebase-tools deploy --only hosting:admin --project "$PROJECT_ID"

echo ">>> Deploying Public Website to Firebase Hosting..."
npx -y firebase-tools deploy --only hosting:public --project "$PROJECT_ID"

echo ""
echo "============================================="
echo "   VAYA PLATFORM SUCCESSFULLY DEPLOYED!      "
echo "============================================="
echo "Verify operational health using docs/smoke-tests.md"
