#!/bin/bash

# VAYA Firebase Custom Domain Automated Connector
# Connects vayadelivery.com, www, app, partner, and admin subdomains to Firebase Hosting & Auth

set -e

PROJECT="goods-delivery-platform"

echo "============================================="
echo "  VAYA FIREBASE CUSTOM DOMAIN CONNECTOR      "
echo "============================================="
echo ""

echo ">>> Obtaining Google Cloud OAuth Access Token..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

if [ -z "$TOKEN" ]; then
  echo "Error: Unable to fetch gcloud access token."
  echo "Please ensure you are logged into gcloud CLI (e.g. run 'gcloud auth login' or run inside Cloud Shell)."
  exit 1
fi

echo ">>> Connected to project: $PROJECT"
echo ""

# 1. Register Custom Domains in Firebase Hosting
echo ">>> Registering custom domains in Firebase Hosting sites..."

register_domain() {
  local SITE="$1"
  local DOMAIN="$2"
  echo "--> Registering $DOMAIN on site $SITE..."
  
  RES=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "https://firebasehosting.googleapis.com/v1beta1/projects/$PROJECT/sites/$SITE/customDomains?customDomainId=$DOMAIN" \
    -d '{}')

  if echo "$RES" | grep -q '"name":'; then
    echo "    ✅ Successfully registered $DOMAIN on $SITE"
  elif echo "$RES" | grep -q "ALREADY_EXISTS"; then
    echo "    ℹ️ Domain $DOMAIN is already registered on $SITE"
  else
    echo "    Response: $RES"
  fi
}

# Register primary apex domain as redirect to www.vayadelivery.com
echo "--> Configuring apex domain redirect: vayadelivery.com -> www.vayadelivery.com..."
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://firebasehosting.googleapis.com/v1beta1/projects/$PROJECT/sites/goods-delivery-platform/customDomains?customDomainId=vayadelivery.com" \
  -d '{
    "redirect": {
      "type": "MOVED_PERMANENTLY",
      "targetUri": "www.vayadelivery.com"
    }
  }' >/dev/null || true

# Register primary www domain & subdomains
register_domain "goods-delivery-platform" "www.vayadelivery.com"
register_domain "vaya-customer-app" "app.vayadelivery.com"
register_domain "vaya-partner-app" "partner.vayadelivery.com"
register_domain "vaya-logistics-admin" "admin.vayadelivery.com"

echo ""
# 2. Configure Authorized Domains for Firebase Auth
echo ">>> Configuring Authorized Domains for Firebase Authentication..."

CURRENT_CONFIG=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config")

EXISTING_DOMAINS=$(echo "$CURRENT_CONFIG" | jq -r '.authorizedDomains[]?' 2>/dev/null || true)

# Create merged JSON array of authorized domains
DOMAINS_JSON=$(jq -n \
  --argjson existing "$(echo "$CURRENT_CONFIG" | jq '.authorizedDomains // []')" \
  '$existing + ["vayadelivery.com", "www.vayadelivery.com", "app.vayadelivery.com", "partner.vayadelivery.com", "admin.vayadelivery.com"] | unique')

AUTH_RES=$(curl -s -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config?updateMask=authorizedDomains" \
  -d "{\"authorizedDomains\": $DOMAINS_JSON}")

if echo "$AUTH_RES" | grep -q '"authorizedDomains":'; then
  echo "    ✅ Authorized Domains updated successfully in Firebase Auth!"
else
  echo "    Response: $AUTH_RES"
fi

echo ""
echo ">>> Verifying Firebase Hosting Custom Domains Status..."
for SITE in goods-delivery-platform vaya-customer-app vaya-partner-app vaya-logistics-admin; do
  echo "=== Site: $SITE"
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://firebasehosting.googleapis.com/v1beta1/projects/$PROJECT/sites/$SITE/customDomains" \
  | jq '.customDomains[]? | {name, hostState, ownershipState, certState: .cert.state, issues}'
done

echo ""
echo "============================================="
echo "   FIREBASE CUSTOM DOMAINS CONNECTED!        "
echo "============================================="
echo "Firebase Hosting will now automatically provision Let's Encrypt SSL certificates."
