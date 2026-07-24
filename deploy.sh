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
if ! npx firebase-tools projects:list &>/dev/null; then
  echo ">>> Firebase session expired or not authenticated. Logging in..."
  npx firebase-tools login --no-localhost
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

# 4. Build and Compile static assets
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

# 5. Build & Deploy Backend on Google Cloud Run
echo ""
echo ">>> Deploying VAYA Backend Node.js service to Google Cloud Run..."
cd backend

# Enable APIs
gcloud services enable run.googleapis.com containerregistry.googleapis.com

# Submit build to Cloud Build
gcloud builds submit --tag gcr.io/"$PROJECT_ID"/vaya-backend

# Deploy the image
gcloud run deploy vaya-backend \
  --image gcr.io/"$PROJECT_ID"/vaya-backend \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars DATABASE_URL="$DATABASE_URL"

cd ..

# 6. Deploy Web Portal & Public Site to Firebase Hosting
echo ""
echo ">>> Deploying multi-site assets to Firebase Hosting..."
echo "Note: If you have not created secondary site targets in Firebase console, you can run:"
echo "  1. npx firebase-tools target:apply hosting public <your-default-site-id>"
echo "  2. npx firebase-tools target:apply hosting admin <your-custom-admin-site-id>"
echo ""

npx firebase-tools deploy --only hosting --project "$PROJECT_ID"

echo ""
echo "============================================="
echo "   VAYA PLATFORM SUCCESSFULLY DEPLOYED!      "
echo "============================================="
echo "Verify operational health using docs/smoke-tests.md"
