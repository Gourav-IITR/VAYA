# VAYA Web Apps — Multilingual (EN / HI / OR) QA Feedback

**Date:** 4 Sep 2026
**Scope:** Customer App (`https://vaya-customer-app.web.app`) and Partner App (`https://vaya-partner-app.web.app`), tested via live browser walkthrough in all three languages plus a code review of the localization implementation in `customer_app/lib/main.dart` and `partner_app/lib/main.dart`.
**Found via:** Live manual walkthrough (Chrome) + static code review.

## Summary and verdict

**Not ready to ship as a multilingual feature.** In both apps, switching the language setting away from English does almost nothing — the vast majority of visible text stays in English no matter what's selected. On top of that, each app has its own **critical bug that breaks the language switcher itself**:

- **Customer App:** closing the "App Language" picker with its **X button right after picking Hindi or Odia crashes the whole app to a blank white screen** and forces a full cold restart.
- **Partner App:** picking Hindi or Odia in "Choose App Language" **throws an error and the selection never takes effect at all** — the app is permanently stuck on English. As a side effect, the bottom navigation bar then stops responding until the page is reloaded.

Underneath those crashes, both apps only wire up translations for a small handful of strings (mainly a couple of dialogs, the language screen itself, and a few labels) while the login flow, home screen, bookings/trips, payments/earnings, account settings, and orders/history screens are hardcoded in English in the source code. The Customer App additionally ships a second, unused translation system (Flutter's standard `.arb`-based `AppLocalizations`, fully translated into Hindi and Odia) that is never actually called anywhere in the app — dead code duplicating the one that is used.

## Critical

### 1. [Customer App] Closing the language picker via the X button after selecting Hindi/Odia crashes the app to a blank white screen

**Component:** customer_app
**Area:** i18n / App Language settings
**Found via:** Manual walkthrough

**Steps to reproduce:**
1. Log in, go to Account → App Language.
2. Select "हिन्दी (Hindi)" (or "ଓଡ଼ିଆ (Odia)") in the bottom sheet.
3. Tap the **X** in the top-right of the "App Language" sheet to close it.

**Expected result:** Sheet closes, Account screen reappears with the new language selected.

**Actual result:** The entire page goes blank white and stays that way — the app does not recover on its own. The browser console shows an unhandled JS exception at the moment of the click (`main.dart.js:6993`/`6995`), immediately followed by a full cold-start sequence (`[VAYA] Cold Start: Saved session found...`, FCM re-init, session re-saved to SharedPreferences), i.e. the app force-restarts itself. Reproduced twice, once for each of Hindi and Odia. Dismissing the same sheet by tapping outside it (on the dimmed background) instead of the X works fine and does not crash — the bug is specific to the X control.

**Evidence:** Console exceptions captured at 05:58:46 and 06:04:33 (two separate reproductions), both immediately preceded by clicking the sheet's close (X) icon right after a language selection.

**Impact:** Any user who taps the natural "close" affordance after changing their language is dropped to a blank screen and has their whole session restarted. This is the single biggest usability blocker on the feature — it actively punishes users for trying to use it.

### 2. [Partner App] Selecting Hindi or Odia in "Choose App Language" throws an error and the language never actually changes

**Component:** partner_app
**Area:** i18n / App Language settings
**Found via:** Manual walkthrough

**Steps to reproduce:**
1. Log in, go to Account → App Language ("Current: English").
2. In the "Choose App Language" sheet, tap "ଓଡ଼ିଆ (Odia)" or "हिन्दी (Hindi)" (tried both the label row and the radio button itself).

**Expected result:** The radio selection moves to the tapped language and "Current:" updates.

**Actual result:** Nothing visibly happens — the radio stays on English. The browser console logs an unhandled exception (`main.dart.js:6816`) every single time the tap is made (reproduced 3 times across both languages). Re-opening the sheet afterwards always shows English still selected. **There is no way to put the Partner App into Hindi or Odia via the UI at all** — the switch is completely non-functional.

**Evidence:** Repeated `[EXCEPTION]` console entries at 06:07:10, 06:07:37 and 06:08:11, one per tap attempt, with the "Current: English" subtitle unchanged after each.

**Impact:** The headline feature under test — letting a driver-partner use the app in their own language — does not work at all in the deployed web build. Combined with finding #3 below, effectively zero translated UI is currently reachable by a real user.

### 3. [Partner App] Bottom navigation becomes completely unresponsive after the failed language-switch attempts

**Component:** partner_app
**Area:** i18n (side effect) / Navigation
**Found via:** Manual walkthrough

**Steps to reproduce:**
1. Reproduce finding #2 (attempt to select Hindi/Odia in the App Language sheet, causing the console exception).
2. Dismiss the sheet and try tapping any of the four bottom tabs (Duty / My Trips / Earnings / Account).

**Expected result:** Tapping a tab navigates to that screen.

**Actual result:** Taps on the bottom nav bar do nothing — the app is stuck on whichever screen it was on. Reloading the page (`https://vaya-partner-app.web.app`) restores normal navigation immediately.

**Evidence:** Reproduced once directly following finding #2; confirmed the nav bar works again immediately after a fresh page load.

**Impact:** A driver who merely tries to change their language setting can end up unable to navigate their app at all until they reload — a serious usability regression triggered by a settings screen that should be low-risk.

## High

### 4. [Customer App] Nearly the entire app is hardcoded English regardless of language selection

**Component:** customer_app
**Area:** i18n coverage
**Found via:** Manual walkthrough (Hindi and Odia) + code review of `customer_app/lib/main.dart`

**Actual result:** With "हिन्दी (Hindi)" or "ଓଡ଼ିଆ (Odia)" set as the app language (confirmed saved via the Account screen and to the backend — toast: "भाषा हिन्दी में बदली गई (Hindi selected)" / "Language updated to ... and saved to database"), every screen walked below rendered **100% English, with zero exceptions**:
- **Bottom navigation** — "Home", "Orders", "Payments", "Account" (these are `const` string literals in the `BottomNavigationBarItem` labels at `lib/main.dart:1852, 1874, 1879, 1884` — not even routed through the app's own translation helper).
- **Home screen** — "PICKUP" / "DROP-OFF" / "Where to deliver?", "RECENT SEARCHES", "VEHICLE CATEGORIES", vehicle names and blurbs ("Bike — Up to 20 kg · Courier & Food", "3-wheeler — Up to 500 kg · Medium loads", etc.).
- **Orders ("Deliveries") screen** — "Deliveries", "Active/Completed/Cancelled" tabs, and even the error state ("Connection Issue", "Server error (404) while loading deliveries.", "Retry Connection").
- **Payments screen** — "Payments", "VAYA Wallet balance", "Add money", "Payment activity", "All/Wallet/UPI/Cash" filters, "No All payment activity found", "Wallet terms", "Refund rules", "Failed payments?".
- **Account screen** — every section header and row ("Logistics", "Saved addresses", "Business & billing", "Preferences", "Notifications", "Help & support", "Contact support", "Disputes & refund cases", "Privacy & legal", "Download my data", "Delete account", "Sign out", version string) — the **only** string on this entire screen that changes with language is the language's own name in "App Language" (e.g. "हिन्दी (Hindi)").
- **Booking flow** — "Set Delivery Route" / "Delivery Route Confirmed" / "Trip Distance" / "Proceed to Vehicle & Fare Selection"; "Choose a vehicle" screen ("ELIGIBLE VEHICLES", vehicle names, "Best for: ...", "TRIP CUSTOMIZATION", "Goods Category", restriction notice, "Continue · Bike · ₹16"); the contact-details screen ("Pickup contact", "Sender name", "Sender mobile", "Building, flat or gate (optional)", "Receiver details", "Review order").

**Root cause (code review):** the app defines its own hand-rolled `LocalizedStrings` class (`lib/main.dart:970-1148`, ~52 translated getters) but it is only actually read from **6 places** in the whole 15,276-line file / 481 `Text(...)` widgets: the session-expired dialog, the contacts-permission dialog, part of the login screen, part of the home screen, part of the trip planner, and the vehicle-switch sheet on the tracking screen. Every other screen listed above builds its text from plain string literals that never reference `LocalizedStrings` at all.

**Impact:** A Hindi- or Odia-preferring user gets essentially the English app with a label in Settings that quietly says otherwise — the feature does not deliver on its premise for the large majority of the customer journey (browsing, booking, tracking orders, paying, and managing their account).

### 5. [Customer App] Even on screens that are partly localized, sibling strings on the same screen are left in English

**Component:** customer_app
**Area:** i18n coverage / consistency
**Found via:** Code review of `customer_app/lib/main.dart`

**Failure scenario:** On the Login/OTP screen, the heading and the "Send OTP"/"Verify OTP" button correctly pull from `LocalizedStrings` (`str.mobileLogin`, `str.verifyOtp`, `str.sendOtp` — `lib/main.dart:1398-1440`), so a Hindi user would see those translate — but the OTP entry field's label is a hardcoded literal `'Enter OTP Code'` (`lib/main.dart:1433`), and the resend control's text is hardcoded as `'Resend OTP in ${_resendCountdown}s'` / `'Resend OTP'` (`lib/main.dart:1454-1455`). The result is a single screen that mixes Hindi/Odia and English text in the same view.

**Impact:** Reads as unfinished/buggy rather than simply "not yet translated" — a partially-translated screen is more jarring to a user than a fully-English one.

### 6. [Customer App] A second, fully-translated localization system exists in the codebase but is never used

**Component:** customer_app
**Area:** i18n / dead code
**Found via:** Code review of `customer_app/lib/l10n/*.arb` and `customer_app/lib/main.dart`

**Actual result:** `customer_app/lib/l10n/app_en.arb`, `app_hi.arb`, and `app_or.arb` each define the same 52 keys (e.g. `selectLanguage`, `welcome`, `bookNow`, `myDeliveries`, `paymentsAndWallet`, `walletTopup`, `securedByRazorpay`, etc.), fully and consistently translated across all three languages, and `pubspec.yaml` has `generate: true` (Flutter's standard `AppLocalizations` code generation is wired up). However, a full-file search shows **`AppLocalizations` is never referenced anywhere in `lib/`** — it is entirely dead code, duplicating (with different, non-overlapping keys) the hand-rolled `LocalizedStrings` class that the app actually uses.

**Impact:** Not a user-facing bug by itself, but it means there are 156 already-translated strings (52 keys × 3 languages) sitting unused that could close some of the gaps in finding #4 with comparatively little engineering effort — worth flagging to the team as a quick win, alongside consolidating to a single localization approach to avoid this drifting further.

### 7. [Partner App] Nearly the entire app is hardcoded English in the source, independent of the crash in finding #2

**Component:** partner_app
**Area:** i18n coverage
**Found via:** Manual walkthrough (English, since Hindi/Odia cannot be selected — finding #2) + code review of `partner_app/lib/main.dart`

**Actual result / code review:** The app defines a `LocalizedPartnerStrings` class (`lib/main.dart:391-533`, aliased as `LocalizedDriverStrings`) with over 100 translated getters, but across the entire 11,058-line file with 355 `Text(...)` widgets, only **9 call sites** actually read from it, covering: the bottom navigation labels ("Duty"/"My Trips"/"Earnings"/"Account", `lib/main.dart:1626-1629`); the Account screen's row **titles only** ("Vehicle Details", "App Language", "Profile verification", "Support", "Payout account", "Sign Out", `lib/main.dart:10889-10985` — their subtitles are not localized); the Pending Approval screen's "Check Approval Status"/"Sign Out" (`lib/main.dart:1278-1283`); and the vehicle-type dropdown items plus "Submit Details" button on the Driver Onboarding screen (`lib/main.dart:1407-1460`).

Everything else observed live in English (which is all a real user can currently see, per finding #2) is hardcoded, including:
- **Duty (home) screen** — "Good morning, {name}", "You're Offline", "You are not receiving delivery trip requests right now...", "GO ONLINE", "TODAY'S EARNINGS", "COMPLETED TRIPS", "Assigned Vehicle: BIKE", "GPS Active • Wallet Dues Settled".
- **Trip History screen** — "Trip History", "Completed"/"Cancelled" tabs, and every trip card's "Completed" status text.
- **Earnings & Wallet screen** — "Earnings & Wallet", "Summary"/"Transactions" tabs, "Cash orders available", "Available balance", "Amount due", "₹X of ₹500 used", "Pay ₹X via UPI", "Setup Payout Bank & UPI Details", "FINANCIAL RULES & ESCALATION" and both rule descriptions.
- **Driver Onboarding screen** — even though the vehicle-type labels are localized, the screen title "Onboard Your Vehicle" (`lib/main.dart:1383`), the "Driver Full Name"/"Vehicle Class"/"License Plate (e.g. OD-02-AX-1234)" field labels (`lib/main.dart:1391,1399,1448`), and the validation messages "Enter your name"/"Enter registration plate" (`lib/main.dart:1392,1449`) are hardcoded.
- **Account screen subtitles** — "Current: English", "OD32A5679 • 2-Wheeler (Bike) • 20 kg max payload", "Driving License & Vehicle RC Verified", "Help center, live chat & 24x7 helpline", "Direct Bank Transfer (HDFC Bank •••• 4892)".

**Impact:** Even setting aside the crash, the translation work that does exist only touches a thin slice of the app (roughly a dozen labels out of hundreds of strings) — closing this gap is a substantially larger effort than finding #2 alone would suggest.

## What was verified working

- Language preference persists correctly (survives page reload) and is saved server-side for the Customer App ("Language updated to X and saved to database").
- Customer App: the session-expired dialog, the contacts-permission dialog (title/message/Cancel/Open Settings), and the vehicle-switch bottom sheet on the tracking screen render fully in the selected language with no mixed English.
- Customer App: dismissing the "App Language" sheet by tapping outside it (rather than the X) works correctly and does not crash.
- Partner App: the Pending Approval screen's "Check Approval Status"/"Sign Out" and the vehicle-type dropdown on Driver Onboarding are correctly wired to the translation class (confirmed by code; could not be seen live in Hindi/Odia due to finding #2).
- Login with the provided phone/OTP credentials worked correctly on the Customer App; both apps correctly auto-restored an existing session on load.

## Recommendation

Treat this as not-yet-shippable as a multilingual feature. Priority order: (1) fix the two language-switch bugs (findings #1 and #2) since they make the feature literally unusable today; (2) decide on one localization approach per app (the Customer App should drop either its unused `AppLocalizations`/`.arb` system or its hand-rolled `LocalizedStrings` class, not maintain both); (3) do a systematic pass wiring every remaining hardcoded string (bottom navs already fixed for Partner App, still open for Customer App; then home, orders/trips, payments/earnings, account, and booking flows in both apps) through whichever system is kept.
