# 🌐 VAYA Logistics — Custom Domain & DNS Setup Guide (`vayadelivery.com`)

This document provides the exact configuration parameters required on your **Domain Registrar / DNS Provider** (e.g., GoDaddy, Namecheap, Cloudflare, Google Domains / Squarespace, Hostinger, BigRock) to route the VAYA Logistics platform frontends to `vayadelivery.com` and its subdomains.

---

## 🎯 Target Application Mapping

| Application | Directory | Firebase Site Target | Production Endpoint |
|---|---|---|---|
| **Landing Page / Public Website** | `public_website` | `goods-delivery-platform` | `https://vayadelivery.com`<br>`https://www.vayadelivery.com` |
| **Customer Web App** | `customer_app` | `vaya-customer-app` | `https://app.vayadelivery.com` |
| **Driver Partner Web App** | `partner_app` | `vaya-partner-app` | `https://partner.vayadelivery.com` |
| **Admin Operations Portal** | `web_portal` | `vaya-logistics-admin` | `https://admin.vayadelivery.com` |

---

## 📋 Complete DNS Records Table

Add the following records in your Domain Provider's **DNS Management / DNS Zone Editor**:

| Record Type | Host / Name | Value / Target / Points To | TTL | Destination |
|---|---|---|---|---|
| **A** | `@` | `199.36.158.100` *(Firebase Primary IP)* | 3600 / Auto | Root `vayadelivery.com` → **Landing Page** |
| **A** | `@` | `199.36.158.100` *(Firebase Secondary IP)* | 3600 / Auto | Redundant IP for Root Domain |
| **CNAME** | `www` | `goods-delivery-platform.web.app` | 3600 / Auto | `www.vayadelivery.com` → **Landing Page** |
| **CNAME** | `app` | `vaya-customer-app.web.app` | 3600 / Auto | `app.vayadelivery.com` → **Customer Web App** |
| **CNAME** | `partner` | `vaya-partner-app.web.app` | 3600 / Auto | `partner.vayadelivery.com` → **Driver Partner App** |
| **CNAME** | `admin` | `vaya-logistics-admin.web.app` | 3600 / Auto | `admin.vayadelivery.com` → **Admin Operations Portal** |

> 💡 **Firebase IP Note**: The IP addresses above are standard Firebase Hosting IPs. If Firebase Console displays different IPs during custom domain setup, use the ones displayed in your Firebase Console.

---

## 🔑 Domain Verification (TXT Record)

If Firebase Console requests proof of domain ownership for `vayadelivery.com`:

| Record Type | Host / Name | Value / Target |
|---|---|---|
| **TXT** | `@` | `firebase=goods-delivery-platform-...` *(Copy exact token from Firebase Console)* |

---

## 🛠️ Step-by-Step Configuration Workflow

### Step 1: Add Custom Domains in Firebase Console
1. Open [Firebase Console](https://console.firebase.google.com/) → Select project **`goods-delivery-platform`**.
2. Navigate to **Build** → **Hosting**.
3. Select each hosting site target from the site dropdown and click **Add Custom Domain**:
   - For **`goods-delivery-platform`**: Add `vayadelivery.com` (and redirect `www.vayadelivery.com`).
   - For **`vaya-customer-app`**: Add `app.vayadelivery.com`.
   - For **`vaya-partner-app`**: Add `partner.vayadelivery.com`.
   - For **`vaya-logistics-admin`**: Add `admin.vayadelivery.com`.

---

### Step 2: Add DNS Records at Domain Registrar
1. Log into your domain registrar account (GoDaddy, Namecheap, Cloudflare, etc.).
2. Go to **My Domains** → Select `vayadelivery.com` → Open **DNS Management / Edit DNS Zone**.
3. Remove any existing default parking `A` records pointing to your registrar's default IP.
4. Input the **A** and **CNAME** records listed in the table above.

---

### Step 3: Configure Firebase Authentication Authorized Domains
To ensure Phone Auth SMS verification and Firebase Login work across all subdomains:
1. In Firebase Console, go to **Build** → **Authentication**.
2. Open the **Settings** tab → Select **Authorized domains**.
3. Click **Add domain** and enter:
   - `vayadelivery.com`
   - `www.vayadelivery.com`
   - `app.vayadelivery.com`
   - `partner.vayadelivery.com`
   - `admin.vayadelivery.com`

---

## ⚡ Registrar Specific Instructions

### 🟡 GoDaddy
- For root `@` records: Select Type `A`, Host `@`, Points to `199.36.158.100`.
- For subdomains: Select Type `CNAME`, Host `app` (or `partner`, `admin`, `www`), Points to `<site-id>.web.app`.

### 🔵 Cloudflare
- Turn **Proxy Status** to **DNS Only** (Grey Cloud ☁️) initially so Firebase can issue Let's Encrypt SSL certificates automatically.
- Enable Cloudflare proxying (Orange Cloud 🟠) after SSL status turns Active in Firebase Console if desired.

### 🔴 Namecheap
- Under **Advanced DNS**, add `A Record` with Host `@` and Value `199.36.158.100`.
- Add `CNAME Record` with Host `app` and Target `vaya-customer-app.web.app.`.

---

## ⏳ SSL & Propagation Expectations

- **DNS Propagation**: Changes take between **5 to 15 minutes** (up to 24 hours in rare cases depending on DNS TTL).
- **Free SSL Certificates**: Firebase automatically provisions free Let's Encrypt SSL certificates for all custom domains once DNS propagation is verified.
