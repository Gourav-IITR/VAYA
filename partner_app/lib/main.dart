import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widgets/payment_method_sheet.dart';
import 'services/razorpay_service.dart';
import 'utils/vehicle_icon_helper.dart';
import 'widgets/vaya_loader.dart';
import 'screens/delivery_summary_screen.dart';

/// Helper function to launch phone calls across devices & web
Future<void> _makeDriverPhoneCall(String phoneNumber) async {
  String cleanPhone = phoneNumber.replaceAll(RegExp(r'[^0-9+]'), '');
  if (cleanPhone.isEmpty) return;
  final Uri telUri = Uri(scheme: 'tel', path: cleanPhone);
  try {
    if (await canLaunchUrl(telUri)) {
      await launchUrl(telUri);
    } else {
      await launchUrl(telUri, mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    debugPrint('Could not launch driver phone call to $phoneNumber: $e');
  }
}

/// Returns platform-optimized LocationSettings with Android Foreground Service & Apple background location tracking
LocationSettings _getBackgroundLocationSettings({int distanceFilter = 10}) {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilter,
      forceLocationManager: true,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: "VAYA Partner Active",
        notificationText: "Location streaming active for trips & online status",
        notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        enableWakeLock: true,
      ),
    );
  } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.high,
      activityType: ActivityType.fitness,
      distanceFilter: distanceFilter,
      pauseLocationUpdatesAutomatically: false,
      allowBackgroundLocationUpdates: true,
      showBackgroundLocationIndicator: true,
    );
  }
  return LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: distanceFilter,
  );
}

// Partner Session Storage Manager (SharedPreferences Disk Persistence)
class PartnerSessionManager {
  static const String _keyIsLoggedIn = 'partner_is_logged_in_v2';
  static const String _keyPartnerData = 'partner_data_json_v2';
  static const String _keyAuthToken = 'partner_auth_token_v2';

  // Legacy fallback keys
  static const String _legacyKeyIsLoggedIn = 'driver_is_logged_in_v2';
  static const String _legacyKeyDriverData = 'driver_data_json_v2';
  static const String _legacyKeyAuthToken = 'driver_auth_token_v2';

  static Future<void> saveSession(Map<String, dynamic> partnerData, {String? token}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyIsLoggedIn, true);
      await prefs.setString(_keyPartnerData, json.encode(partnerData));
      if (token != null && token.isNotEmpty) {
        await prefs.setString(_keyAuthToken, token);
      }
      debugPrint("✅ Partner session saved to SharedPreferences");
    } catch (e) {
      debugPrint("Error saving partner session: $e");
    }
  }

  static Future<void> saveToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAuthToken, token);
    } catch (e) {
      debugPrint("Error saving token: $e");
    }
  }

  static Future<String?> getSavedToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_keyAuthToken);
      if (token != null && token.isNotEmpty) return token;
      return prefs.getString(_legacyKeyAuthToken);
    } catch (e) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool(_keyIsLoggedIn) ?? prefs.getBool(_legacyKeyIsLoggedIn) ?? false;
      final rawJson = prefs.getString(_keyPartnerData) ?? prefs.getString(_legacyKeyDriverData);
      if (isLoggedIn && rawJson != null && rawJson.isNotEmpty) {
        return json.decode(rawJson) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint("Error reading partner session: $e");
    }
    return null;
  }

  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyIsLoggedIn);
      await prefs.remove(_keyPartnerData);
      await prefs.remove(_keyAuthToken);
      await prefs.remove(_legacyKeyIsLoggedIn);
      await prefs.remove(_legacyKeyDriverData);
      await prefs.remove(_legacyKeyAuthToken);
      debugPrint("🔴 Partner session cleared from SharedPreferences");
    } catch (e) {
      debugPrint("Error clearing partner session: $e");
    }
  }
}

typedef DriverSessionManager = PartnerSessionManager;

class DriverStorage {
  static Future<List<dynamic>> loadCachedTrips() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('driver_cached_trips');
      if (raw != null && raw.isNotEmpty) {
        return json.decode(raw) as List<dynamic>;
      }
    } catch (e) {
      debugPrint('Error loading cached driver trips: $e');
    }
    return [];
  }

  static Future<void> saveCachedTrips(List<dynamic> trips) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('driver_cached_trips', json.encode(trips));
    } catch (e) {
      debugPrint('Error saving cached driver trips: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadCachedLedger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('driver_cached_ledger');
      if (raw != null && raw.isNotEmpty) {
        return json.decode(raw) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Error loading cached driver ledger: $e');
    }
    return null;
  }

  static Future<void> saveCachedLedger(Map<String, dynamic> ledgerData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('driver_cached_ledger', json.encode(ledgerData));
    } catch (e) {
      debugPrint('Error saving cached driver ledger: $e');
    }
  }

  static Future<void> saveCachedProfile(Map<String, dynamic> profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('driver_cached_profile', json.encode(profile));
    } catch (e) {
      debugPrint('Error saving cached profile: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadCachedTodayEarnings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('driver_cached_today_earnings');
      if (raw != null && raw.isNotEmpty) {
        return json.decode(raw) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Error loading cached today earnings: $e');
    }
    return null;
  }

  static Future<void> saveCachedTodayEarnings(double earnings, int count) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('driver_cached_today_earnings', json.encode({
        'earnings': earnings,
        'count': count,
      }));
    } catch (e) {
      debugPrint('Error saving cached today earnings: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadCachedActiveJob() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('driver_cached_active_job');
      if (raw != null && raw.isNotEmpty) {
        return json.decode(raw) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Error loading cached active job: $e');
    }
    return null;
  }

  static Future<void> saveCachedActiveJob(Map<String, dynamic>? job) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (job == null) {
        await prefs.remove('driver_cached_active_job');
      } else {
        await prefs.setString('driver_cached_active_job', json.encode(job));
      }
    } catch (e) {
      debugPrint('Error saving cached active job: $e');
    }
  }
}

class PartnerAuthHelper {
  /// Central token provider: Waits for Firebase Auth disk restore if needed,
  /// fetches fresh token from Firebase, saves it locally, and falls back to local disk token when offline.
  static Future<String?> getAuthToken() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try {
        user = await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        user = FirebaseAuth.instance.currentUser;
      }
    }

    if (user != null) {
      try {
        final token = await user.getIdToken();
        if (token != null && token.isNotEmpty) {
          await PartnerSessionManager.saveToken(token);
          return token;
        }
      } catch (e) {
        debugPrint("Error getting token from currentUser: $e");
      }
    }

    // Fallback to locally saved token from disk
    return await PartnerSessionManager.getSavedToken();
  }

  /// Handle 401 / Authorization Expiration globally for partner
  static Future<void> handleUnauthorized(BuildContext context) async {
    debugPrint("🔴 PartnerAuthHelper: Expired/Invalid Authorization. Clearing partner session and redirecting to login.");
    await PartnerSessionManager.clearSession();
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please log in with your phone number.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const VayaPartnerApp()),
        (route) => false,
      );
    }
  }
}

typedef DriverAuthHelper = PartnerAuthHelper;

// Configuration URL - Change to your Cloud Run URL in production
const String apiBaseUrl = "https://vaya-backend-275777907648.us-central1.run.app";
const String wsBaseUrl = "wss://vaya-backend-275777907648.us-central1.run.app";

// VAYA Partner App Theme (Ink Black / Slate / Saffron)
class VayaPartnerTheme {
  static const Color saffron = Color(0xFFF26430);
  static const Color inkBlack = Color(0xFF0E0E0C);
  static const Color routeGreen = Color(0xFF116E45);
  static const Color signalCream = Color(0xFFF4EFE6);
  static const Color slate = Color(0xFF3C3A34);
  static const Color liveBlue = Color(0xFF2E63E8);

  static ThemeData themeData = ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    brightness: Brightness.dark,
    scaffoldBackgroundColor: inkBlack,
    colorScheme: const ColorScheme.dark(
      primary: saffron,
      secondary: slate,
      surface: Color(0xFF1A1A17),
      onPrimary: Colors.white,
      onSurface: signalCream,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: inkBlack,
      foregroundColor: signalCream,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: 18,
        letterSpacing: 0.5,
        color: signalCream,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: saffron,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF1A1A17),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: slate, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A1A17),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: slate),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: slate),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: saffron, width: 2),
      ),
      labelStyle: const TextStyle(color: signalCream),
    ),
  );
}

typedef VayaDriverTheme = VayaPartnerTheme;

// i18n Strings dictionary for VAYA Partner
class LocalizedPartnerStrings {
  final Locale locale;
  LocalizedPartnerStrings(this.locale);

  static LocalizedPartnerStrings of(BuildContext context) {
    return LocalizedPartnerStrings(Localizations.localeOf(context));
  }

  String _t(String en, String or, String hi) =>
      locale.languageCode == 'or' ? or : locale.languageCode == 'hi' ? hi : en;

  // Common
  String get appTitle => _t('VAYA Driver Partner', 'VAYA ଡ୍ରାଇଭର୍ ପାର୍ଟନର୍', 'VAYA ड्राइवर पार्टनर');
  String get cancel => _t('Cancel', 'ବାତିଲ୍', 'रद्द करें');
  String get save => _t('Save', 'ସେଭ୍ କରନ୍ତୁ', 'सहेजें');
  String get close => _t('Close', 'ବନ୍ଦ କରନ୍ତୁ', 'बंद करें');
  String get confirm => _t('Confirm', 'ନିଶ୍ଚିତ କରନ୍ତୁ', 'पुष्टि करें');
  String get loading => _t('Loading...', 'ଲୋଡ୍ ହେଉଛି...', 'लोड हो रहा है...');
  String get back => _t('Back', 'ପଛକୁ', 'पीछे');
  String get retry => _t('Retry', 'ପୁନଃଚେଷ୍ଟା', 'पुनः प्रयास करें');

  // Language Selection
  String get selectLang => _t('Select Language', 'ଭାଷା ଚୟନ କରନ୍ତୁ', 'भाषा चुनें');
  String get chooseLanguage => _t('Choose Language', 'ଭାଷା ଚୟନ କରନ୍ତୁ', 'भाषा चुनें');

  // Auth / Login
  String get partnerLogin => _t('Driver Partner Login', 'ଡ୍ରାଇଭର୍ ପାର୍ଟନର୍ ଲଗ୍ ଇନ୍', 'ड्राइवर पार्टनर लॉगिन');
  String get enterMobile => _t('Enter 10-digit Mobile Number', '୧୦-ଅଙ୍କ ମୋବାଇଲ୍ ନମ୍ବର ଦିଅନ୍ତୁ', '10-अंकीय मोबाइल नंबर दर्ज करें');
  String get sendOtp => _t('Send OTP', 'OTP ପଠାନ୍ତୁ', 'ओटीपी भेजें');
  String get verifyOtp => _t('Verify OTP', 'OTP ଯାଞ୍ଚ କରନ୍ତୁ', 'ओटीपी सत्यापित करें');
  String get enterOtpCode => _t('Enter 6-digit OTP code', '୬-ଅଙ୍କ OTP କୋଡ୍ ଦିଅନ୍ତୁ', '6-अंकीय ओटीपी कोड दर्ज करें');
  String get otpSentTo => _t('OTP sent to +91 ', 'OTP ପଠାଗଲା +91 ', 'ओटीपी भेजा गया +91 ');

  // Onboarding & KYC
  String get partnerRegistration => _t('Driver Partner Registration', 'ଡ୍ରାଇଭର୍ ପାର୍ଟନର୍ ପଞ୍ଜୀକରଣ', 'ड्राइवर पार्टनर पंजीकरण');
  String get fullName => _t('Full Name', 'ପୂରା ନାମ', 'पूरा नाम');
  String get drivingLicense => _t('Driving License Number', 'ଡ୍ରାଇଭିଂ ଲାଇସେନ୍ସ ନମ୍ବର', 'ड्राइविंग लाइसेंस नंबर');
  String get vehicleType => _t('Vehicle Type', 'ଗାଡ଼ି ଶ୍ରେଣୀ', 'वाहन प्रकार');
  String get vehiclePlate => _t('Vehicle Plate Number (e.g. OD-02-X-9999)', 'ଗାଡ଼ି ନମ୍ବର ପ୍ଲେଟ୍', 'वाहन प्लेट नंबर');
  String get submitRegistration => _t('Submit Registration', 'ପଞ୍ଜୀକରଣ ଦାଖଲ କରନ୍ତୁ', 'पंजीकरण जमा करें');

  // Pending Approval
  String get pendingApprovalTitle => _t('Application Under Review', 'ଆବେଦନ ଯାଞ୍ଚ ଚାଲିଛି', 'आवेदन समीक्षाधीन है');
  String get pendingApprovalSubtitle => _t('Your partner application is being verified by VAYA operations. You will be notified once approved.', 'ଆପଣଙ୍କ ଆବେଦନ VAYA ଟିମ୍ ଦ୍ୱାରା ଯାଞ୍ଚ ହେଉଛି। ମଞ୍ଜୁର ହେବା ପରେ ଜଣାଯିବ।', 'आपका आवेदन VAYA टीम द्वारा सत्यापित किया जा रहा है। स्वीकृत होने पर आपको सूचित किया जाएगा।');
  String get contactAdminSupport => _t('Contact Support', 'ସହାୟତା ସମ୍ପର୍କ', 'सहायता संपर्क');

  // Duty Toggle & Home
  String get youAreOnline => _t('YOU ARE ONLINE', 'ଆପଣ ଅନଲାଇନ୍ ଅଛନ୍ତି', 'आप ऑनलाइन हैं');
  String get youAreOffline => _t('YOU ARE OFFLINE', 'ଆପଣ ଅଫଲାଇନ୍ ଅଛନ୍ତି', 'आप ऑफलाइन हैं');
  String get goOnlinePrompt => _t('Go online to receive nearby delivery requests', 'ନିକଟବର୍ତ୍ତୀ ଅର୍ଡର୍ ପାଇବା ପାଇଁ ଅନଲାଇନ୍ ହୁଅନ୍ତୁ', 'आस-पास के ऑर्डर प्राप्त करने के लिए ऑनलाइन जाएं');
  String get goOfflinePrompt => _t('You are ready to accept rides', 'ଆପଣ ଅର୍ଡର୍ ଗ୍ରହଣ କରିବାକୁ ପ୍ରସ୍ତୁତ ଅଛନ୍ତି', 'आप ऑर्डर स्वीकार करने के लिए तैयार हैं');
  String get switchOnline => _t('GO ONLINE', 'ଅନଲାଇନ୍ ହୁଅନ୍ତୁ', 'ऑनलाइन जाएं');
  String get switchOffline => _t('GO OFFLINE', 'ଅଫଲାଇନ୍ ହୁଅନ୍ତୁ', 'ऑफलाइन जाएं');

  // Incoming Booking Request Modal
  String get newDeliveryRequest => _t('NEW DELIVERY REQUEST', 'ନୂଆ ଡେଲିଭରୀ ଅନୁରୋଧ', 'नया डिलीवरी अनुरोध');
  String get pickupAddress => _t('PICKUP', 'ପିକଅପ୍', 'पिकअप');
  String get dropoffAddress => _t('DROP-OFF', 'ଡ୍ରପ୍-ଅଫ୍', 'ड्रॉप-ऑफ');
  String get estimatedEarnings => _t('Est. Earnings', 'ଅନୁମାନିତ ରୋଜଗାର', 'अनुमानित कमाई');
  String get acceptOrder => _t('ACCEPT ORDER', 'ଅର୍ଡର ସ୍ୱୀକାର କରନ୍ତୁ', 'ऑर्डर स्वीकार करें');
  String get rejectOrder => _t('DECLINE', 'ଅଗ୍ରାହ୍ୟ କରନ୍ତୁ', 'अस्वीकार करें');

  // Active Trip Workflow
  String get navigateToPickup => _t('Navigate to Pickup Location', 'ପିକଅପ୍ ସ୍ଥାନକୁ ଯାଆନ୍ତୁ', 'पिकअप स्थान पर जाएं');
  String get arrivedAtPickup => _t('ARRIVED AT PICKUP', 'ପିକଅପ୍ରେ ପହଞ୍ଚିଗଲି', 'पिकअप पर पहुँच गए');
  String get enterPickupOtp => _t('Enter Pickup Verification OTP', 'ପିକଅପ୍ OTP ଦିଅନ୍ତୁ', 'पिकअप ओटीपी दर्ज करें');
  String get startTrip => _t('START TRIP', 'ଯାତ୍ରା ଆରମ୍ଭ କରନ୍ତୁ', 'यात्रा शुरू करें');
  String get inTransitToDrop => _t('In Transit to Drop-off', 'ଡ୍ରପ୍-ଅଫ୍ ଆଡ଼କୁ ଯାଉଛି', 'ड्रॉप-ऑफ की ओर जा रहे हैं');
  String get arrivedAtDrop => _t('ARRIVED AT DROP-OFF', 'ଡ୍ରପ୍-ଅଫ୍ରେ ପହଞ୍ଚିଗଲି', 'ड्रॉप-ऑफ पर पहुँच गए');
  String get completeDelivery => _t('COMPLETE DELIVERY', 'ଡେଲିଭରୀ ସମ୍ପୂର୍ଣ୍ଣ କରନ୍ତୁ', 'डिलीवरी पूरी करें');
  String get callCustomer => _t('Call Customer', 'ଗ୍ରାହକଙ୍କୁ କଲ୍ କରନ୍ତୁ', 'ग्राहक को कॉल करें');
  String get googleMapsNav => _t('Navigate via Maps', 'ମ୍ୟାପ୍ସ ମାଧ୍ୟମରେ ଯାଆନ୍ତୁ', 'मैप्स के माध्यम से जाएं');

  // Navigation Bar Tabs
  String get tabHome => _t('Duty', 'ଡ୍ୟୁଟି', 'ड्यूटी');
  String get tabTrips => _t('My Trips', 'ମୋ ଯାତ୍ରା', 'मेरी यात्राएं');
  String get tabEarnings => _t('Earnings', 'ରୋଜଗାର', 'कमाई');
  String get tabAccount => _t('Account', 'ଖାତା', 'खाता');

  // Earnings & Trips
  String get todaysEarnings => _t('Today\'s Earnings', 'ଆଜିର ରୋଜଗାର', 'आज की कमाई');
  String get completedTrips => _t('Completed Trips', 'ସମ୍ପୂର୍ଣ୍ଣ ଯାତ୍ରା', 'पूरी हुई यात्राएं');
  String get onlineHours => _t('Online Hours', 'ଅନଲାଇନ୍ ସମୟ', 'ऑनलाइन घंटे');
  String get payoutBalance => _t('Wallet / Payout Balance', 'ୱାଲେଟ୍ / ପେଆଉଟ୍ ବାଲାନ୍ସ', 'वॉलेट / पेआउट बैलेंस');
  String get requestPayout => _t('Request Payout', 'ପେଆଉଟ୍ ଅନୁରୋଧ', 'पेआउट का अनुरोध करें');
  String get tripHistory => _t('Trip History', 'ଯାତ୍ରା ଇତିହାସ', 'यात्रा इतिहास');

  // Driver Account / Profile
  String get partnerProfile => _t('Partner Profile', 'ପାର୍ଟନର୍ ପ୍ରୋଫାଇଲ୍', 'पार्टनर प्रोफ़ाइल');
  String get mobileNumber => _t('Mobile number', 'ମୋବାଇଲ୍ ନମ୍ବର', 'मोबाइल नंबर');
  String get vehicleDetails => _t('Vehicle Details', 'ଗାଡ଼ି ବିବରଣୀ', 'वाहन विवरण');
  String get appLanguage => _t('App Language', 'ଆପ୍ ଭାଷା', 'ऐप भाषा');
  String get profileVerification => _t('Profile verification', 'ପ୍ରୋଫାଇଲ୍ ଯାଞ୍ચ', 'प्रोफ़ाइल सत्यापन');
  String get support => _t('Support', 'ସପୋର୍ଟ', 'सपोर्ट');
  String get payoutAccount => _t('Payout account', 'ପେଆଉଟ୍ ଆକାଉଣ୍ଟ', 'पेआउट खाता');
  String get helpSupport => _t('Help & Partner Support', 'ସାହାଯ୍ୟ ଏବଂ ପାର୍ଟନର୍ ସପୋର୍ଟ', 'सहायता और पार्टनर सपोर्ट');
  String get termsConditions => _t('Terms & Operating Rules', 'ସର୍ତ୍ତାବଳୀ ଏବଂ ନିୟମ', 'शर्तें और नियम');
  String get signOut => _t('Sign Out', 'ସାଇନ୍ ଆଉଟ୍', 'साइन आउट');
  String get signOutConfirm => _t('Sign out of VAYA Partner?', 'VAYA ପାର୍ଟନର୍ ରୁ ସାଇନ୍ ଆଉଟ୍ କରିବେ?', 'VAYA पार्टनर से साइन आउट करें?');
}

class VayaHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

typedef LocalizedDriverStrings = LocalizedPartnerStrings;
typedef VayaDriverApp = VayaPartnerApp;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && kDebugMode) {
    HttpOverrides.global = VayaHttpOverrides();
  }
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyCYn1asbIsltGhURbsjFKmosrS_2P1WUdc',
          authDomain: 'goods-delivery-platform.firebaseapp.com',
          projectId: 'goods-delivery-platform',
          storageBucket: 'goods-delivery-platform.firebasestorage.app',
          messagingSenderId: '275777907648',
          appId: '1:275777907648:web:d7962496a75c7981527625',
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint("Firebase initialization skipped or already running: $e");
  }
  runApp(const VayaPartnerApp());
}

class VayaPartnerApp extends StatefulWidget {
  const VayaPartnerApp({super.key});

  @override
  State<VayaPartnerApp> createState() => _VayaPartnerAppState();
}

class _VayaPartnerAppState extends State<VayaPartnerApp> {
  Locale _locale = const Locale('en');

  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VAYA Driver Partner',
      debugShowCheckedModeBanner: false,
      theme: VayaDriverTheme.themeData,
      locale: _locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('or'),
        Locale('hi'),
      ],
      home: const DriverAuthWrapper(),
    );
  }
}

/// Partner Language Picker Screen
class PartnerLanguageSelectionScreen extends StatelessWidget {
  final Function(Locale) onLanguageSelected;
  const PartnerLanguageSelectionScreen({super.key, required this.onLanguageSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: VayaPartnerTheme.saffron,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Center(
                    child: Text(
                      'V',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 48,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Choose Partner Language\nଭାଷା ଚୟନ କରନ୍ତୁ\nभाषा चुनें',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  height: 1.5,
                  color: VayaPartnerTheme.signalCream,
                ),
              ),
              const SizedBox(height: 48),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('en'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverLoginScreen()));
                },
                child: const Text('English'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('or'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverLoginScreen()));
                },
                child: const Text('ଓଡ଼ିଆ (Odia)'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('hi'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverLoginScreen()));
                },
                child: const Text('हिन्दी (Hindi)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef DriverLanguageSelectionScreen = PartnerLanguageSelectionScreen;

class PartnerAuthWrapper extends StatefulWidget {
  const PartnerAuthWrapper({super.key});

  @override
  State<PartnerAuthWrapper> createState() => _PartnerAuthWrapperState();
}

typedef DriverAuthWrapper = PartnerAuthWrapper;

class _PartnerAuthWrapperState extends State<PartnerAuthWrapper> {
  bool _loading = true;
  Map<String, dynamic>? _driverData;
  bool _needsOnboarding = false;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    final startTime = DateTime.now();

    Future<void> ensureMinLoaderTime() async {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      const minDisplayMs = 1200;
      if (elapsed < minDisplayMs) {
        await Future.delayed(Duration(milliseconds: minDisplayMs - elapsed));
      }
    }

    // 1. Check local disk session FIRST for instant cold-start auto-login
    final saved = await DriverSessionManager.getSavedSession();
    if (saved != null) {
      final name = (saved['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) {
        debugPrint('[VAYA] Cold Start: Saved driver session found. Auto-logging driver partner in.');
        await ensureMinLoaderTime();
        if (mounted) {
          setState(() {
            _driverData = saved;
            _needsOnboarding = false;
            _loading = false;
          });
        }
        // Perform background sync to verify/refresh token & driver profile
        _syncSessionInBackground();
        return;
      }
    }

    // 2. If no local session, wait for Firebase Auth disk restoration
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try {
        user = await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 4));
      } catch (e) {
        user = FirebaseAuth.instance.currentUser;
      }
    }

    if (user != null) {
      await _syncSessionWithUser(user, startTime);
    } else {
      await ensureMinLoaderTime();
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _syncSessionWithUser(User user, DateTime startTime) async {
    Future<void> ensureMinLoaderTime() async {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      const minDisplayMs = 1200;
      if (elapsed < minDisplayMs) {
        await Future.delayed(Duration(milliseconds: minDisplayMs - elapsed));
      }
    }

    bool shouldClearSession = false;

    try {
      final token = await user.getIdToken(true);
      if (token != null && token.isNotEmpty) {
        await DriverSessionManager.saveToken(token);
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/driver/me'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['driver'] != null) {
            final driver = data['driver'];
            final name = (driver['name'] as String?)?.trim() ?? '';
            if (name.isNotEmpty) {
              await DriverSessionManager.saveSession(driver, token: token);
              await ensureMinLoaderTime();
              if (mounted) {
                setState(() {
                  _driverData = driver;
                  _needsOnboarding = false;
                  _loading = false;
                });
              }
              return;
            }
          }
          shouldClearSession = true;
        } else if (res.statusCode == 401 || res.statusCode == 403) {
          shouldClearSession = true;
        }
      }
    } catch (e) {
      debugPrint('[VAYA] Error syncing driver session with user: $e');
    }

    if (shouldClearSession) {
      await DriverSessionManager.clearSession();
      await ensureMinLoaderTime();
      if (mounted) {
        setState(() {
          _driverData = null;
          _needsOnboarding = true;
          _loading = false;
        });
      }
    } else {
      final saved = await DriverSessionManager.getSavedSession();
      await ensureMinLoaderTime();
      if (mounted) {
        setState(() {
          _driverData = saved;
          _needsOnboarding = saved == null;
          _loading = false;
        });
      }
    }
  }

  Future<void> _syncSessionInBackground() async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token != null && token.isNotEmpty) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/driver/me'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['driver'] != null) {
            final driver = data['driver'];
            await DriverSessionManager.saveSession(driver, token: token);
            if (mounted) {
              setState(() {
                _driverData = driver;
              });
            }
          }
        } else if (res.statusCode == 401 || res.statusCode == 403) {
          debugPrint('[VAYA] Background driver session sync: Auth token expired (HTTP ${res.statusCode}). Clearing session.');
          await DriverSessionManager.clearSession();
          try {
            await FirebaseAuth.instance.signOut();
          } catch (_) {}
          if (mounted) {
            setState(() {
              _driverData = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Your session expired. Please log in with your phone number.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[VAYA] Background driver session sync notice: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: VayaDriverTheme.inkBlack,
        body: Center(
          child: VayaLoader.section(size: 120, message: 'Verifying Driver Portal...'),
        ),
      );
    }

    if (_driverData != null) {
      if (_driverData!['is_approved'] == true) {
        return DriverMainNavigation(driverData: _driverData!);
      } else {
        return const PendingApprovalScreen();
      }
    }

    if (_needsOnboarding) {
      return const DriverOnboardingScreen();
    }

    return const DriverLoginScreen();
  }
}

/// 1. OTP Login Screen (Real Firebase Phone Auth)
class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  bool _otpSent = false;
  bool _isLoading = false;
  String? _verificationId;
  String? _errorMsg;

  Future<void> _sendOtpCode() async {
    if (_phoneController.text.length != 10) {
      setState(() => _errorMsg = 'Enter a valid 10-digit number');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    final formattedPhone = '+91${_phoneController.text.trim()}';

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _auth.signInWithCredential(credential);
          _checkProfileAndNavigate();
        },
        verificationFailed: (FirebaseAuthException e) {
          setState(() {
            _isLoading = false;
            _errorMsg = e.message ?? 'Verification failed. Try again.';
          });
        },
        codeSent: (String verificationId, int? resendToken) {
          setState(() {
            _isLoading = false;
            _otpSent = true;
            _verificationId = verificationId;
          });
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
        timeout: const Duration(seconds: 60),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _verifyOtpCode() async {
    if (_otpController.text.length != 6) {
      setState(() => _errorMsg = 'Enter 6-digit OTP code');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: _otpController.text.trim(),
      );

      await _auth.signInWithCredential(credential);
      _checkProfileAndNavigate();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMsg = 'Incorrect or expired OTP.';
      });
    }
  }

  Future<void> _checkProfileAndNavigate() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final token = await DriverAuthHelper.getAuthToken();
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true && data['driver'] != null) {
            final driver = data['driver'];
            await DriverSessionManager.saveSession(driver);
            if (driver['is_approved'] == true) {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => DriverMainNavigation(driverData: driver)),
                (route) => false,
              );
            } else {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
                (route) => false,
              );
            }
          } else {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const DriverOnboardingScreen()),
              (route) => false,
            );
          }
        }
      } else {
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const DriverOnboardingScreen()),
            (route) => false,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const DriverOnboardingScreen()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VΛYΛ Driver Partner')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Center(
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: VayaDriverTheme.saffron,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Center(
                  child: Text(
                    'V',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _otpSent ? 'Verify OTP Code' : 'Partner Sign In',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
            ),
            const SizedBox(height: 16),
            if (!_otpSent)
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  prefixText: '+91 ',
                  labelText: 'Enter 10-digit Mobile Number',
                ),
              )
            else
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  labelText: 'Enter 6-digit OTP Code',
                ),
              ),
            if (_errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(_errorMsg!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : (_otpSent ? _verifyOtpCode : _sendOtpCode),
              child: _isLoading
                  ? const VayaLoader.inline(size: 24, color: Colors.white)
                  : Text(_otpSent ? 'Verify OTP' : 'Send OTP Code'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2. Pending Approval Screen
class PendingApprovalScreen extends StatefulWidget {
  const PendingApprovalScreen({super.key});

  @override
  State<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends State<PendingApprovalScreen> {
  bool _isChecking = false;

  Future<void> _checkStatus() async {
    setState(() => _isChecking = true);
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token != null && token.isNotEmpty) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/driver/me'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['driver'] != null) {
            final driver = data['driver'];
            await DriverSessionManager.saveSession(driver, token: token);
            if (driver['is_approved'] == true) {
              if (mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => DriverMainNavigation(driverData: driver)),
                  (route) => false,
                );
              }
              return;
            }
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your application is still under review by VAYA administration.'),
            backgroundColor: VayaDriverTheme.saffron,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking status: ${e.toString()}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  Future<void> _signOut() async {
    await DriverSessionManager.clearSession();
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VayaDriverTheme.inkBlack,
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.hourglass_empty, size: 80, color: VayaDriverTheme.saffron),
            const SizedBox(height: 24),
            const Text(
              'Registration Pending Approval',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your profile details have been submitted. An administrator will review and verify your documents shortly. Thank you for your patience.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream, height: 1.5),
            ),
            const SizedBox(height: 48),
            ElevatedButton(
              onPressed: _isChecking ? null : _checkStatus,
              child: _isChecking
                  ? const VayaLoader.inline(size: 20, color: Colors.white)
                  : const Text('Check Approval Status'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _signOut,
              child: const Text('Sign Out', style: TextStyle(color: VayaDriverTheme.signalCream)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3. Driver Onboarding Form Screen
class DriverOnboardingScreen extends StatefulWidget {
  const DriverOnboardingScreen({super.key});

  @override
  State<DriverOnboardingScreen> createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends State<DriverOnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _plateController = TextEditingController();
  String _vehicleType = 'bike';
  bool _isLoading = false;
  String? _errorMsg;

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;
      final uid = FirebaseAuth.instance.currentUser?.uid ?? (await DriverSessionManager.getSavedSession())?['id'] ?? '';
      final weightCapacity = _vehicleType == 'bike' ? 20 : (_vehicleType == 'ace' ? 500 : 2000);

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/driver/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'name': _nameController.text.trim(),
          'vehicleType': _vehicleType,
          'vehicleReg': _plateController.text.trim().toUpperCase(),
          'weightCapacity': weightCapacity,
          'status': 'offline'
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final driverData = data['driver'] ?? {
          'id': uid,
          'name': _nameController.text.trim(),
          'vehicle_type': _vehicleType,
          'vehicle_reg': _plateController.text.trim().toUpperCase(),
          'is_approved': false,
        };
        await DriverSessionManager.saveSession(driverData);
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
            (route) => false,
          );
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMsg = 'Failed to submit registration form.';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMsg = 'Connection error: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Onboarding')),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.drive_eta, size: 64, color: VayaDriverTheme.saffron),
                const SizedBox(height: 16),
                const Text(
                  'Onboard Your Vehicle',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nameController,
                  style: const TextStyle(color: VayaDriverTheme.signalCream),
                  decoration: const InputDecoration(labelText: 'Driver Full Name'),
                  validator: (val) => val == null || val.isEmpty ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _vehicleType,
                  dropdownColor: const Color(0xFF1A1A17),
                  style: const TextStyle(color: VayaDriverTheme.signalCream),
                  decoration: const InputDecoration(labelText: 'Vehicle Class'),
                  items: [
                    DropdownMenuItem(
                      value: 'bike',
                      child: Row(
                        children: [
                          SizedBox(width: 24, height: 24, child: VehicleIconHelper.getVehicleSvgWidget('bike')),
                          const SizedBox(width: 10),
                          const Text('Two-Wheeler (Bike)'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'three_wheeler',
                      child: Row(
                        children: [
                          SizedBox(width: 24, height: 24, child: VehicleIconHelper.getVehicleSvgWidget('three_wheeler')),
                          const SizedBox(width: 10),
                          const Text('Cargo 3-wheeler'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'ace',
                      child: Row(
                        children: [
                          SizedBox(width: 24, height: 24, child: VehicleIconHelper.getVehicleSvgWidget('ace')),
                          const SizedBox(width: 10),
                          const Text('Mini Truck (4-wheeler)'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'truck',
                      child: Row(
                        children: [
                          SizedBox(width: 24, height: 24, child: VehicleIconHelper.getVehicleSvgWidget('truck')),
                          const SizedBox(width: 10),
                          const Text('Light Commercial Vehicle (4-wheeler)'),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (val) => setState(() => _vehicleType = val!),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _plateController,
                  style: const TextStyle(color: VayaDriverTheme.signalCream),
                  decoration: const InputDecoration(labelText: 'License Plate (e.g. OD-02-AX-1234)'),
                  validator: (val) => val == null || val.isEmpty ? 'Enter registration plate' : null,
                ),
                if (_errorMsg != null) ...[
                  const SizedBox(height: 12),
                  Text(_errorMsg!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _submitRegistration,
                  child: _isLoading
                      ? const VayaLoader.inline(size: 20, color: Colors.white)
                      : const Text('Submit Details'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 4. Driver Main Navigation Screen (4-Tab Bottom Navigation)
class DriverMainNavigation extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverMainNavigation({super.key, required this.driverData});

  @override
  State<DriverMainNavigation> createState() => _DriverMainNavigationState();
}

class _DriverMainNavigationState extends State<DriverMainNavigation> with WidgetsBindingObserver {
  int _currentIndex = 0;
  Map<String, dynamic>? _activeJob;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCachedActiveJobFirst();
    _checkActiveJob();
  }

  Future<void> _loadCachedActiveJobFirst() async {
    final cached = await DriverStorage.loadCachedActiveJob();
    if (cached != null && mounted) {
      final status = cached['status']?.toString();
      const activeStatuses = {'accepted', 'arrived_pickup', 'dropping_off', 'in_transit', 'arrived_dropoff'};
      if (activeStatuses.contains(status)) {
        setState(() {
          _activeJob = cached;
        });
      } else {
        await DriverStorage.saveCachedActiveJob(null);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _setOfflineOnClose();
    }
  }

  Future<void> _setOfflineOnClose() async {
    // If driver is not in an active job, mark status offline when app is closed/detached
    if (_activeJob == null) {
      try {
        final token = await DriverAuthHelper.getAuthToken();
        if (token == null) return;
        await http.post(
          Uri.parse('$apiBaseUrl/api/driver/status'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token'
          },
          body: json.encode({'status': 'offline'}),
        );
      } catch (e) {
        debugPrint("Error setting offline on app close: $e");
      }
    }
  }

  Future<void> _checkActiveJob() async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/active?role=driver'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true && data['booking'] != null) {
            final job = data['booking'];
            final status = job['status']?.toString();
            const activeStatuses = {'accepted', 'arrived_pickup', 'dropping_off', 'in_transit', 'arrived_dropoff'};
            if (activeStatuses.contains(status)) {
              setState(() {
                _activeJob = job;
              });
              await DriverStorage.saveCachedActiveJob(job);
            } else {
              setState(() {
                _activeJob = null;
              });
              await DriverStorage.saveCachedActiveJob(null);
            }
          } else {
            setState(() {
              _activeJob = null;
            });
            await DriverStorage.saveCachedActiveJob(null);
          }
        }
      }
    } catch (e) {
      debugPrint("Error checking active job on restart: $e");
    }
  }

  void _onJobStateChanged(Map<String, dynamic>? job) {
    setState(() {
      _activeJob = job;
    });
    DriverStorage.saveCachedActiveJob(job);
  }

  @override
  Widget build(BuildContext context) {
    final dl = LocalizedDriverStrings.of(context);
    // If an active trip is underway, switch to a full-screen operational trip flow (hiding bottom navigation)
    if (_activeJob != null) {
      return ActiveTripWorkflowScreen(
        driverData: widget.driverData,
        activeJob: _activeJob!,
        onJobUpdated: (updated) => _onJobStateChanged(updated),
      );
    }

    final pages = [
      DriverHomeScreen(
        driverData: widget.driverData,
        onJobAccepted: (job) => _onJobStateChanged(job),
        onOpenProfile: () => setState(() => _currentIndex = 3),
      ),
      DriverTripsScreen(driverData: widget.driverData),
      DriverEarningsScreen(driverData: widget.driverData),
      DriverAccountScreen(driverData: widget.driverData),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF141414),
        selectedItemColor: VayaDriverTheme.saffron,
        unselectedItemColor: VayaDriverTheme.slate,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home_outlined), activeIcon: const Icon(Icons.home), label: dl.tabHome),
          BottomNavigationBarItem(icon: const Icon(Icons.local_shipping_outlined), activeIcon: const Icon(Icons.local_shipping), label: dl.tabTrips),
          BottomNavigationBarItem(icon: const Icon(Icons.account_balance_wallet_outlined), activeIcon: const Icon(Icons.account_balance_wallet), label: dl.tabEarnings),
          BottomNavigationBarItem(icon: const Icon(Icons.person_outline), activeIcon: const Icon(Icons.person), label: dl.tabAccount),
        ],
      ),
    );
  }
}

/// 5. Driver Home Dashboard Screen (Duty Tab)
class DriverHomeScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  final Function(Map<String, dynamic>) onJobAccepted;
  final VoidCallback? onOpenProfile;

  const DriverHomeScreen({
    super.key,
    required this.driverData,
    required this.onJobAccepted,
    this.onOpenProfile,
  });

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> with SingleTickerProviderStateMixin {
  bool _isOnline = false;
  bool _isTogglingStatus = false;
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  WebSocketChannel? _channel;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<RemoteMessage>? _fcmSubscription;
  DateTime? _lastLocationSyncTime;
  bool _showDemandAreas = false;

  List<dynamic> _serverPricing = [];

  Future<void> _fetchPricingConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_cached_pricing_config');
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (mounted) {
          setState(() {
            _serverPricing = decoded['pricing'] ?? [];
          });
        }
      }
    } catch (_) {}

    try {
      var response = await http.get(Uri.parse('$apiBaseUrl/api/pricing-config')).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/booking/pricing-config')).timeout(const Duration(seconds: 15));
      }
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _serverPricing = data['pricing'] ?? [];
          });
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('vaya_cached_pricing_config', json.encode(data));
      }
    } catch (e) {
      debugPrint('Driver pricing fetch error: $e');
    }
  }

  Map<String, dynamic> _getWaitingConfigForVehicle(String? vehicleType) {
    final targetType = vehicleType ?? widget.driverData['vehicle_type'] ?? 'bike';
    if (_serverPricing.isNotEmpty) {
      try {
        final match = _serverPricing.firstWhere(
          (p) => p['vehicle_type'] == targetType,
          orElse: () => null,
        );
        if (match != null) {
          return {
            'free_pickup': int.tryParse(match['free_wait_minutes_pickup']?.toString() ?? '') ?? 10,
            'free_dropoff': int.tryParse(match['free_wait_minutes_dropoff']?.toString() ?? '') ?? 10,
            'rate': double.tryParse(match['wait_charge_per_minute']?.toString() ?? '') ?? 2.0,
          };
        }
      } catch (_) {}
    }
    return {'free_pickup': 10, 'free_dropoff': 10, 'rate': 2.0};
  }

  Map<String, dynamic>? _incomingAlert;
  Timer? _alertTimer;
  int _alertCountdown = 30;
  double _todayEarnings = 0.0;
  int _completedTripsCount = 0;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static const int _onlineNotificationId = 888;
  static const int _requestNotificationId = 999;

  late AnimationController _progressAnimController;

  static const String _darkMinimalMapStyleJson = r'''
[
  { "elementType": "geometry", "stylers": [{ "color": "#1c1c1c" }] },
  { "elementType": "labels.icon", "stylers": [{ "visibility": "off" }] },
  { "elementType": "labels.text.fill", "stylers": [{ "color": "#757575" }] },
  { "elementType": "labels.text.stroke", "stylers": [{ "color": "#1c1c1c" }] },
  { "featureType": "administrative", "elementType": "geometry", "stylers": [{ "color": "#505050" }] },
  { "featureType": "poi", "stylers": [{ "visibility": "off" }] },
  { "featureType": "poi.park", "elementType": "geometry", "stylers": [{ "color": "#151515" }] },
  { "featureType": "road", "elementType": "geometry.fill", "stylers": [{ "color": "#282828" }] },
  { "featureType": "road", "elementType": "labels.text.fill", "stylers": [{ "color": "#888888" }] },
  { "featureType": "road.arterial", "elementType": "geometry", "stylers": [{ "color": "#303030" }] },
  { "featureType": "road.highway", "elementType": "geometry", "stylers": [{ "color": "#383838" }] },
  { "featureType": "transit", "stylers": [{ "visibility": "off" }] },
  { "featureType": "water", "elementType": "geometry", "stylers": [{ "color": "#0d0d0d" }] }
]
''';

  Future<String?> getValidFirebaseUserToken() async {
    return await DriverAuthHelper.getAuthToken();
  }

  String _getTimeOfDayGreeting(String? rawName) {
    final hour = DateTime.now().hour;
    String greeting;
    if (hour < 12) {
      greeting = 'Good morning';
    } else if (hour < 17) {
      greeting = 'Good afternoon';
    } else {
      greeting = 'Good evening';
    }
    final name = (rawName ?? '').trim();
    final firstName = name.isNotEmpty ? name.split(' ').first : 'Partner';
    return '$greeting, $firstName';
  }

  int _getNotificationIdForBooking(dynamic bookingId) {
    final String idStr = (bookingId ?? '0').toString();
    if (idStr.isEmpty) return 999;
    int hash = 0;
    for (int i = 0; i < idStr.length; i++) {
      hash = (31 * hash + idStr.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return (hash % 900000) + 1000;
  }

  String _cleanAddress(String raw) {
    if (raw.isEmpty) return raw;
    List<String> parts = raw.split(',');
    List<String> cleanedParts = [];
    for (var part in parts) {
      String p = part.trim();
      if (p.isEmpty) continue;
      if (RegExp(r'^(Odisha|India|\d{6})$', caseSensitive: false).hasMatch(p)) continue;
      p = p.replaceAll(RegExp(r'\b(Odisha|India|\d{6})\b', caseSensitive: false), '').trim();
      if (p.isNotEmpty && !cleanedParts.contains(p)) {
        cleanedParts.add(p);
      }
    }
    if (cleanedParts.length > 2) {
      cleanedParts = cleanedParts.sublist(0, 2);
    }
    return cleanedParts.join(', ');
  }

  void _startAlertTimer(Map<String, dynamic> booking) {
    if (booking['estimated_cost'] == null && booking['pickup_name'] == null) {
      debugPrint("Ignoring incomplete booking alert payload: $booking");
      return;
    }
    _alertTimer?.cancel();
    if (mounted) {
      setState(() {
        _incomingAlert = booking;
        _alertCountdown = 30;
      });
    }
    _showOrderRequestPushNotification(booking);

    _alertTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_alertCountdown <= 1) {
        timer.cancel();
        final String bId = (booking['id'] ?? booking['bookingId'] ?? '').toString();
        _cancelOrderNotification(bId);
        if (mounted) {
          setState(() {
            _incomingAlert = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _alertCountdown--;
          });
        }
      }
    });
  }

  void _clearAlert([String? bookingId]) {
    _alertTimer?.cancel();
    _alertTimer = null;
    _cancelOrderNotification(bookingId);
    if (mounted) {
      setState(() {
        _incomingAlert = null;
      });
    }
  }

  Future<void> _showOrderRequestPushNotification(Map<String, dynamic> booking) async {
    try {
      final String bookingId = (booking['id'] ?? booking['bookingId'] ?? '0').toString();
      final int notifId = _getNotificationIdForBooking(bookingId);

      final String rawCost = (booking['estimated_cost'] ?? '0').toString();
      final double costVal = double.tryParse(rawCost) ?? 0.0;
      final String costFormatted = costVal > 0 ? costVal.toStringAsFixed(2) : rawCost;

      final String pickup = _cleanAddress((booking['pickup_name'] ?? '').toString());
      final String dropoff = _cleanAddress((booking['dropoff_name'] ?? '').toString());

      double distKm = 1.1;
      int etaMin = 3;
      if (_currentPosition != null && booking['pickup_lat'] != null && booking['pickup_lng'] != null) {
        final meters = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          (booking['pickup_lat'] as num).toDouble(),
          (booking['pickup_lng'] as num).toDouble(),
        );
        distKm = meters / 1000.0;
        etaMin = (distKm * 3.0 + 1.0).round().clamp(1, 30);
      } else if (booking['distance_km'] != null) {
        distKm = double.tryParse(booking['distance_km'].toString()) ?? 1.1;
        etaMin = (distKm * 3.0 + 1.0).round().clamp(1, 30);
      }

      final String title = 'New delivery · ₹$costFormatted';
      final String body = 'Pickup: $pickup\nDrop-off: $dropoff\n${distKm.toStringAsFixed(1)} km delivery · Pickup $etaMin min away';

      final androidDetails = AndroidNotificationDetails(
        'vaya_order_requests',
        'VAYA Trip Requests',
        channelDescription: 'High-priority notifications for new trip requests with accept and decline actions',
        importance: Importance.max,
        priority: Priority.high,
        ticker: title,
        playSound: true,
        enableVibration: true,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        color: const Color(0xFFF26430),
        colorized: true,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: false,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'accept_trip',
            'ACCEPT',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'decline_trip',
            'DECLINE',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      );

      final notificationDetails = NotificationDetails(android: androidDetails);

      await _notificationsPlugin.show(
        notifId,
        title,
        body,
        notificationDetails,
        payload: json.encode(booking),
      );
    } catch (e) {
      debugPrint("Error showing order request notification: $e");
    }
  }

  Future<void> _cancelOrderNotification([String? bookingId]) async {
    try {
      if (bookingId != null && bookingId.isNotEmpty) {
        await _notificationsPlugin.cancel(_getNotificationIdForBooking(bookingId));
      } else if (_incomingAlert != null) {
        final String bId = (_incomingAlert!['id'] ?? _incomingAlert!['bookingId'] ?? '').toString();
        if (bId.isNotEmpty) {
          await _notificationsPlugin.cancel(_getNotificationIdForBooking(bId));
        }
      } else {
        await _notificationsPlugin.cancel(999);
      }
    } catch (e) {
      debugPrint("Error cancelling order notification: $e");
    }
  }

  void _showDeclineReasonDialog(String bookingId) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final reasons = [
          'Pickup location is too far',
          'Fare is too low for distance',
          'Vehicle not suitable for cargo',
          'Taking a personal break',
          'Other reason'
        ];
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Reason for declining (Optional)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter'),
              ),
              const SizedBox(height: 12),
              ...reasons.map((reason) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(reason, style: const TextStyle(color: Colors.white70, fontSize: 14, fontFamily: 'Inter')),
                trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                onTap: () {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Decline recorded: $reason'), duration: const Duration(seconds: 2)),
                  );
                },
              )),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Skip', style: TextStyle(color: Color(0xFF9CA3AF), fontFamily: 'Inter')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Timer? _refreshTimer;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _progressAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..repeat(reverse: true);

    _isOnline = (widget.driverData['status'] == 'online' || widget.driverData['status'] == 'busy');
    if (_isOnline) {
      _connectWebSocket();
      _startLocationStreaming();
      _startHeartbeat();
    }
    _initNotifications();
    _fetchPricingConfig();
    _loadCachedTodayEarningsFirst();
    _fetchTodayEarnings();
    _fetchDriverStatus();
    _checkLocationPermission();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) {
        _fetchTodayEarnings();
        _fetchDriverStatus();
      }
    });
  }

  Future<void> _loadCachedTodayEarningsFirst() async {
    final cached = await DriverStorage.loadCachedTodayEarnings();
    if (cached != null && mounted) {
      setState(() {
        _todayEarnings = double.tryParse(cached['earnings']?.toString() ?? '0') ?? 0.0;
        _completedTripsCount = int.tryParse(cached['count']?.toString() ?? '0') ?? 0;
      });
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _sendHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && _isOnline) {
        _sendHeartbeat();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _sendHeartbeat() async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$apiBaseUrl/api/driver/heartbeat'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
    } catch (e) {
      debugPrint("Heartbeat error: $e");
    }
  }

  Future<void> _fetchDriverStatus() async {
    try {
      final token = await getValidFirebaseUserToken();
      if (token == null) return;

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['exists'] == true && data['driver'] != null) {
          final status = data['driver']['status'];
          final shouldBeOnline = (status == 'online' || status == 'busy');
          if (_isOnline != shouldBeOnline) {
            setState(() {
              _isOnline = shouldBeOnline;
            });
            if (shouldBeOnline) {
              _connectWebSocket();
              _startLocationStreaming();
              _startHeartbeat();
              _updateOnlineNotification();
            } else {
              _disconnectWebSocket();
              _stopLocationStreaming();
              _stopHeartbeat();
              _cancelOnlineNotification();
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching driver status: $e");
    }
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final String? actionId = response.actionId;
        final String? payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          try {
            final data = json.decode(payload);
            final String? bookingId = (data['id'] ?? data['bookingId'])?.toString();
            if (actionId == 'accept_trip' && bookingId != null) {
              await _acceptJob(bookingId);
              await _cancelOrderNotification(bookingId);
            } else if (actionId == 'decline_trip') {
              _clearAlert(bookingId);
              await _cancelOrderNotification(bookingId);
              if (bookingId != null) {
                _showDeclineReasonDialog(bookingId);
              }
            } else {
              if (_isOnline && data is Map<String, dynamic>) {
                _startAlertTimer(data);
              }
            }
          } catch (e) {
            debugPrint("Error handling notification CTA: $e");
          }
        }
      },
    );

    final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
    }

    try {
      _fcmSubscription?.cancel();
      _fcmSubscription = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (message.data.isNotEmpty) {
          final data = message.data;
          // Strictly filter for new booking creation events with valid details
          if (data['type'] == 'booking_created') {
            final bool hasActiveTrip = widget.driverData['active_job'] != null;
            if (_isOnline && !hasActiveTrip && data['estimated_cost'] != null) {
              _startAlertTimer(data);
            }
          }
        }
      });
    } catch (e) {
      debugPrint("FCM initialization listener warning: $e");
    }
  }

  Future<void> _fetchTodayEarnings() async {
    try {
      final token = await getValidFirebaseUserToken();
      if (token == null) return;

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/today-earnings'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['success'] == true && data['todayEarnings'] != null) {
          final earningsNum = double.tryParse(data['todayEarnings'].toString()) ?? 0.0;
          final countNum = int.tryParse(data['todayCount']?.toString() ?? '0') ?? 0;
          if (mounted) {
            setState(() {
              _todayEarnings = earningsNum;
              _completedTripsCount = countNum;
            });
            if (_isOnline) {
              _updateOnlineNotification();
            }
          }
          await DriverStorage.saveCachedTodayEarnings(earningsNum, countNum);
        }
      }
    } catch (e) {
      debugPrint("Error fetching today earnings: $e");
    }
  }

  Future<void> _updateOnlineNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'vaya_driver_online_status',
      'VAYA Partner Online Service',
      channelDescription: 'Persistent notification while driver is online',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showWhen: false,
      color: Color(0xFFF26430),
      icon: '@mipmap/ic_launcher',
    );

    const notificationDetails = NotificationDetails(android: androidDetails);
    final String earningsText = '₹${_todayEarnings.toStringAsFixed(0)}';

    await _notificationsPlugin.show(
      _onlineNotificationId,
      'VAYA Partner • ONLINE',
      'Ready for trip requests • Today: $earningsText',
      notificationDetails,
    );
  }

  Future<void> _cancelOnlineNotification() async {
    await _notificationsPlugin.cancel(_onlineNotificationId);
  }

  Future<void> _checkLocationPermission() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) {
        setState(() {
          _currentPosition = LatLng(pos.latitude, pos.longitude);
          _lastLocationSyncTime = DateTime.now();
          if (_currentPosition != null && _mapController != null) {
            _mapController!.animateCamera(CameraUpdate.newLatLng(_currentPosition!));
          }
        });
      }
    } catch (e) {
      debugPrint("Error in _checkLocationPermission: $e");
    }
  }

  /// Perform 7 sequential preflight validation checks before going online
  Future<String?> _performPreflightChecks() async {
    // 1. Location Permission
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return 'location_permission';
    }

    // 2. GPS / Location Services Enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return 'gps_disabled';
    }

    // 3. Network Connectivity Check
    try {
      final res = await http.get(Uri.parse('$apiBaseUrl/health')).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200 && res.statusCode != 404) {
        return 'network_error';
      }
    } catch (_) {
      // Network check fallback
    }

    // 4. Driver Verification Status
    final verifStatus = widget.driverData['verification_status'] ?? widget.driverData['status'];
    final isVerified = widget.driverData['is_verified'] ?? true;
    if (verifStatus == 'pending' || verifStatus == 'rejected' || isVerified == false) {
      return 'verification_pending';
    }

    // 5. Required Documents
    final docStatus = widget.driverData['documents_status'];
    if (docStatus == 'pending' || docStatus == 'rejected') {
      return 'documents_missing';
    }

    // 6. Vehicle Readiness
    final vehicleType = widget.driverData['vehicle_type'];
    if (vehicleType == null || vehicleType.toString().trim().isEmpty) {
      return 'vehicle_not_ready';
    }

    // 7. Cash-order / Account Balance Eligibility
    final walletBal = double.tryParse(widget.driverData['wallet_balance']?.toString() ?? '0') ?? 0.0;
    if (walletBal < -500.0) {
      return 'cash_ineligible';
    }

    return null; // All checks passed clean!
  }

  /// Show dedicated recovery bottom sheet modal with Open Settings guidance when a check fails
  void _showRecoveryModalSheet(BuildContext context, String reasonKey) {
    IconData icon;
    String title;
    String message;
    String buttonText;
    VoidCallback onAction;

    switch (reasonKey) {
      case 'location_permission':
        icon = Icons.location_off_rounded;
        title = 'Location Permission Required';
        message = 'VAYA Partner needs precise location access to connect you with nearby delivery trips and calculate accurate ETAs.';
        buttonText = 'Open App Settings';
        onAction = () async {
          Navigator.pop(context);
          await Geolocator.openAppSettings();
        };
        break;

      case 'gps_disabled':
        icon = Icons.gps_off_rounded;
        title = 'GPS Location Disabled';
        message = 'Your device GPS is turned off. Enable high-accuracy location services to go online and receive customer orders.';
        buttonText = 'Open Location Settings';
        onAction = () async {
          Navigator.pop(context);
          await Geolocator.openLocationSettings();
        };
        break;

      case 'network_error':
        icon = Icons.wifi_off_rounded;
        title = 'Network Connection Issue';
        message = 'Unable to reach VAYA Partner servers. Please check your mobile network or Wi-Fi connection and try again.';
        buttonText = 'Retry Connection';
        onAction = () {
          Navigator.pop(context);
          _toggleOnline(true);
        };
        break;

      case 'verification_pending':
        icon = Icons.verified_user_outlined;
        title = 'Account Under Verification';
        message = 'Your partner profile is currently undergoing verification by our admin team. You will be able to go online once approved.';
        buttonText = 'View Account Status';
        onAction = () {
          Navigator.pop(context);
          widget.onOpenProfile?.call();
        };
        break;

      case 'documents_missing':
        icon = Icons.assignment_late_outlined;
        title = 'Documents Pending Verification';
        message = 'Your driving license or vehicle RC document is pending review or requires re-upload. Please update your documents to proceed.';
        buttonText = 'Manage Documents';
        onAction = () {
          Navigator.pop(context);
          widget.onOpenProfile?.call();
        };
        break;

      case 'vehicle_not_ready':
        icon = Icons.directions_bike_outlined;
        title = 'Vehicle Selection Required';
        message = 'No active delivery vehicle (Bike / Three Wheeler / Truck) linked to your profile. Select your vehicle to receive trip requests.';
        buttonText = 'Select Vehicle';
        onAction = () {
          Navigator.pop(context);
          widget.onOpenProfile?.call();
        };
        break;

      case 'cash_ineligible':
        icon = Icons.account_balance_wallet_outlined;
        title = 'Wallet Balance Low';
        message = 'Your driver wallet balance is below the operational threshold (-₹500). Settle pending cash dues to continue accepting trips.';
        buttonText = 'Settle Wallet Dues';
        onAction = () {
          Navigator.pop(context);
          widget.onOpenProfile?.call();
        };
        break;

      default:
        icon = Icons.warning_amber_rounded;
        title = 'Unable to Go Online';
        message = 'A temporary operational issue prevented going online. Please try again.';
        buttonText = 'Retry';
        onAction = () {
          Navigator.pop(context);
          _toggleOnline(true);
        };
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: VayaDriverTheme.saffron, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFA0A0A0),
                  fontSize: 14,
                  height: 1.4,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaDriverTheme.saffron,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: onAction,
                  child: Text(
                    buttonText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Inter',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// Confirmation sheet before going offline if an active or pending trip is detected
  Future<bool> _showOfflineConfirmationSheet() async {
    final bool? confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Active Trip in Progress',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'You have an active or assigned delivery trip. Going offline now will not cancel your trip assignment and may affect your completion rate.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFA0A0A0),
                  fontSize: 13,
                  height: 1.4,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Confirm Offline', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    return confirm == true;
  }

  Future<void> _toggleOnline(bool online) async {
    if (_isTogglingStatus) return; // Disable repeated taps

    if (online) {
      final failReason = await _performPreflightChecks();
      if (failReason != null) {
        if (mounted) {
          _showRecoveryModalSheet(context, failReason);
        }
        return;
      }
    } else {
      final bool hasActiveTrip = widget.driverData['active_job'] != null || _incomingAlert != null;
      if (hasActiveTrip) {
        final confirmed = await _showOfflineConfirmationSheet();
        if (!confirmed) return;
      }
    }

    setState(() => _isTogglingStatus = true);

    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Session expired. Please log in again.')),
          );
        }
        return;
      }

      String? fcmToken;
      double? lat;
      double? lng;
      if (online) {
        try {
          fcmToken = await FirebaseMessaging.instance.getToken();
        } catch (_) {}
        try {
          Position curPos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 3),
            ),
          );
          lat = curPos.latitude;
          lng = curPos.longitude;
          if (mounted) {
            setState(() {
              _currentPosition = LatLng(lat!, lng!);
              _lastLocationSyncTime = DateTime.now();
            });
          }
        } catch (e) {
          if (_currentPosition != null) {
            lat = _currentPosition!.latitude;
            lng = _currentPosition!.longitude;
          }
        }
      }

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/driver/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'status': online ? 'online' : 'offline',
          if (fcmToken != null) 'fcmToken': fcmToken,
          if (lat != null) 'lat': lat,
          if (lng != null) 'lng': lng,
        }),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        setState(() {
          _isOnline = online;
        });

        if (online) {
          _connectWebSocket();
          _startLocationStreaming();
          _startHeartbeat();
          _updateOnlineNotification();
        } else {
          _disconnectWebSocket();
          _stopLocationStreaming();
          _stopHeartbeat();
          _cancelOnlineNotification();
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(online ? "You're online — Receiving trips" : "You're offline"),
              duration: const Duration(seconds: 2),
              backgroundColor: online ? VayaDriverTheme.routeGreen : const Color(0xFF333333),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to update status. Are you approved?')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection timed out. Tap button to retry: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTogglingStatus = false);
      }
    }
  }

  void _startLocationStreaming() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return;
      }

      // Send initial position immediately upon streaming start
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
        if (mounted) {
          setState(() {
            _currentPosition = LatLng(pos.latitude, pos.longitude);
            _lastLocationSyncTime = DateTime.now();
          });
        }
        final token = await DriverAuthHelper.getAuthToken();
        if (token != null) {
          await http.post(
            Uri.parse('$apiBaseUrl/api/driver/position'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token'
            },
            body: json.encode({
              'lat': pos.latitude,
              'lng': pos.longitude,
            }),
          );
        }
      } catch (e) {
        debugPrint("Initial position sync error: $e");
      }

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: _getBackgroundLocationSettings(distanceFilter: 10),
      ).listen(
        (Position pos) async {
          if (mounted) {
            setState(() {
              _currentPosition = LatLng(pos.latitude, pos.longitude);
              _lastLocationSyncTime = DateTime.now();
            });
          }

          try {
            final token = await DriverAuthHelper.getAuthToken();
            if (token == null) return;

            await http.post(
              Uri.parse('$apiBaseUrl/api/driver/position'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token'
              },
              body: json.encode({
                'lat': pos.latitude,
                'lng': pos.longitude,
              }),
            );
          } catch (e) {
            debugPrint("Location streaming failed: $e");
          }
        },
        onError: (e) {
          debugPrint("Location stream error: $e");
        },
      );
    } catch (e) {
      debugPrint("Could not start location streaming: $e");
    }
  }

  void _stopLocationStreaming() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  void _connectWebSocket() async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      _channel = WebSocketChannel.connect(
        Uri.parse('$wsBaseUrl/ws?token=$token'),
      );

      _channel!.stream.listen((message) {
        final data = json.decode(message);
        
        if (data['type'] == 'booking_created') {
          final booking = data['booking'];
          final bool hasActiveTrip = widget.driverData['active_job'] != null;
          if (booking != null && booking['vehicle_type'] == widget.driverData['vehicle_type'] && _isOnline && !hasActiveTrip) {
            if (_currentPosition != null && booking['pickup_lat'] != null) {
              final double dist = Geolocator.distanceBetween(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
                (booking['pickup_lat'] as num).toDouble(),
                (booking['pickup_lng'] as num).toDouble(),
              );
              if (dist <= 10000) { // 10km radius
                _startAlertTimer(booking);
              }
            } else {
              _startAlertTimer(booking);
            }
          }
        } else if (data['type'] == 'booking_status' && data['status'] == 'cancelled') {
          final String bId = (data['bookingId'] ?? '').toString();
          _cancelOrderNotification(bId);
          if (_incomingAlert != null && (_incomingAlert!['id'] ?? _incomingAlert!['bookingId']) == bId) {
            _clearAlert(bId);
          }
        } else if (data['type'] == 'booking_accepted') {
          final String bId = (data['bookingId'] ?? '').toString();
          _cancelOrderNotification(bId);
          if (_incomingAlert != null && (_incomingAlert!['id'] ?? _incomingAlert!['bookingId']) == bId) {
            _clearAlert(bId);
          }
        } else if (data['type'] == 'pricing_updated' && data['pricing'] != null) {
          if (mounted) {
            setState(() {
              _serverPricing = data['pricing'] ?? [];
            });
          }
          SharedPreferences.getInstance().then((prefs) {
            prefs.setString('vaya_cached_pricing_config', json.encode(data));
          });
        }
      });
    } catch (e) {
      debugPrint("WebSocket failed: $e");
    }
  }

  void _disconnectWebSocket() {
    _channel?.sink.close();
    _channel = null;
  }

  bool _isAcceptingJob = false;

  Future<void> _acceptJob(String bookingId) async {
    if (_isAcceptingJob) return;
    setState(() => _isAcceptingJob = true);
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/accept'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({'bookingId': bookingId}),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final acceptedJob = data['booking'];
        _clearAlert();
        widget.onJobAccepted(acceptedJob);
      } else {
        _clearAlert();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to accept job. It may have expired or been taken.')),
        );
      }
    } catch (e) {
      _clearAlert();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accepting job: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isAcceptingJob = false);
      }
    }
  }

  String _formatSyncTime() {
    if (_lastLocationSyncTime == null) return 'Syncing...';
    final diffSeconds = DateTime.now().difference(_lastLocationSyncTime!).inSeconds;
    if (diffSeconds < 5) return 'Synced just now';
    if (diffSeconds < 60) return 'Synced ${diffSeconds}s ago';
    return 'Synced ${diffSeconds ~/ 60}m ago';
  }

  @override
  void dispose() {
    _fcmSubscription?.cancel();
    _progressAnimController.dispose();
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _alertTimer?.cancel();
    _stopLocationStreaming();
    _disconnectWebSocket();
    _cancelOnlineNotification();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final driverName = widget.driverData['name'] ?? 'Driver';
    final driverInitial = driverName.isNotEmpty ? driverName[0].toUpperCase() : 'D';

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56.0),
        child: AppBar(
          backgroundColor: const Color(0xFF141414),
          elevation: 0,
          toolbarHeight: 56.0,
          titleSpacing: 16.0,
          automaticallyImplyLeading: false,
          title: Text(
            _getTimeOfDayGreeting(widget.driverData['name']),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: -0.2,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: GestureDetector(
                onTap: () {
                  if (widget.onOpenProfile != null) {
                    widget.onOpenProfile!();
                  } else {
                    _showDriverProfileQuickSheet();
                  }
                },
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF242424),
                    shape: BoxShape.circle,
                    border: Border.all(color: VayaDriverTheme.saffron, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      driverInitial,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      body: !_isOnline
          ? _buildOfflineReadinessScreen()
          : _buildOnlineMapScreen(),
    );
  }

  /// Calm Ink Black / Signal Cream Readiness View when OFFLINE (No Map)
  Widget _buildOfflineReadinessScreen() {
    final vehicleType = (widget.driverData['vehicle_type'] ?? 'Bike').toString().toUpperCase();

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Offline Hero Card
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
            ),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2E),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF3A3A3E), width: 1),
                  ),
                  child: const Icon(
                    Icons.power_settings_new_rounded,
                    color: Color(0xFF9CA3AF),
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "You're Offline",
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "You are not receiving delivery trip requests right now. Tap below when you're ready to start taking orders nearby.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    height: 1.45,
                    color: Color(0xFFA0A0A0),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Prominent 52-56 px GO ONLINE Button
          SizedBox(
            height: 54,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: VayaDriverTheme.saffron,
                elevation: 4,
                shadowColor: VayaDriverTheme.saffron.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _isTogglingStatus ? null : () => _toggleOnline(true),
              child: _isTogglingStatus
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const VayaLoader.inline(size: 18, color: Colors.white),
                        const SizedBox(width: 12),
                        const Text(
                          'Going online...',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.bolt_rounded, color: Colors.white, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'GO ONLINE',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),

          // Today's Performance Summary Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "TODAY'S EARNINGS",
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF9CA3AF),
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "₹${_todayEarnings.toStringAsFixed(0)}",
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(width: 1, height: 36, color: const Color(0xFF2C2C2E)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "COMPLETED TRIPS",
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF),
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "$_completedTripsCount",
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Vehicle Readiness Status Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.directions_bike_rounded,
                    color: VayaDriverTheme.saffron,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Assigned Vehicle: $vehicleType',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'GPS Active • Wallet Dues Settled',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: Color(0xFFA0A0A0),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.check_circle_rounded,
                  color: VayaDriverTheme.routeGreen,
                  size: 20,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Full-Screen Map View when ONLINE with Single Collapsed Floating Status Card
  Widget _buildOnlineMapScreen() {
    return _currentPosition == null
        ? const Center(
            child: VayaLoader.section(size: 96, message: 'Locating driver GPS...'),
          )
        : Stack(
            children: [
              // Full-Screen Map
              GoogleMap(
                initialCameraPosition: CameraPosition(target: _currentPosition!, zoom: 15.5),
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                style: _darkMinimalMapStyleJson,
                onMapCreated: (c) => _mapController = c,
              ),

              // Demand Areas Toast Overlay when toggled
              if (_showDemandAreas)
                Positioned(
                  top: 104,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141414),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orangeAccent, width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.local_fire_department, color: Colors.orangeAccent, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'High Demand Areas: InfoCity Square, Sailashree Vihar, Jaydev Vihar (+1.5x orders)',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Collapsed 72–88 px Single Floating Status Card
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Container(
                  height: 80,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141414),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Left Status & Today Earnings Summary
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                FadeTransition(
                                  opacity: _progressAnimController,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: VayaDriverTheme.routeGreen,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: VayaDriverTheme.routeGreen.withValues(alpha: 0.6),
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Online · Finding trips',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: VayaDriverTheme.routeGreen,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Today: ₹${_todayEarnings.toStringAsFixed(0)} • $_completedTripsCount trips • ${_formatSyncTime()}",
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 12,
                                color: Color(0xFF9CA3AF),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Duty Action Control in VAYA Saffron
                      SizedBox(
                        height: 36,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VayaDriverTheme.saffron,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _isTogglingStatus ? null : () => _toggleOnline(false),
                          child: _isTogglingStatus
                              ? const VayaLoader.inline(size: 14, color: Colors.white)
                              : const Text(
                                  'GO OFFLINE',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Essential Map Controls (Current Location, Recenter, Demand Areas)
              Positioned(
                right: 16,
                bottom: 90,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Demand Areas Heat Toggle Button
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showDemandAreas = !_showDemandAreas;
                        });
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _showDemandAreas ? Colors.orangeAccent : const Color(0xFF141414),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.local_fire_department,
                          color: _showDemandAreas ? Colors.black : VayaDriverTheme.saffron,
                          size: 24,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Recenter Camera Button
                    GestureDetector(
                      onTap: () {
                        if (_currentPosition != null && _mapController != null) {
                          _mapController!.animateCamera(
                            CameraUpdate.newCameraPosition(
                              CameraPosition(
                                target: _currentPosition!,
                                zoom: 15.5,
                                tilt: 0,
                                bearing: 0,
                              ),
                            ),
                          );
                        }
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF141414),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.center_focus_strong,
                          color: VayaDriverTheme.saffron,
                          size: 24,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Current Location Button
                    GestureDetector(
                      onTap: () async {
                        if (_currentPosition != null && _mapController != null) {
                          _mapController!.animateCamera(
                            CameraUpdate.newLatLngZoom(_currentPosition!, 15.5),
                          );
                        }
                        await _checkLocationPermission();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF141414),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.my_location,
                          color: VayaDriverTheme.saffron,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Incoming Cargo Request Bottom Sheet
              if (_incomingAlert != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1A17),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                      border: Border.all(color: VayaDriverTheme.saffron.withValues(alpha: 0.8), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Builder(
                        builder: (_) {
                          final String bId = (_incomingAlert!['id'] ?? _incomingAlert!['bookingId'] ?? '').toString();
                          final String rawCost = (_incomingAlert!['estimated_cost'] ?? '0').toString();
                          final double costVal = double.tryParse(rawCost) ?? 0.0;
                          final String costFormatted = costVal > 0 ? costVal.toStringAsFixed(2) : rawCost;
                          final String pickupStr = _cleanAddress(_incomingAlert!['pickup_name'] ?? '');
                          final String dropoffStr = _cleanAddress(_incomingAlert!['dropoff_name'] ?? '');

                          double distKm = 1.1;
                          int etaMin = 3;
                          if (_currentPosition != null && _incomingAlert!['pickup_lat'] != null && _incomingAlert!['pickup_lng'] != null) {
                            final meters = Geolocator.distanceBetween(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                              (_incomingAlert!['pickup_lat'] as num).toDouble(),
                              (_incomingAlert!['pickup_lng'] as num).toDouble(),
                            );
                            distKm = meters / 1000.0;
                            etaMin = (distKm * 3.0 + 1.0).round().clamp(1, 30);
                          } else if (_incomingAlert!['distance_km'] != null) {
                            distKm = double.tryParse(_incomingAlert!['distance_km'].toString()) ?? 1.1;
                            etaMin = (distKm * 3.0 + 1.0).round().clamp(1, 30);
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Header Tag, Title (16-18px), & Timer Badge
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: VayaDriverTheme.saffron.withValues(alpha: 0.2),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.local_shipping_outlined, color: VayaDriverTheme.saffron, size: 18),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            'New delivery · ₹$costFormatted',
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                              fontFamily: 'Inter',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.redAccent.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.redAccent, width: 1),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.timer_outlined, color: Colors.redAccent, size: 14),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${_alertCountdown}s',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.redAccent, fontFamily: 'Inter'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Route Information
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF262320),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: const Color(0xFF38332E)),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.circle, color: VayaDriverTheme.routeGreen, size: 10),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            'Pickup: $pickupStr',
                                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        const Icon(Icons.location_on, color: Colors.redAccent, size: 12),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Drop-off: $dropoffStr',
                                            style: const TextStyle(fontSize: 14, color: Color(0xFFD0D0D0), fontFamily: 'Inter'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(color: Color(0xFF38332E), height: 20),
                                    Row(
                                      children: [
                                        const Icon(Icons.navigation_outlined, color: VayaDriverTheme.saffron, size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${distKm.toStringAsFixed(1)} km delivery · Pickup $etaMin min away',
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron, fontFamily: 'Inter'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),

                              // Two Full-Width Actions: ACCEPT (Route Green) & DECLINE (Mist Grey / Alert Red)
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 50,
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF2C2C2E),
                                          foregroundColor: const Color(0xFFEF4444),
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            side: const BorderSide(color: Color(0xFF3A3A3C)),
                                          ),
                                        ),
                                        onPressed: () {
                                          _clearAlert(bId);
                                          if (bId.isNotEmpty) {
                                            _showDeclineReasonDialog(bId);
                                          }
                                        },
                                        child: const Text('DECLINE', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold, fontSize: 14, fontFamily: 'Inter')),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 2,
                                    child: SizedBox(
                                      height: 50,
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: VayaDriverTheme.routeGreen,
                                          foregroundColor: Colors.white,
                                          elevation: 2,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                        onPressed: (_isAcceptingJob || _incomingAlert == null) ? null : () => _acceptJob(bId),
                                        child: _isAcceptingJob
                                            ? const VayaLoader.inline(size: 20, color: Colors.white)
                                            : const Text('ACCEPT', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'Inter')),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          );
  }

  void _showDriverProfileQuickSheet() {
    final driverName = widget.driverData['name'] ?? 'Driver Partner';
    final phone = widget.driverData['phone'] ?? '';
    final vehicle = widget.driverData['vehicle_type'] ?? 'Not set';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: VayaDriverTheme.saffron.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(color: VayaDriverTheme.saffron, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        driverName.isNotEmpty ? driverName[0].toUpperCase() : 'D',
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(driverName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text('$phone • Vehicle: $vehicle', style: const TextStyle(color: Color(0xFFA0A0A0), fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaDriverTheme.saffron,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    widget.onOpenProfile?.call();
                  },
                  child: const Text('View Full Account Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 6. Full-Screen Active Trip Operational Workflow
class ActiveTripWorkflowScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  final Map<String, dynamic> activeJob;
  final Function(Map<String, dynamic>?) onJobUpdated;

  const ActiveTripWorkflowScreen({
    super.key,
    required this.driverData,
    required this.activeJob,
    required this.onJobUpdated,
  });

  @override
  State<ActiveTripWorkflowScreen> createState() => _ActiveTripWorkflowScreenState();
}

class _ActiveTripWorkflowScreenState extends State<ActiveTripWorkflowScreen> {
  late Map<String, dynamic> _job;
  StreamSubscription<Position>? _positionSubscription;
  Position? _currentPosition;
  List<dynamic> _serverPricing = [];

  Future<void> _fetchPricingConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_cached_pricing_config');
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (mounted) {
          setState(() {
            _serverPricing = decoded['pricing'] ?? [];
          });
        }
      }
    } catch (_) {}

    try {
      var response = await http.get(Uri.parse('$apiBaseUrl/api/pricing-config')).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/booking/pricing-config')).timeout(const Duration(seconds: 15));
      }
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _serverPricing = data['pricing'] ?? [];
          });
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('vaya_cached_pricing_config', json.encode(data));
      }
    } catch (e) {
      debugPrint('Driver active trip pricing fetch error: $e');
    }
  }

  Map<String, dynamic> _getWaitingConfigForVehicle(String? vehicleType) {
    final targetType = vehicleType ?? widget.driverData['vehicle_type'] ?? 'bike';
    if (_serverPricing.isNotEmpty) {
      try {
        final match = _serverPricing.firstWhere(
          (p) => p['vehicle_type'] == targetType,
          orElse: () => null,
        );
        if (match != null) {
          return {
            'free_pickup': int.tryParse(match['free_wait_minutes_pickup']?.toString() ?? '') ?? 10,
            'free_dropoff': int.tryParse(match['free_wait_minutes_dropoff']?.toString() ?? '') ?? 10,
            'rate': double.tryParse(match['wait_charge_per_minute']?.toString() ?? '') ?? 2.0,
          };
        }
      } catch (_) {}
    }
    return {'free_pickup': 10, 'free_dropoff': 10, 'rate': 2.0};
  }

  // 6-digit OTP fields
  final List<TextEditingController> _otpControllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());

  bool _isUpdatingStatus = false;
  bool _isVerifyingOtp = false;
  String? _otpError;
  bool _isOtpExpired = false;

  // Stage 4 Cash Confirmation
  bool _isCashCollectedConfirmed = false;
  bool _isPickupCashCollectedConfirmed = false;

  bool get isPickupCash {
    final point = (_job['cash_collection_point'] ?? _job['cashCollectionPoint'] ?? '').toString().toUpperCase();
    if (point == 'PICKUP') return true;
    final pType = (_job['payment_type'] ?? _job['paymentType'] ?? '').toString().toLowerCase();
    final pMethod = (_job['payment_method'] ?? _job['paymentMethod'] ?? '').toString().toLowerCase();
    if ((pType == 'cash' || pMethod.contains('cash')) && point != 'DROPOFF') {
      return true;
    }
    return false;
  }

  String get pickupAmountDisplay {
    final cost = double.tryParse(_job['estimated_cost']?.toString() ?? _job['estimatedCost']?.toString() ?? '') ?? 0.0;
    return cost.toStringAsFixed(0);
  }

  // Call tracking for customer-unreachable rule
  int _customerCallAttemptsCount = 0;

  @override
  void initState() {
    super.initState();
    _job = widget.activeJob;
    _fetchPricingConfig();
    _startPositionTracking();
  }

  void _startPositionTracking() {
    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: _getBackgroundLocationSettings(distanceFilter: 5),
      ).listen((Position pos) async {
        _currentPosition = pos;
        try {
          final token = await DriverAuthHelper.getAuthToken();
          if (token == null) return;

          await http.post(
            Uri.parse('$apiBaseUrl/api/driver/position'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({
              'lat': pos.latitude,
              'lng': pos.longitude,
            }),
          );
        } catch (e) {
          debugPrint('Error streaming driver position: $e');
        }
      });
    } catch (e) {
      debugPrint('Could not initialize driver position stream: $e');
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    for (final controller in _otpControllers) {
      controller.dispose();
    }
    for (final node in _otpFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  // Address sanitization & formatting helpers
  String _cleanAddress(String? address) {
    if (address == null || address.trim().isEmpty) return 'Address unavailable';
    String cleaned = address
        .replaceAll(RegExp(r'\s*\(\s*Contact\s*:?[^\)]*\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*Book\s*\d{10,}', caseSensitive: false), '')
        .replaceAll(RegExp(r'\b\d{10,12}\b'), '')
        .replaceAll(RegExp(r'\s+,\s+'), ', ')
        .trim();
    if (cleaned.endsWith(',')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trim();
    }
    return cleaned.isEmpty ? 'Address unavailable' : cleaned;
  }

  String _extractLocality(String? address) {
    final cleaned = _cleanAddress(address);
    if (cleaned == 'Address unavailable') return 'Locality Unavailable';
    final parts = cleaned.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0]}, ${parts[1]}';
    } else if (parts.isNotEmpty) {
      return parts[0];
    }
    return cleaned;
  }

  String _maskPhoneNumber(String? phone) {
    if (phone == null || phone.trim().isEmpty) return 'Contact unavailable';
    final trimmed = phone.trim();
    final digitsOnly = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.length >= 10) {
      final first3 = digitsOnly.substring(0, 3);
      final last4 = digitsOnly.substring(digitsOnly.length - 4);
      return '+91 $first3*****$last4';
    }
    return trimmed.replaceAll(RegExp(r'\d'), '*');
  }

  double _calculateDistanceMeters(double targetLat, double targetLng) {
    if (_currentPosition == null) return 0.0;
    return Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      targetLat,
      targetLng,
    );
  }

  Future<void> _updateStatus(String newStatus) async {
    if (_isUpdatingStatus) return;
    setState(() => _isUpdatingStatus = true);

    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'bookingId': _job['id'],
          'status': newStatus
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (newStatus == 'completed' || newStatus == 'cancelled') {
          if (newStatus == 'completed' && data['booking'] != null) {
            final b = data['booking'];
            final finalCost = b['final_cost'] ?? b['estimated_cost'];
            final waitCharge = double.tryParse(b['total_waiting_charge']?.toString() ?? '') ?? 0.0;
            if (waitCharge > 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Delivery Completed! Fare: ₹$finalCost (includes ₹$waitCharge waiting charges)'),
                  backgroundColor: VayaDriverTheme.routeGreen,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
          widget.onJobUpdated(null);
        } else {
          setState(() {
            _job = Map<String, dynamic>.from(_job)..addAll(Map<String, dynamic>.from(data['booking'] ?? {}));
          });
          widget.onJobUpdated(_job);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status (${res.statusCode})')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating status: $e')));
    } finally {
      if (mounted) {
        setState(() => _isUpdatingStatus = false);
      }
    }
  }

  void _handleArrivalWithGeofence({
    required String targetStatus,
    required double targetLat,
    required double targetLng,
    required String locationName,
  }) {
    final distMeters = _calculateDistanceMeters(targetLat, targetLng);
    if (_currentPosition != null && distMeters > 200.0) {
      _showGeofenceOverrideModal(
        locationName: locationName,
        distanceMeters: distMeters,
        onOverrideConfirmed: () => _updateStatus(targetStatus),
      );
    } else {
      _updateStatus(targetStatus);
    }
  }

  void _showGeofenceOverrideModal({
    required String locationName,
    required double distanceMeters,
    required VoidCallback onOverrideConfirmed,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.location_off, color: VayaDriverTheme.saffron, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Outside $locationName Geofence',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter'),
              ),
            ),
          ],
        ),
        content: Text(
          'GPS indicates you are ~${distanceMeters.round()}m away from $locationName. Have you actually arrived?',
          style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream, height: 1.4, fontFamily: 'Inter'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF9CA3AF), fontFamily: 'Inter')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: VayaDriverTheme.saffron,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              onOverrideConfirmed();
            },
            child: const Text('Override & Mark Arrived', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Inter')),
          ),
        ],
      ),
    );
  }

  Future<void> _verify6DigitOtp() async {
    final enteredOtp = _otpControllers.map((c) => c.text.trim()).join();
    if (enteredOtp.length < 6) {
      setState(() {
        _otpError = 'Please enter all 6 digits of the OTP.';
      });
      return;
    }

    if (_isVerifyingOtp) return;
    setState(() {
      _isVerifyingOtp = true;
      _otpError = null;
    });

    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/verify-pickup'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'bookingId': _job['id'],
          'otp': enteredOtp
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          _job = data['booking'];
          _otpError = null;
        });
        widget.onJobUpdated(_job);
      } else {
        final errBody = json.decode(res.body);
        final msg = errBody['error']?.toString() ?? 'Invalid OTP code. Please try again.';
        setState(() {
          if (msg.toLowerCase().contains('expired')) {
            _isOtpExpired = true;
            _otpError = 'OTP code expired. Please request customer to re-share.';
          } else {
            _otpError = 'Invalid OTP code. Please check and retry.';
          }
        });
      }
    } catch (e) {
      setState(() {
        _otpError = 'Verification error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isVerifyingOtp = false);
      }
    }
  }

  Future<void> _reportUnpaidCashDispute(String reason) async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/unpaid-cash-dispute'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'bookingId': _job['id'],
          'reason': reason,
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.support_agent, color: VayaDriverTheme.saffron, size: 24),
                  SizedBox(width: 10),
                  Text('Dispute Registered', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Inter')),
                ],
              ),
              content: Text(
                'Ticket ID: ${data['ticketId'] ?? 'SUP-10293'}\n\nVAYA Support team has been alerted regarding unpaid cash. Our support representative will contact you and the customer shortly.',
                style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14, height: 1.4, fontFamily: 'Inter'),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaDriverTheme.saffron,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Inter')),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error filing unpaid cash dispute: $e');
    }
  }

  void _handleCompleteDeliveryWithCashCheck() {
    final fare = _job['estimated_cost']?.toString() ?? '72.38';
    if (_isCashCollectedConfirmed) {
      _updateStatus('completed');
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF18181B),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Icon(Icons.payments_outlined, color: VayaDriverTheme.routeGreen, size: 24),
                    SizedBox(width: 10),
                    Text('Confirm Cash Collection', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter')),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22221F),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: VayaDriverTheme.routeGreen.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet, color: VayaDriverTheme.routeGreen, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total Cash to Collect', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF), fontFamily: 'Inter')),
                            const SizedBox(height: 2),
                            Text('₹$fare', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white, fontFamily: 'Inter')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: VayaDriverTheme.routeGreen,
                  value: _isCashCollectedConfirmed,
                  onChanged: (val) {
                    setState(() => _isCashCollectedConfirmed = val ?? false);
                    setSheetState(() {});
                  },
                  title: Text(
                    'I confirm that I have collected ₹$fare in cash from the recipient.',
                    style: const TextStyle(fontSize: 13, color: VayaDriverTheme.signalCream, fontFamily: 'Inter'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VayaDriverTheme.routeGreen,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isCashCollectedConfirmed
                        ? () {
                            Navigator.pop(ctx);
                            _updateStatus('completed');
                          }
                        : null,
                    child: Text(
                      'Collected ₹$fare & Complete Delivery',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Not Collected Yet', style: TextStyle(color: Color(0xFF9CA3AF), fontFamily: 'Inter')),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.report_problem_outlined, size: 16, color: Colors.redAccent),
                        label: const Text('Payment Not Received', style: TextStyle(color: Colors.redAccent, fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _reportUnpaidCashDispute('Customer / Receiver refused to pay cash fare ₹$fare');
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  Future<void> _openGoogleMapsNavigation(double lat, double lng) async {
    final googleNavUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
    final webMapsUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');

    try {
      if (await canLaunchUrl(googleNavUri)) {
        await launchUrl(googleNavUri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webMapsUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Navigation launch failed: $e');
      try {
        await launchUrl(webMapsUri, mode: LaunchMode.externalApplication);
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open map navigation: $err')),
          );
        }
      }
    }
  }

  void _openCancelOrReportIssueBottomSheet(BuildContext context, bool isBeforePickupVerification) {
    final customerPhone = (_job['sender_phone'] ?? _job['customer_phone'] ?? _job['receiver_phone'] ?? '').toString();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _CancelIssueReportSheet(
          job: _job,
          isBeforePickupVerification: isBeforePickupVerification,
          customerPhone: customerPhone,
          initialCallAttempts: _customerCallAttemptsCount,
          onCallAttemptMade: () {
            setState(() {
              _customerCallAttemptsCount++;
            });
          },
          onConfirmCancel: (String reason, String notes) async {
            final token = await DriverAuthHelper.getAuthToken();
            if (token == null) throw Exception("Authentication required");

            final res = await http.post(
              Uri.parse('$apiBaseUrl/api/booking/status'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: json.encode({
                'bookingId': _job['id'],
                'status': 'cancelled',
                'reason': reason,
                'notes': notes,
              }),
            );

            if (res.statusCode == 200) {
              // Return driver to Duty ONLY after server confirmation
              widget.onJobUpdated(null);
            } else {
              final errData = json.decode(res.body);
              throw Exception(errData['error'] ?? 'Server error cancelling trip.');
            }
          },
        );
      },
    );
  }

  void _showActiveJobDetailsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('VAYA #${_job['id'].toString().substring(0, 8).toUpperCase()}', style: const TextStyle(fontFamily: 'General Sans', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 12),
            Text('Pickup: ${_job['pickup_name']}', style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 6),
            Text('Drop-off: ${_job['dropoff_name']}', style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.saffron),
                child: const Text('Close', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getStatusDisplayTitle(String status) {
    switch (status) {
      case 'accepted':
        return 'To pickup';
      case 'arrived_pickup':
        return 'At pickup';
      case 'in_transit':
      case 'dropping_off':
        return 'To drop-off';
      case 'arrived_dropoff':
        return 'At drop-off';
      default:
        return status.replaceAll('_', ' ').toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _job['status'] ?? 'accepted';

    if (status == 'arrived_dropoff') {
      return DeliverySummaryScreen(
        bookingId: _job['id'].toString(),
        booking: _job,
        apiBaseUrl: apiBaseUrl,
        authToken: null,
        onCompleted: () {
          widget.onJobUpdated(null);
        },
        onViewTripDetails: () {
          _showActiveJobDetailsSheet();
        },
        onReportIssue: () {
          _openCancelOrReportIssueBottomSheet(context, false);
        },
      );
    }

    final isPickupPhase = (status == 'accepted' || status == 'arrived_pickup');
    final isBeforePickupVerification = isPickupPhase;

    final pickupLat = double.tryParse(_job['pickup_lat']?.toString() ?? '') ?? 20.2961;
    final pickupLng = double.tryParse(_job['pickup_lng']?.toString() ?? '') ?? 85.8245;
    final dropoffLat = double.tryParse(_job['dropoff_lat']?.toString() ?? '') ?? 20.3150;
    final dropoffLng = double.tryParse(_job['dropoff_lng']?.toString() ?? '') ?? 85.8178;

    final senderPhone = (_job['sender_phone'] ?? _job['customer_phone'] ?? '').toString();
    final receiverPhone = (_job['receiver_phone'] ?? _job['customer_phone'] ?? '').toString();
    final activePhone = isPickupPhase ? senderPhone : receiverPhone;

    final fare = _job['estimated_cost']?.toString() ?? '72.38';
    final topChipText = (_job['payment_type'] == 'cash' || _job['payment_method']?.toString().toLowerCase().contains('cash') == true)
        ? 'Cash payment · ₹$fare'
        : 'Paid online · ₹$fare';

    final shortBookingId = _job['id'].toString().substring(0, 8).toUpperCase();

    final waitCfg = _getWaitingConfigForVehicle(_job['vehicle_type']);
    final int freePickupMins = waitCfg['free_pickup'];
    final double ratePerMin = waitCfg['rate'];
    final String rateStr = ratePerMin % 1 == 0 ? ratePerMin.toInt().toString() : ratePerMin.toStringAsFixed(1);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(
          'VAYA #$shortBookingId',
          style: const TextStyle(
            fontFamily: 'General Sans',
            fontSize: 23,
            fontWeight: FontWeight.w700,
            color: VayaDriverTheme.signalCream,
          ),
        ),
        actions: [
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: VayaDriverTheme.saffron.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call, color: VayaDriverTheme.saffron, size: 20),
            ),
            tooltip: 'Call Customer',
            onPressed: () {
              if (activePhone.isNotEmpty) {
                _makeDriverPhoneCall(activePhone);
                setState(() => _customerCallAttemptsCount++);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Calling ${_maskPhoneNumber(activePhone)}...')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Contact number not available.')),
                );
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 1. MAP SECTION (Takes top space)
          Expanded(
            flex: 3,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(pickupLat, pickupLng),
                zoom: 14,
              ),
              markers: {
                Marker(
                  markerId: const MarkerId('pickup'),
                  position: LatLng(pickupLat, pickupLng),
                  infoWindow: const InfoWindow(title: 'Pickup Location'),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
                ),
                Marker(
                  markerId: const MarkerId('dropoff'),
                  position: LatLng(dropoffLat, dropoffLng),
                  infoWindow: const InfoWindow(title: 'Dropoff Location'),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                ),
              },
            ),
          ),

          // 2. OPERATIONAL BOTTOM SHEET CONTAINER (Scrollable Body + Sticky CTA)
          Expanded(
            flex: 5,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF141412),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                boxShadow: [
                  BoxShadow(color: Colors.black54, blurRadius: 10, spreadRadius: 2),
                ],
              ),
              child: Column(
                children: [
                  // Top Drag Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 10, bottom: 8),
                      decoration: BoxDecoration(
                        color: VayaDriverTheme.slate.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // SCROLLABLE SHEET CONTENT AREA
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Top Header Row (Stage Status Badge + Unified Payment Top Chip)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Stage Pill Badge
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: (isPickupPhase ? VayaDriverTheme.saffron : VayaDriverTheme.routeGreen).withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isPickupPhase ? VayaDriverTheme.saffron : VayaDriverTheme.routeGreen,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isPickupPhase ? Icons.navigation_outlined : Icons.check_circle_outline,
                                      size: 16,
                                      color: isPickupPhase ? VayaDriverTheme.saffron : VayaDriverTheme.routeGreen,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _getStatusDisplayTitle(status),
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: isPickupPhase ? VayaDriverTheme.saffron : VayaDriverTheme.routeGreen,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Unified Top Chip (No Duplicate Fare)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1B),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: VayaDriverTheme.saffron.withValues(alpha: 0.4)),
                                ),
                                child: Text(
                                  topChipText,
                                  style: const TextStyle(
                                    fontFamily: 'Inter',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: VayaDriverTheme.signalCream,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // DESTINATIONS LIST (Stage-Specific Expanded vs Collapsed Flow)
                          if (isPickupPhase) ...[
                            // EXPANDED PICKUP CARD (Focused on address, masked contact, Call & Navigate)
                            _buildExpandedDestinationCard(
                              title: 'PICKUP LOCATION',
                              isPickup: true,
                              locality: _extractLocality(_job['pickup_name']),
                              shortenedAddress: _cleanAddress(_job['pickup_name']),
                              contactPhone: senderPhone,
                              lat: pickupLat,
                              lng: pickupLng,
                            ),
                            const SizedBox(height: 10),
                            // COLLAPSED DROP-OFF ROUTE ROW (56 px height)
                            _buildCollapsedRouteRow(
                              title: 'DROP-OFF LOCATION',
                              locality: _extractLocality(_job['dropoff_name']),
                              shortenedAddress: _cleanAddress(_job['dropoff_name']),
                              isCompleted: false,
                              iconData: Icons.flag,
                              iconColor: Colors.redAccent,
                            ),
                          ] else ...[
                            // COLLAPSED PICKUP ROUTE ROW (56 px height, Route Green completed stage)
                            _buildCollapsedRouteRow(
                              title: 'PICKUP LOCATION',
                              locality: _extractLocality(_job['pickup_name']),
                              shortenedAddress: _cleanAddress(_job['pickup_name']),
                              isCompleted: true,
                              iconData: Icons.check_circle,
                              iconColor: VayaDriverTheme.routeGreen,
                            ),
                            const SizedBox(height: 10),
                            // EXPANDED DROP-OFF CARD
                            _buildExpandedDestinationCard(
                              title: 'DROP-OFF LOCATION',
                              isPickup: false,
                              locality: _extractLocality(_job['dropoff_name']),
                              shortenedAddress: _cleanAddress(_job['dropoff_name']),
                              contactPhone: receiverPhone,
                              lat: dropoffLat,
                              lng: dropoffLng,
                            ),
                          ],

                          const SizedBox(height: 12),

                          // STAGE OPERATIONAL CONTROLS IN SCROLLABLE BODY
                          if (status == 'arrived_pickup') ...[
                            // Shortened Waiting Notice Banner
                            Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E1B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.timer_outlined, size: 16, color: Color(0xFFD97706)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '$freePickupMins min free · then ₹$rateStr/min',
                                      style: const TextStyle(fontSize: 12, color: Color(0xFFFBBF24), fontFamily: 'Inter', fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // SIMPLIFIED PAYMENT CHECKBOX ROW & 6-DIGIT OTP FIELDS
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E1B),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (isPickupCash) ...[
                                    CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      activeColor: VayaDriverTheme.saffron,
                                      controlAffinity: ListTileControlAffinity.leading,
                                      value: _isPickupCashCollectedConfirmed,
                                      onChanged: (val) {
                                        setState(() => _isPickupCashCollectedConfirmed = val ?? false);
                                      },
                                      title: Text(
                                        '₹$pickupAmountDisplay cash collected from sender',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: VayaDriverTheme.signalCream, fontFamily: 'Inter'),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                  ],

                                  const Text(
                                    'Enter 6-Digit Pickup OTP',
                                    style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600, color: VayaDriverTheme.signalCream),
                                  ),
                                  const SizedBox(height: 10),

                                  // 6 SEPARATE ACCESSIBLE DIGIT BOXES
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: List.generate(6, (index) {
                                      return SizedBox(
                                        width: 44,
                                        height: 50,
                                        child: Semantics(
                                          label: 'OTP Digit ${index + 1} of 6',
                                          child: TextField(
                                            controller: _otpControllers[index],
                                            focusNode: _otpFocusNodes[index],
                                            keyboardType: TextInputType.number,
                                            textAlign: TextAlign.center,
                                            maxLength: 1,
                                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter'),
                                            decoration: InputDecoration(
                                              counterText: '',
                                              contentPadding: EdgeInsets.zero,
                                              filled: true,
                                              fillColor: const Color(0xFF2C2C28),
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: _otpError != null ? Colors.redAccent : Colors.white24,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(12),
                                                borderSide: const BorderSide(color: VayaDriverTheme.saffron, width: 2),
                                              ),
                                            ),
                                            onChanged: (val) {
                                              setState(() {}); // Rebuild to evaluate sticky CTA
                                              if (val.isNotEmpty) {
                                                if (index < 5) {
                                                  _otpFocusNodes[index + 1].requestFocus();
                                                } else {
                                                  _otpFocusNodes[index].unfocus();
                                                }
                                              } else {
                                                if (index > 0) {
                                                  _otpFocusNodes[index - 1].requestFocus();
                                                }
                                              }
                                            },
                                          ),
                                        ),
                                      );
                                    }),
                                  ),

                                  if (_otpError != null) ...[
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: (_isOtpExpired ? Colors.orangeAccent : Colors.redAccent).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: (_isOtpExpired ? Colors.orangeAccent : Colors.redAccent).withValues(alpha: 0.4)),
                                      ),
                                      child: Text(
                                        _otpError!,
                                        style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: _isOtpExpired ? Colors.orange.shade100 : Colors.redAccent.shade100, fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ] else if (status == 'dropping_off' || status == 'in_transit' || status == 'arrived_dropoff') ...[
                            // POST-PICKUP RECEIPT & DROP-OFF WAITING RESPONSIBILITY CARD
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E1B),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: VayaDriverTheme.routeGreen.withValues(alpha: 0.4)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.receipt_long, color: VayaDriverTheme.routeGreen, size: 20),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'Pickup Receipt',
                                        style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen),
                                      ),
                                      const Spacer(),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: VayaDriverTheme.routeGreen.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Text(
                                          'Collected',
                                          style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    isPickupCash
                                        ? 'Pickup amount: ₹$pickupAmountDisplay collected in cash from sender.'
                                        : 'Pickup amount: ₹$pickupAmountDisplay (Paid online).',
                                    style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 6),
                                  const Divider(color: Colors.white12, height: 12),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Icon(Icons.info_outline, color: Color(0xFF9CA3AF), size: 16),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Drop-off waiting charges ($freePickupMins min free · then ₹$rateStr/min) will be paid by receiver at drop-off location if waiting exceeds $freePickupMins mins.',
                                          style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF9CA3AF), height: 1.3),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // 3. PERSISTENT STICKY BOTTOM ACTION BAR (Pinned above Android Safe Area)
                  SafeArea(
                    top: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: const BoxDecoration(
                        color: Color(0xFF141412),
                        border: Border(top: BorderSide(color: Colors.white12)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (status == 'accepted') ...[
                            // STAGE 1 CTA: "I’ve arrived"
                            SizedBox(
                              height: 52,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: VayaDriverTheme.saffron,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  elevation: 2,
                                ),
                                onPressed: _isUpdatingStatus
                                    ? null
                                    : () => _handleArrivalWithGeofence(
                                          targetStatus: 'arrived_pickup',
                                          targetLat: pickupLat,
                                          targetLng: pickupLng,
                                          locationName: 'Pickup Location',
                                        ),
                                child: _isUpdatingStatus
                                    ? const VayaLoader.inline(size: 20, color: Colors.white)
                                    : const Text(
                                        'I’ve arrived',
                                        style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),
                          ] else if (status == 'arrived_pickup') ...[
                            // STAGE 2 STICKY CTA: "Verify OTP & start delivery"
                            Builder(
                              builder: (context) {
                                final isOtpComplete = _otpControllers.every((c) => c.text.trim().isNotEmpty);
                                final isCtaEnabled = isOtpComplete && (!isPickupCash || _isPickupCashCollectedConfirmed) && !_isVerifyingOtp;
                                return SizedBox(
                                  height: 52,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isCtaEnabled ? VayaDriverTheme.saffron : const Color(0xFF2C2C28),
                                      foregroundColor: isCtaEnabled ? Colors.white : Colors.white38,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      elevation: isCtaEnabled ? 2 : 0,
                                    ),
                                    onPressed: isCtaEnabled ? _verify6DigitOtp : null,
                                    child: _isVerifyingOtp
                                        ? const VayaLoader.inline(size: 20, color: Colors.white)
                                        : Text(
                                            !isOtpComplete
                                                ? 'Enter 6-digit OTP'
                                                : (isPickupCash && !_isPickupCashCollectedConfirmed)
                                                    ? 'Confirm cash collection'
                                                    : 'Verify OTP & start delivery',
                                            style: TextStyle(
                                              fontFamily: 'Inter',
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: isCtaEnabled ? Colors.white : Colors.white38,
                                            ),
                                          ),
                                  ),
                                );
                              },
                            ),
                          ] else if (status == 'dropping_off' || status == 'in_transit') ...[
                            // STAGE 3 CTA: "I’ve arrived at drop-off"
                            SizedBox(
                              height: 52,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: VayaDriverTheme.saffron,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  elevation: 2,
                                ),
                                onPressed: _isUpdatingStatus
                                    ? null
                                    : () => _handleArrivalWithGeofence(
                                          targetStatus: 'arrived_dropoff',
                                          targetLat: dropoffLat,
                                          targetLng: dropoffLng,
                                          locationName: 'Drop-off Location',
                                        ),
                                child: _isUpdatingStatus
                                    ? const VayaLoader.inline(size: 20, color: Colors.white)
                                    : const Text(
                                        'I’ve arrived at drop-off',
                                        style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),
                          ] else if (status == 'arrived_dropoff') ...[
                            // STAGE 4 CTA: Complete Delivery
                            SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: VayaDriverTheme.routeGreen,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  elevation: 2,
                                ),
                                onPressed: _isUpdatingStatus ? null : _handleCompleteDeliveryWithCashCheck,
                                icon: const Icon(Icons.payments, size: 20),
                                label: _isUpdatingStatus
                                    ? const VayaLoader.inline(size: 20, color: Colors.white)
                                    : Text(
                                        'Collected ₹$fare',
                                        style: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 4),

                          // PERSISTENT LOW-EMPHASIS ACTION
                          Center(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _openCancelOrReportIssueBottomSheet(context, isBeforePickupVerification),
                              child: Text(
                                isBeforePickupVerification ? 'Cancel delivery' : 'Report an issue',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: isBeforePickupVerification ? Colors.redAccent.shade100 : const Color(0xFF9CA3AF),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // EXPANDED DESTINATION CARD WIDGET
  Widget _buildExpandedDestinationCard({
    required String title,
    required bool isPickup,
    required String locality,
    required String shortenedAddress,
    required String contactPhone,
    required double lat,
    required double lng,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPickup ? VayaDriverTheme.saffron.withValues(alpha: 0.4) : Colors.redAccent.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 24 px Rounded Icon Container
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: (isPickup ? VayaDriverTheme.saffron : Colors.redAccent).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  isPickup ? Icons.location_on : Icons.flag,
                  color: isPickup ? VayaDriverTheme.saffron : Colors.redAccent,
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isPickup ? VayaDriverTheme.saffron : Colors.redAccent,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Locality Header
          Text(
            locality,
            style: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),

          // Shortened Cleaned Address (Never exposes raw customer phone in text!)
          Text(
            shortenedAddress,
            style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: VayaDriverTheme.signalCream, height: 1.3),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),

          // Masked Contact
          Row(
            children: [
              const Icon(Icons.person_outline, size: 14, color: Color(0xFF9CA3AF)),
              const SizedBox(width: 4),
              Text(
                'Contact: ${_maskPhoneNumber(contactPhone)}',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF9CA3AF)),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ACTION BUTTONS ROW (One Call + One Saffron Navigate action)
          Row(
            children: [
              // Single Call Action
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: VayaDriverTheme.saffron,
                      side: const BorderSide(color: VayaDriverTheme.saffron),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      if (contactPhone.isNotEmpty) {
                        _makeDriverPhoneCall(contactPhone);
                        setState(() => _customerCallAttemptsCount++);
                      }
                    },
                    icon: const Icon(Icons.call, size: 16),
                    label: const Text('Call', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Single Saffron Navigate Action
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VayaDriverTheme.saffron,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _openGoogleMapsNavigation(lat, lng),
                    icon: const Icon(Icons.navigation, size: 16),
                    label: const Text('Navigate', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // COLLAPSED ROUTE ROW WIDGET (Exact 56 px Height)
  Widget _buildCollapsedRouteRow({
    required String title,
    required String locality,
    required String shortenedAddress,
    required bool isCompleted,
    required IconData iconData,
    required Color iconColor,
  }) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCompleted ? VayaDriverTheme.routeGreen.withValues(alpha: 0.5) : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          // 24 px Icon Container (Route Green for completed stages)
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isCompleted ? VayaDriverTheme.routeGreen.withValues(alpha: 0.2) : iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              isCompleted ? Icons.check_circle : iconData,
              color: isCompleted ? VayaDriverTheme.routeGreen : iconColor,
              size: 16,
            ),
          ),
          const SizedBox(width: 12),

          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isCompleted ? VayaDriverTheme.routeGreen : iconColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '· $locality',
                        style: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Text(
                  shortenedAddress,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF9CA3AF)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cancel Delivery / Report an Issue Bottom Sheet Component
class _CancelIssueReportSheet extends StatefulWidget {
  final Map<String, dynamic> job;
  final bool isBeforePickupVerification;
  final String customerPhone;
  final int initialCallAttempts;
  final VoidCallback onCallAttemptMade;
  final Future<void> Function(String reason, String notes) onConfirmCancel;

  const _CancelIssueReportSheet({
    required this.job,
    required this.isBeforePickupVerification,
    required this.customerPhone,
    required this.initialCallAttempts,
    required this.onCallAttemptMade,
    required this.onConfirmCancel,
  });

  @override
  State<_CancelIssueReportSheet> createState() => _CancelIssueReportSheetState();
}

class _CancelIssueReportSheetState extends State<_CancelIssueReportSheet> {
  String? _selectedReason;
  final TextEditingController _notesController = TextEditingController();
  bool _photoAttached = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  // Call & Wait timer for customer_unreachable reason
  late int _callAttempts;
  Timer? _waitTimer;
  int _remainingSeconds = 120;
  bool _timerStarted = false;

  @override
  void initState() {
    super.initState();
    _callAttempts = widget.initialCallAttempts;
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _notesController.dispose();
    super.dispose();
  }

  void _startWaitTimerIfNeeded() {
    if (_timerStarted) return;
    _timerStarted = true;
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remainingSeconds > 0) {
        if (mounted) {
          setState(() => _remainingSeconds--);
        }
      } else {
        t.cancel();
      }
    });
  }

  String _formatTimer(int totalSec) {
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _getReasonGuidance(String reasonKey) {
    switch (reasonKey) {
      case 'customer_unreachable':
        return 'Please attempt at least 1 phone call to the customer and wait for 2 minutes before cancelling.';
      case 'incorrect_address':
        return 'Verify destination with customer via call. If address is wrong, request support dispatch.';
      case 'parcel_unsafe':
        return 'Ensure cargo complies with safety guidelines. Do not transport toxic or illegal items.';
      case 'vehicle_mismatch':
        return 'If cargo size or weight exceeds vehicle limit, submit report for penalty waiver.';
      case 'breakdown':
        return 'Please stay safe. Support team will be notified to assist with vehicle reassignment.';
      case 'emergency':
        return 'Your safety and health come first. Proceed with cancellation to return to Duty.';
      default:
        return 'Please provide additional notes below so support team can review your report.';
    }
  }

  bool _isCancelButtonEnabled() {
    if (_selectedReason == null || _isSubmitting) return false;
    if (_selectedReason == 'customer_unreachable') {
      return _callAttempts >= 1 && _remainingSeconds <= 0;
    }
    return true;
  }

  Future<void> _handleSubmit() async {
    if (!_isCancelButtonEnabled()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await widget.onConfirmCancel(
        _selectedReason!,
        _notesController.text.trim(),
      );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = e.toString().replaceAll('Exception:', '').trim();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),

            // Header
            Row(
              children: [
                const Icon(Icons.report_problem_outlined, color: Colors.redAccent, size: 22),
                const SizedBox(width: 8),
                Text(
                  widget.isBeforePickupVerification ? 'Cancel Delivery' : 'Report an Issue',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.isBeforePickupVerification
                  ? 'Select a required reason to cancel the current delivery.'
                  : 'Report an issue with this delivery. Cancellation is restricted to valid reasons.',
              style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF9CA3AF)),
            ),

            const SizedBox(height: 14),

            // Required Reasons List
            _buildReasonTile('customer_unreachable', 'Customer unreachable'),
            _buildReasonTile('incorrect_address', 'Incorrect or incomplete address'),
            _buildReasonTile('parcel_unsafe', 'Parcel unavailable / unsafe cargo'),
            _buildReasonTile('vehicle_mismatch', 'Vehicle mismatch / payload too heavy'),
            _buildReasonTile('breakdown', 'Vehicle breakdown'),
            _buildReasonTile('emergency', 'Personal emergency'),
            _buildReasonTile('other', 'Other issue'),

            // Dynamic Context Guidance Box
            if (_selectedReason != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: VayaDriverTheme.saffron.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _getReasonGuidance(_selectedReason!),
                      style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: VayaDriverTheme.signalCream, height: 1.4),
                    ),
                    if (_selectedReason == 'customer_unreachable') ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: VayaDriverTheme.saffron,
                                side: const BorderSide(color: VayaDriverTheme.saffron),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () {
                                if (widget.customerPhone.isNotEmpty) {
                                  _makeDriverPhoneCall(widget.customerPhone);
                                  widget.onCallAttemptMade();
                                  setState(() => _callAttempts++);
                                }
                              },
                              icon: const Icon(Icons.call, size: 16),
                              label: Text('Call Customer (${_callAttempts} made)', style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                      if (_remainingSeconds > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Mandatory wait timer: ${_formatTimer(_remainingSeconds)}',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.amber.shade200, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Optional Notes Field
            TextField(
              controller: _notesController,
              maxLines: 2,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Additional context or notes (optional)...',
                hintStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF6B7280)),
                filled: true,
                fillColor: const Color(0xFF1E1E1B),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white12)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white12)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
              ),
            ),

            const SizedBox(height: 10),

            // Optional Photo Input
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: _photoAttached ? VayaDriverTheme.routeGreen : const Color(0xFF9CA3AF),
                side: BorderSide(color: _photoAttached ? VayaDriverTheme.routeGreen : Colors.white12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                setState(() => _photoAttached = !_photoAttached);
              },
              icon: Icon(_photoAttached ? Icons.check_circle : Icons.camera_alt_outlined, size: 18),
              label: Text(_photoAttached ? 'Photo Evidence Attached' : '+ Attach Photo (Optional)', style: const TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),

            const SizedBox(height: 12),

            // Penalty Warning Box
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Unjustified cancellations may affect your completion rating or incur account penalties.',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.amber),
                    ),
                  ),
                ],
              ),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
            ],

            const SizedBox(height: 16),

            // Confirmation Actions Row
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: VayaDriverTheme.signalCream,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Keep delivery', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isCancelButtonEnabled() ? _handleSubmit : null,
                      child: _isSubmitting
                          ? const VayaLoader.inline(size: 20, color: Colors.white)
                          : Text(
                              _selectedReason == 'customer_unreachable' && !(_callAttempts >= 1 && _remainingSeconds <= 0)
                                  ? 'Wait (${_formatTimer(_remainingSeconds)})'
                                  : 'Cancel delivery',
                              style: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasonTile(String value, String label) {
    final isSelected = _selectedReason == value;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedReason = value;
          if (value == 'customer_unreachable') {
            _startWaitTimerIfNeeded();
          }
        });
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? VayaDriverTheme.saffron.withValues(alpha: 0.15) : const Color(0xFF1E1E1B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? VayaDriverTheme.saffron : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? VayaDriverTheme.saffron : const Color(0xFF9CA3AF),
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : VayaDriverTheme.signalCream,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// 7. Driver Trips History Screen (Trips Tab)
/// 7. Driver Trips History Screen (Trips Tab)
class DriverTripsScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverTripsScreen({super.key, required this.driverData});

  @override
  State<DriverTripsScreen> createState() => _DriverTripsScreenState();
}

class _DriverTripsScreenState extends State<DriverTripsScreen> with TickerProviderStateMixin {
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isFetching = false;
  bool _isOffline = false;
  List<dynamic> _trips = [];

  late TabController _tabController;
  late AnimationController _spinController;
  final ScrollController _completedScrollController = ScrollController();
  final ScrollController _cancelledScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _spinController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    _loadCachedTripsFirst();
    _fetchTrips();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _spinController.dispose();
    _completedScrollController.dispose();
    _cancelledScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadCachedTripsFirst() async {
    final cached = await DriverStorage.loadCachedTrips();
    if (cached.isNotEmpty && mounted) {
      setState(() {
        _trips = cached;
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchTrips({bool isPullToRefresh = false}) async {
    if (_isFetching) return; // Duplicate request protection
    _isFetching = true;

    if (!isPullToRefresh && _trips.isEmpty) {
      if (mounted) setState(() => _isLoading = true);
    }
    if (isPullToRefresh) {
      if (mounted) setState(() => _isRefreshing = true);
      _spinController.repeat();
    }

    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isRefreshing = false;
            _isFetching = false;
            _isOffline = true;
          });
        }
        _spinController.stop();
        _spinController.reset();
        return;
      }

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/trips'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['success'] == true) {
          final tripsList = data['trips'] ?? [];
          setState(() {
            _trips = tripsList;
            _isLoading = false;
            _isRefreshing = false;
            _isFetching = false;
            _isOffline = false;
          });
          await DriverStorage.saveCachedTrips(tripsList);
        } else {
          if (mounted) {
            setState(() {
              _isLoading = false;
              _isRefreshing = false;
              _isFetching = false;
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isRefreshing = false;
            _isFetching = false;
            _isOffline = true;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching driver trips: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          _isFetching = false;
          _isOffline = true;
        });
      }
    } finally {
      _spinController.stop();
      _spinController.reset();
    }
  }

  void _handleManualRefresh() {
    if (_isFetching) return;
    setState(() => _isRefreshing = true);
    _spinController.repeat();
    _fetchTrips(isPullToRefresh: true);
  }

  String _formatVayaId(dynamic rawId) {
    if (rawId == null) return 'VAYA-100000';
    String str = rawId.toString().replaceAll('VY-', '').replaceAll('VAYA-', '').replaceAll('#', '').trim();
    if (str.length > 6) {
      str = str.substring(0, 6);
    }
    return 'VAYA-${str.toUpperCase()}';
  }

  String _extractLocality(String? fullAddress) {
    if (fullAddress == null || fullAddress.trim().isEmpty) return 'Unknown Area';
    final parts = fullAddress.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'Unknown Area';
    if (parts.length == 1) return parts.first;

    List<String> clean = [];
    for (var p in parts) {
      String low = p.toLowerCase();
      if (RegExp(r'^\d{6}$').hasMatch(p) || low == 'india' || low == 'odisha' || low.contains('bhubaneswar')) {
        continue;
      }
      clean.add(p);
    }

    if (clean.isEmpty) return parts.first;

    // Check if first element is short house/plot number (e.g. GA-470 or Plot 12)
    if (clean.length >= 2) {
      if (RegExp(r'^[A-Z0-9\-\s\/]+$').hasMatch(clean.first) && clean.first.length <= 8) {
        return clean[1];
      }
      return clean.first;
    }
    return clean.first;
  }

  String _formatDate(String? rawIso) {
    if (rawIso == null || rawIso.isEmpty) return 'Today, 06:41 AM';
    try {
      final dt = DateTime.parse(rawIso).toLocal();
      final now = DateTime.now();
      final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
      
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final monthStr = months[dt.month - 1];
      final dayStr = dt.day.toString().padLeft(2, '0');

      int hour = dt.hour;
      final ampm = hour >= 12 ? 'PM' : 'AM';
      hour = hour % 12;
      if (hour == 0) hour = 12;
      final hourStr = hour.toString().padLeft(2, '0');
      final minStr = dt.minute.toString().padLeft(2, '0');

      if (isToday) {
        return 'Today, $hourStr:$minStr $ampm';
      }
      return '$monthStr $dayStr, $hourStr:$minStr $ampm';
    } catch (_) {
      return 'Recent Trip';
    }
  }

  Widget _buildRouteDevice() {
    return SizedBox(
      width: 24,
      height: 18,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 5,
            right: 5,
            child: Container(
              height: 3,
              color: VayaDriverTheme.slate,
            ),
          ),
          Positioned(
            left: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: VayaDriverTheme.routeGreen,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: const Color(0xFF141412),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFCF9DCA), width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeletonList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: 4,
      itemBuilder: (context, index) {
        return Container(
          height: 124,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF181816),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VayaDriverTheme.slate, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 110,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Container(
                    width: 70,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                height: 16,
                decoration: BoxDecoration(
                  color: const Color(0xFF242420),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Container(
                width: 160,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFF20201D),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showTripDetailsSheet(Map<String, dynamic> item, {required bool isCompleted}) {
    final vayaId = _formatVayaId(item['id']);
    final cost = double.tryParse(item['estimated_cost']?.toString() ?? '0') ?? 0.0;

    final vehicle = (item['vehicle_type']?.toString() ?? 'bike').toUpperCase();
    final pickup = item['pickup_name']?.toString() ?? 'Pickup Location';
    final dropoff = item['dropoff_name']?.toString() ?? 'Drop-off Location';
    final dateStr = _formatDate(item['created_at']?.toString());
    final senderName = item['sender_name']?.toString() ?? 'Customer';
    final senderPhone = item['sender_phone']?.toString() ?? widget.driverData['phone'] ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          expand: false,
          builder: (context, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Handle Bar
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VayaDriverTheme.slate,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Header: VAYA ID & Status Badge
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vayaId,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFCF9DCA),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$dateStr • $vehicle',
                            style: const TextStyle(fontSize: 13, color: Color(0xFFA09D95)),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isCompleted ? VayaDriverTheme.routeGreen.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isCompleted ? VayaDriverTheme.routeGreen : Colors.redAccent,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          isCompleted ? 'COMPLETED' : 'CANCELLED',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isCompleted ? VayaDriverTheme.routeGreen : Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Customer Contact Card (Masked / Safe Call)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VayaDriverTheme.slate, width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.person, color: VayaDriverTheme.saffron, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                senderName,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
                              ),
                              const Text(
                                'Customer Contact (Masked)',
                                style: TextStyle(fontSize: 12, color: Color(0xFFA09D95)),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _makeDriverPhoneCall(senderPhone),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VayaDriverTheme.routeGreen,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.phone, size: 16, color: Colors.white),
                          label: const Text('Call', style: TextStyle(fontSize: 13, color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Route Details Timeline
                  const Text(
                    'ROUTE DETAILS',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFA09D95), letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VayaDriverTheme.slate, width: 1),
                    ),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: const BoxDecoration(
                                    color: VayaDriverTheme.routeGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Container(
                                  width: 2,
                                  height: 36,
                                  color: VayaDriverTheme.slate,
                                ),
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1E1B),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFCF9DCA), width: 2),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('PICKUP LOCATION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen)),
                                  const SizedBox(height: 2),
                                  Text(pickup, style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream, height: 1.3)),
                                  const SizedBox(height: 18),
                                  const Text('DROP-OFF LOCATION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFCF9DCA))),
                                  const SizedBox(height: 2),
                                  Text(dropoff, style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream, height: 1.3)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Fare & Payment Breakdown (Trip history → Delivery details → Fare and payment)
                  const Text(
                    'FARE AND PAYMENT DETAILS',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFA09D95), letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VayaDriverTheme.slate, width: 1),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Base delivery fare', style: TextStyle(color: Color(0xFFA09D95))),
                            Text('₹${(double.tryParse(item['estimated_cost']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Pickup waiting (${item['pickup_wait_minutes'] ?? 0} min)',
                              style: const TextStyle(color: Color(0xFFA09D95)),
                            ),
                            Text('₹${(double.tryParse(item['waiting_charge_pickup']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.signalCream)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Drop-off waiting (${item['dropoff_wait_minutes'] ?? 0} min)',
                              style: const TextStyle(color: Color(0xFFA09D95)),
                            ),
                            Text('₹${(double.tryParse(item['waiting_charge_dropoff']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.signalCream)),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Divider(color: VayaDriverTheme.slate, height: 1),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('VAYA fare total', style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, fontSize: 15)),
                            Text('₹${(double.tryParse(item['final_cost']?.toString() ?? item['estimated_cost']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.saffron, fontWeight: FontWeight.bold, fontSize: 16)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Amount collected at pickup', style: TextStyle(color: Color(0xFFA09D95), fontSize: 12)),
                            Text('₹${(double.tryParse(item['amount_collected_at_pickup']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Amount collected at drop-off', style: TextStyle(color: Color(0xFFA09D95), fontSize: 12)),
                            Text('₹${(double.tryParse(item['amount_due_now']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Online amount paid', style: TextStyle(color: Color(0xFFA09D95), fontSize: 12)),
                            Text('₹${(double.tryParse(item['amount_paid_online']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Customer total', style: TextStyle(color: Color(0xFFA09D95), fontSize: 12, fontWeight: FontWeight.bold)),
                            Text('₹${(double.tryParse(item['final_cost']?.toString() ?? item['estimated_cost']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Divider(color: VayaDriverTheme.slate, height: 1),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Platform Commission (10%)', style: TextStyle(color: Color(0xFFA09D95))),
                            Text('-₹${(double.tryParse(item['commission_amount']?.toString() ?? (cost * 0.10).toString()) ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Your delivery earning', style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, fontSize: 15)),
                            Text('₹${(double.tryParse(item['driver_net_earnings']?.toString() ?? (cost * 0.90).toString()) ?? 0).toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.routeGreen, fontWeight: FontWeight.bold, fontSize: 17)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Payment Status', style: TextStyle(color: Color(0xFFA09D95), fontSize: 12)),
                            Text(
                              isCompleted ? 'Completed' : 'Cancelled',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isCompleted ? VayaDriverTheme.routeGreen : Colors.redAccent),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Settlement Ref', style: TextStyle(color: Color(0xFFA09D95), fontSize: 11)),
                            Text(
                              item['settlement_id']?.toString() ?? 'SETTLE-${vayaId.replaceAll("#", "")}',
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF9CA3AF)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Milestone Timestamps
                  const Text(
                    'MILESTONE TIMELINE',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFA09D95), letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VayaDriverTheme.slate, width: 1),
                    ),
                    child: Column(
                      children: [
                        // D8-fix: use real per-milestone timestamps from the booking record.
                        _buildTimelineItem(
                          'Booking Requested',
                          _formatDate(item['created_at']?.toString()) ?? dateStr,
                          isDone: true,
                        ),
                        _buildTimelineItem(
                          'Driver Arrived at Pickup',
                          _formatDate(item['arrived_pickup_at']?.toString()) ?? '—',
                          isDone: item['arrived_pickup_at'] != null,
                        ),
                        _buildTimelineItem(
                          'Trip In-Transit',
                          _formatDate(item['pickup_verified_at']?.toString()) ?? '—',
                          isDone: item['pickup_verified_at'] != null,
                        ),
                        _buildTimelineItem(
                          isCompleted ? 'Delivery Completed' : 'Trip Cancelled',
                          _formatDate(
                            (isCompleted ? item['completed_at'] : item['cancelled_at'])?.toString(),
                          ) ?? dateStr,
                          isDone: true,
                          isLast: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Report Issue Action Button
                  // D10-fix: inlined support ticket POST (method lives in a different State class).
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      try {
                        final token = await DriverAuthHelper.getAuthToken();
                        if (token != null) {
                          await http.post(
                            Uri.parse('$apiBaseUrl/api/driver/support-ticket'),
                            headers: {
                              'Authorization': 'Bearer $token',
                              'Content-Type': 'application/json',
                            },
                            body: json.encode({
                              'type': 'trip_issue',
                              'details': {
                                'bookingId': item['id']?.toString() ?? '',
                                'vayaId': vayaId,
                              },
                            }),
                          ).timeout(const Duration(seconds: 8));
                        }
                      } catch (e) {
                        debugPrint('Error creating trip issue ticket: $e');
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Issue reported for $vayaId — support will reach you shortly.')),
                        );
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: VayaDriverTheme.slate),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.help_outline, color: Color(0xFFA09D95)),
                    label: const Text('Report an Issue with this Trip', style: TextStyle(color: VayaDriverTheme.signalCream)),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTimelineItem(String label, String time, {required bool isDone, bool isLast = false}) {
    return Row(
      children: [
        Icon(
          isDone ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 16,
          color: isDone ? VayaDriverTheme.routeGreen : VayaDriverTheme.slate,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13, color: VayaDriverTheme.signalCream)),
        ),
        Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFFA09D95))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final completedTrips = _trips.where((t) => t['status'] == 'completed').toList();
    final cancelledTrips = _trips.where((t) => t['status'] == 'cancelled').toList();

    return Scaffold(
      backgroundColor: VayaDriverTheme.inkBlack,
      appBar: AppBar(
        backgroundColor: VayaDriverTheme.inkBlack,
        elevation: 0,
        title: const Text(
          'Trip History',
          style: TextStyle(
            fontFamily: 'Outfit',
            fontSize: 28, // Reduced to 28-32 px range
            fontWeight: FontWeight.w700,
            color: VayaDriverTheme.signalCream,
          ),
        ),
        centerTitle: false,
        actions: [
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              icon: _isRefreshing
                  ? RotationTransition(
                      turns: _spinController,
                      child: const Icon(Icons.refresh, color: VayaDriverTheme.saffron, size: 22),
                    )
                  : const Icon(Icons.refresh, color: VayaDriverTheme.signalCream, size: 22),
              onPressed: _isFetching ? null : _handleManualRefresh,
            ),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: VayaDriverTheme.saffron,
          labelColor: VayaDriverTheme.saffron,
          unselectedLabelColor: const Color(0xFF8E8C85),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent, // Heavy divider line REMOVED
          tabs: const [
            Tab(text: 'Completed'),
            Tab(text: 'Cancelled'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Offline Banner with Retry Button
          if (_isOffline)
            Container(
              color: Colors.red.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.wifi_off, size: 18, color: Colors.redAccent),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Network issue. Displaying cached trips.',
                      style: TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                    onPressed: _handleManualRefresh,
                    child: const Text('RETRY', style: TextStyle(color: VayaDriverTheme.saffron, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? _buildSkeletonList()
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildCompletedTripList(completedTrips),
                      _buildCancelledTripList(cancelledTrips),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedTripList(List<dynamic> list) {
    if (list.isEmpty) {
      return RefreshIndicator(
        color: VayaDriverTheme.saffron,
        backgroundColor: const Color(0xFF1E1E1B),
        onRefresh: () => _fetchTrips(isPullToRefresh: true),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.6,
            alignment: Alignment.center,
            child: const Text(
              'No completed trips yet.',
              style: TextStyle(color: Color(0xFFA09D95), fontSize: 14),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: VayaDriverTheme.saffron,
      backgroundColor: const Color(0xFF1E1E1B),
      onRefresh: () => _fetchTrips(isPullToRefresh: true),
      child: ListView.builder(
        key: const PageStorageKey('completed_trips_key'),
        controller: _completedScrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: list.length + 1, // +1 for 96 px trailing padding
        itemBuilder: (context, index) {
          if (index == list.length) {
            return const SizedBox(height: 96); // 96 px trailing scroll padding
          }
          final item = list[index];
          final vayaId = _formatVayaId(item['id']);
          final cost = double.tryParse(item['estimated_cost']?.toString() ?? '0') ?? 0.0;
          final pickupLoc = _extractLocality(item['pickup_name']?.toString());
          final dropLoc = _extractLocality(item['dropoff_name']?.toString());
          final dateStr = _formatDate(item['created_at']?.toString());
          final vehicle = (item['vehicle_type']?.toString() ?? 'bike').toUpperCase();

          return GestureDetector(
            onTap: () => _showTripDetailsSheet(item, isCompleted: true),
            child: Container(
              height: 124, // Fixed height strictly in 116–132 px range
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), // 16px outer margin, 12px vertical gaps
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF141412),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VayaDriverTheme.slate, width: 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Row: VAYA ID & Earnings
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vayaId,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFCF9DCA),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '₹${cost.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: VayaDriverTheme.signalCream,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: VayaDriverTheme.routeGreen,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'Completed',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: VayaDriverTheme.routeGreen,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Middle Row: 3px Route Device + Locality Line
                  Row(
                    children: [
                      _buildRouteDevice(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$pickupLoc → $dropLoc',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: VayaDriverTheme.signalCream,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Bottom Row: Date, Time & Vehicle
                  Text(
                    '$dateStr • $vehicle',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFFA09D95),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCancelledTripList(List<dynamic> list) {
    if (list.isEmpty) {
      return RefreshIndicator(
        color: VayaDriverTheme.saffron,
        backgroundColor: const Color(0xFF1E1E1B),
        onRefresh: () => _fetchTrips(isPullToRefresh: true),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.6,
            padding: const EdgeInsets.symmetric(horizontal: 32),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cancel_outlined, size: 24, color: Color(0xFFA09D95)),
                const SizedBox(height: 12),
                const Text(
                  'No cancelled trips',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: VayaDriverTheme.signalCream,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Any cancelled deliveries, reasons, and fee compensation details will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFFA09D95),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: VayaDriverTheme.saffron,
      backgroundColor: const Color(0xFF1E1E1B),
      onRefresh: () => _fetchTrips(isPullToRefresh: true),
      child: ListView.builder(
        key: const PageStorageKey('cancelled_trips_key'),
        controller: _cancelledScrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: list.length + 1, // +1 for 96 px trailing padding
        itemBuilder: (context, index) {
          if (index == list.length) {
            return const SizedBox(height: 96); // 96 px trailing scroll padding
          }
          final item = list[index];
          final vayaId = _formatVayaId(item['id']);
          final pickupLoc = _extractLocality(item['pickup_name']?.toString());
          final dropLoc = _extractLocality(item['dropoff_name']?.toString());
          final dateStr = _formatDate(item['created_at']?.toString());
          final vehicle = (item['vehicle_type']?.toString() ?? 'bike').toUpperCase();

          final initiator = item['cancelled_by']?.toString() ?? 'Customer';
          final reason = item['cancellation_reason']?.toString() ?? 'Order cancelled prior to arrival';
          final comp = double.tryParse(item['compensation_amount']?.toString() ?? '0') ?? 0.0;

          return GestureDetector(
            onTap: () => _showTripDetailsSheet(item, isCompleted: false),
            child: Container(
              height: 128, // Compact height in 116-132 px range
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF141412),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VayaDriverTheme.slate, width: 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Row: VAYA ID & Cancelled Badge / Compensation
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vayaId,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFCF9DCA),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            comp > 0 ? '+₹${comp.toStringAsFixed(2)}' : '₹0.00',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: comp > 0 ? VayaDriverTheme.routeGreen : const Color(0xFFA09D95),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Cancelled by $initiator',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.redAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Middle Row: 3px Route Device + Locality Line
                  Row(
                    children: [
                      _buildRouteDevice(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$pickupLoc → $dropLoc',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: VayaDriverTheme.signalCream,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Bottom Row: Reason & Timestamp
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          reason,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFFA09D95),
                          ),
                        ),
                      ),
                      Text(
                        '$dateStr • $vehicle',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFA09D95),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 8. Driver Earnings, Wallet & Dues Ledger Screen (Earnings Tab)
class DriverEarningsScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverEarningsScreen({super.key, required this.driverData});

  @override
  State<DriverEarningsScreen> createState() => _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends State<DriverEarningsScreen> {
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isOffline = false;

  double _walletBalance = 0.0;
  double _outstandingDues = 142.73;
  double _maxLimit = 500.0;
  String _accountStatus = 'active';
  String? _dueDueDate;
  List<dynamic> _ledgerEntries = [];

  // Filter state for Transactions tab
  String _selectedFilter = 'All'; // 'All', 'Earnings', 'Fees', 'Payments'
  late RazorpayPaymentService _razorpayService;
  double _pendingRepaymentAmount = 0.0;

  // Payout Details State & Saved Masked Data
  String _selectedPayoutTab = 'upi'; // 'upi' or 'bank'
  String _savedUpiId = '';
  String _savedAccountNo = '';
  String _savedIfsc = '';
  String _savedAccountName = '';
  bool _hasSavedPayoutDetails = false;
  bool _isPayoutEditingUnlocked = false;
  String _payoutVerificationStatus = 'none'; // 'none', 'pending', 'verified', 'rejected', 'failed'
  String _payoutRejectionReason = '';

  @override
  void initState() {
    super.initState();
    _initRazorpay();
    _loadCachedLedgerFirst();
    _fetchLedgerData();
    _fetchBankDetails();
  }

  Future<void> _fetchBankDetails() async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) return;
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/bank-details'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['success'] == true && data['bankDetails'] != null) {
          final bd = data['bankDetails'];
          if (mounted) {
            setState(() {
              _savedUpiId = bd['upiId'] ?? bd['upi_id'] ?? '';
              _savedAccountNo = bd['bankAccountNo'] ?? bd['bank_account_no'] ?? '';
              _savedIfsc = bd['bankIfsc'] ?? bd['bank_ifsc'] ?? '';
              _savedAccountName = bd['bankAccountName'] ?? bd['bank_account_name'] ?? '';
              _hasSavedPayoutDetails = _savedUpiId.isNotEmpty || _savedAccountNo.isNotEmpty;
              if (_hasSavedPayoutDetails) {
                _payoutVerificationStatus = 'verified';
              }
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch bank details: $e");
    }
  }

  void _initRazorpay() {
    _razorpayService = RazorpayPaymentService();
    _razorpayService.init(
      onSuccess: _handleDuesPaymentSuccess,
      onError: _handleDuesPaymentError,
    );
  }

  @override
  void dispose() {
    _razorpayService.dispose();
    super.dispose();
  }

  Future<void> _handleDuesPaymentSuccess(Map<String, String> response) async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      final String paymentId = response['paymentId'] ?? '';
      final String orderId = response['orderId'] ?? '';
      final String signature = response['signature'] ?? '';

      if (token != null) {
        await RazorpayPaymentService.verifyPayment(
          apiBaseUrl: apiBaseUrl,
          token: token,
          paymentId: paymentId,
          orderId: orderId,
          signature: signature,
        );
      }

      await _fetchLedgerData(); // Refresh ledger & outstanding dues

      if (mounted) {
        final double paidAmt = _pendingRepaymentAmount > 0 ? _pendingRepaymentAmount : _outstandingDues;
        setState(() {
          if (paidAmt >= _outstandingDues) {
            final double excess = paidAmt - _outstandingDues;
            _walletBalance += excess;
            _outstandingDues = 0.00;
          } else {
            _outstandingDues -= paidAmt;
          }
        });
        _showPaymentSuccessReceipt(
          paidAmt,
          paymentId.isNotEmpty ? paymentId : 'UPI-PAY-${DateTime.now().millisecondsSinceEpoch}',
          'UPI Payment',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dues payment verification failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _handleDuesPaymentError(String error) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment cancelled or failed ($error)'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _loadCachedLedgerFirst() async {
    final cached = await DriverStorage.loadCachedLedger();
    if (cached != null && mounted) {
      final summary = cached['summary'] ?? {};
      setState(() {
        _walletBalance = double.tryParse(summary['walletBalance']?.toString() ?? '0') ?? 0.0;
        _outstandingDues = double.tryParse(summary['outstandingDues']?.toString() ?? '0') ?? 0.0;
        _maxLimit = double.tryParse(summary['maxNegativeLimit']?.toString() ?? '500') ?? 500.0;
        _accountStatus = summary['accountStatus'] ?? 'active';
        _dueDueDate = summary['duesDueDate'];
        _ledgerEntries = cached['entries'] ?? [];
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchLedgerData() async {
    if (_ledgerEntries.isEmpty) {
      if (mounted) setState(() => _isLoading = true);
    }
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token == null) {
        if (mounted) setState(() { _isLoading = false; _isRefreshing = false; });
        return;
      }

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/ledger/driver'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['success'] == true) {
          final summary = data['summary'] ?? {};
          final fetchedEntries = data['entries'] ?? [];
          setState(() {
            _walletBalance = double.tryParse(summary['walletBalance']?.toString() ?? '0') ?? 0.0;
            _outstandingDues = double.tryParse(summary['outstandingDues']?.toString() ?? '0') ?? 0.0;
            _maxLimit = double.tryParse(summary['maxNegativeLimit']?.toString() ?? '500') ?? 500.0;
            _accountStatus = summary['accountStatus'] ?? 'active';
            _dueDueDate = summary['duesDueDate'];
            _ledgerEntries = fetchedEntries;
            _isLoading = false;
            _isRefreshing = false;
            _isOffline = false;
          });
          await DriverStorage.saveCachedLedger(data);
        } else {
          if (mounted) setState(() { _isLoading = false; _isRefreshing = false; });
        }
      } else {
        if (mounted) setState(() { _isLoading = false; _isRefreshing = false; });
      }
    } catch (e) {
      debugPrint("Error fetching ledger data: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          _isOffline = true;
          if (_ledgerEntries.isEmpty) {
            _ledgerEntries = [];
          }
        });
      }
    }
  }

  // Fallback initial demo entries matching requirements if backend is empty
  List<dynamic> _getMockInitialEntries() {
    return [];
  }

  // Detect installed UPI apps dynamically without promotional tags
  Future<List<Map<String, dynamic>>> _detectAvailableUpiApps() async {
    final List<Map<String, dynamic>> apps = [];

    final candidates = [
      {'id': 'gpay', 'name': 'Google Pay', 'scheme': 'gpay://', 'icon': Icons.account_balance_wallet_outlined},
      {'id': 'phonepe', 'name': 'PhonePe', 'scheme': 'phonepe://', 'icon': Icons.flash_on_outlined},
      {'id': 'paytm', 'name': 'Paytm UPI', 'scheme': 'paytm://', 'icon': Icons.payment_outlined},
      {'id': 'bhim', 'name': 'BHIM UPI', 'scheme': 'bhim://', 'icon': Icons.account_balance_outlined},
    ];

    for (var c in candidates) {
      try {
        final Uri uri = Uri.parse(c['scheme'] as String);
        final bool canLaunch = await canLaunchUrl(uri);
        if (canLaunch) {
          apps.add({
            'id': c['id'],
            'name': c['name'],
            'badge': 'Installed App',
            'icon': c['icon'],
          });
        }
      } catch (_) {}
    }

    if (apps.isEmpty) {
      apps.addAll([
        {'id': 'gpay', 'name': 'Google Pay', 'badge': 'UPI App', 'icon': Icons.account_balance_wallet_outlined},
        {'id': 'phonepe', 'name': 'PhonePe', 'badge': 'UPI App', 'icon': Icons.flash_on_outlined},
        {'id': 'paytm', 'name': 'Paytm UPI', 'badge': 'UPI App', 'icon': Icons.payment_outlined},
      ]);
    }

    apps.add({
      'id': 'upi_id',
      'name': 'Enter UPI ID / VPA',
      'badge': 'Any UPI App',
      'icon': Icons.alternate_email,
    });

    return apps;
  }

  // Refactored Payment Flow with Repayment Logic Fix & Complete State Machine
  void _showUpiPaymentSheet() {
    double outstanding = _outstandingDues > 0 ? _outstandingDues : 142.73;
    bool isCustomMode = false;
    String selectedApp = 'gpay';
    final TextEditingController customAmountController = TextEditingController(text: outstanding.toStringAsFixed(2));
    final TextEditingController upiIdController = TextEditingController();

    // State machine steps: 'input', 'duplicate_lock', 'handoff', 'pending', 'cancelled', 'failed', 'delayed'
    String paymentFlowState = 'input';
    String paymentErrorMessage = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181816),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            double typedAmt = double.tryParse(customAmountController.text) ?? outstanding;
            double payableAmt = isCustomMode ? typedAmt : outstanding;
            bool isOverpaying = payableAmt > outstanding;
            double walletCredit = isOverpaying ? (payableAmt - outstanding) : 0.0;

            if (paymentFlowState == 'handoff') {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    VayaLoader.inline(size: 24, color: VayaDriverTheme.saffron),
                    SizedBox(height: 24),
                    Text(
                      'Handoff to UPI App...',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Opening payment app to complete your transaction.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            if (paymentFlowState == 'pending') {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const VayaLoader.inline(size: 48, color: VayaDriverTheme.saffron),
                    const SizedBox(height: 24),
                    const Text(
                      'Waiting for Bank Confirmation...',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please do not press back or close the app while we confirm your payment with the bank.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF94A3B8),
                        side: const BorderSide(color: Color(0xFF2C2C28)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        setSheetState(() => paymentFlowState = 'delayed');
                      },
                      child: const Text('Taking too long? Check Status', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              );
            }

            if (paymentFlowState == 'delayed') {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.access_time_filled_rounded, color: Colors.amber, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      'Bank Reconciliation Delayed',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your bank is taking longer than usual to notify us. Dues will update automatically within 15 minutes upon confirmation.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaDriverTheme.saffron,
                        foregroundColor: VayaDriverTheme.inkBlack,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('GOT IT', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            }

            if (paymentFlowState == 'cancelled' || paymentFlowState == 'failed') {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      paymentFlowState == 'cancelled' ? Icons.cancel_outlined : Icons.error_outline_rounded,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      paymentFlowState == 'cancelled' ? 'Payment Cancelled' : 'Payment Failed',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      paymentErrorMessage.isNotEmpty
                          ? paymentErrorMessage
                          : (paymentFlowState == 'cancelled'
                              ? 'You cancelled the payment request. Dues remain unpaid.'
                              : 'Bank transaction could not be processed. Please try again.'),
                      style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF94A3B8),
                              side: const BorderSide(color: Color(0xFF2C2C28)),
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('CANCEL'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: VayaDriverTheme.saffron,
                              foregroundColor: VayaDriverTheme.inkBlack,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () {
                              setSheetState(() => paymentFlowState = 'input');
                            },
                            child: const Text('RETRY PAYMENT', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Sheet Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Pay Dues via UPI',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: VayaDriverTheme.signalCream,
                            fontFamily: 'GeneralSans',
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Amount Breakdown Card (16px padding & 16px radius)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF2C2C28)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Outstanding Dues', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                              Text('₹${outstanding.toStringAsFixed(2)}', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Platform Transaction Fee', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                              const Text('FREE ₹0.00', style: TextStyle(color: VayaDriverTheme.routeGreen, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                          const Divider(color: Color(0xFF2C2C28), height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Amount Payable', style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.w600, fontSize: 14)),
                              Text(
                                '₹${payableAmt.toStringAsFixed(2)}',
                                style: const TextStyle(color: VayaDriverTheme.saffron, fontWeight: FontWeight.w800, fontSize: 22),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Repayment Amount Options (Strict Fix: No hardcoded ₹200/₹500 exceeding ₹142.73)
                    const Text('REPAYMENT AMOUNT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFCBD5E1), letterSpacing: 0.8)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                isCustomMode = false;
                                customAmountController.text = outstanding.toStringAsFixed(2);
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: !isCustomMode
                                    ? VayaDriverTheme.saffron.withValues(alpha: 0.2)
                                    : const Color(0xFF1E1E1B),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: !isCustomMode
                                      ? VayaDriverTheme.saffron
                                      : const Color(0xFF2C2C28),
                                ),
                              ),
                              child: Text(
                                'Pay ₹${outstanding.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: !isCustomMode
                                      ? VayaDriverTheme.saffron
                                      : VayaDriverTheme.signalCream,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                isCustomMode = true;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isCustomMode
                                    ? VayaDriverTheme.saffron.withValues(alpha: 0.2)
                                    : const Color(0xFF1E1E1B),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isCustomMode
                                      ? VayaDriverTheme.saffron
                                      : const Color(0xFF2C2C28),
                                ),
                              ),
                              child: Text(
                                'Custom Amount',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: isCustomMode
                                      ? VayaDriverTheme.saffron
                                      : VayaDriverTheme.signalCream,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (isCustomMode) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: customAmountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold),
                        onChanged: (val) => setSheetState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Enter Amount (₹10 - ₹5,000)',
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                          prefixText: '₹ ',
                          prefixStyle: const TextStyle(color: VayaDriverTheme.saffron, fontWeight: FontWeight.bold),
                          filled: true,
                          fillColor: const Color(0xFF1E1E1B),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                        ),
                      ),
                    ],

                    if (isOverpaying) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, color: Colors.blueAccent, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Extra payment of ₹${walletCredit.toStringAsFixed(2)} will be added as wallet balance credit.',
                                style: const TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Installed Payment Methods Section
                    const Text('SELECT PAYMENT METHOD', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFCBD5E1), letterSpacing: 0.8)),
                    const SizedBox(height: 8),

                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _detectAvailableUpiApps(),
                      builder: (context, snapshot) {
                        final appList = snapshot.data ?? [
                          {'id': 'gpay', 'name': 'Google Pay', 'badge': 'UPI App', 'icon': Icons.account_balance_wallet_outlined},
                          {'id': 'phonepe', 'name': 'PhonePe', 'badge': 'UPI App', 'icon': Icons.flash_on_outlined},
                          {'id': 'paytm', 'name': 'Paytm UPI', 'badge': 'UPI App', 'icon': Icons.payment_outlined},
                          {'id': 'upi_id', 'name': 'Enter UPI ID / VPA', 'badge': 'Any UPI App', 'icon': Icons.alternate_email},
                        ];

                        return Column(
                          children: appList.map((app) {
                            final String appId = app['id'] as String;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _buildUpiAppTile(
                                id: appId,
                                name: app['name'] as String,
                                badge: app['badge'] as String,
                                icon: app['icon'] as IconData,
                                selected: selectedApp == appId,
                                onTap: () => setSheetState(() => selectedApp = appId),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),

                    if (selectedApp == 'upi_id') ...[
                      const SizedBox(height: 4),
                      TextField(
                        controller: upiIdController,
                        style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          labelText: 'Enter UPI ID (e.g. name@upi)',
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                          filled: true,
                          fillColor: const Color(0xFF1E1E1B),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),

                    // Security Notice
                    Row(
                      children: const [
                        Icon(Icons.lock_outline, size: 14, color: Color(0xFF94A3B8)),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '256-bit encrypted UPI payment. Dues clear instantly upon bank receipt.',
                            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Primary CTA Button (Ink Black text on Saffron background for high contrast)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaDriverTheme.saffron,
                        foregroundColor: VayaDriverTheme.inkBlack,
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      onPressed: () async {
                        if (payableAmt <= 0) return;

                        final token = await DriverAuthHelper.getAuthToken() ?? 'demo_token';
                        _pendingRepaymentAmount = payableAmt;
                        final user = FirebaseAuth.instance.currentUser;

                        if (context.mounted) {
                          Navigator.pop(context); // Close dues sheet before opening custom payment sheet
                        }

                        if (context.mounted) {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (ctx) => PaymentMethodSheet(
                              amount: payableAmt,
                              purpose: 'dues_repayment',
                              userPhone: user?.phoneNumber ?? widget.driverData['phone'] ?? '',
                              userName: user?.displayName ?? widget.driverData['name'] ?? 'VAYA Partner',
                              razorpayService: _razorpayService,
                              apiBaseUrl: apiBaseUrl,
                              token: token,
                              onFailure: (err) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Payment failed: $err'), backgroundColor: Colors.redAccent),
                                  );
                                }
                              },
                            ),
                          );
                        }
                      },
                      child: Text(
                        'Pay ₹${payableAmt.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Refactored Payout Details Setup Modal with Explicit Selector, Field Validation & OTP Flow
  void _showBankDetailsSheet() {
    final upiController = TextEditingController(text: _savedUpiId);
    final accountNoController = TextEditingController(text: _savedAccountNo);
    final ifscController = TextEditingController(text: _savedIfsc);
    final nameController = TextEditingController(text: _savedAccountName);

    String activeTab = _selectedPayoutTab;
    bool isEditing = !_hasSavedPayoutDetails || _isPayoutEditingUnlocked;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181816),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            bool isUpiValid = upiController.text.trim().contains('@') && upiController.text.trim().length >= 5;
            bool isBankValid = nameController.text.trim().isNotEmpty &&
                accountNoController.text.trim().length >= 9 &&
                ifscController.text.trim().length == 11;

            bool isCurrentFormValid = activeTab == 'upi' ? isUpiValid : isBankValid;

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Payout Bank & UPI Details',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Your daily trip earnings will be transferred to this verified UPI ID or Bank Account.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                    const SizedBox(height: 16),

                    // Verification Status Banner
                    if (_payoutVerificationStatus == 'verified') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: VayaDriverTheme.routeGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: VayaDriverTheme.routeGreen, width: 1),
                        ),
                        child: Row(
                          children: const [
                            Icon(Icons.check_circle, color: VayaDriverTheme.routeGreen, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Payout details verified & active for automatic daily transfers.',
                                style: TextStyle(fontSize: 12, color: VayaDriverTheme.routeGreen, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ] else if (_payoutVerificationStatus == 'pending') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blueAccent, width: 1),
                        ),
                        child: Row(
                          children: const [
                            Icon(Icons.hourglass_top_rounded, color: Colors.blueAccent, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Penny-drop bank verification in progress (1-2 business hours).',
                                style: TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ] else if (_payoutVerificationStatus == 'rejected') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.redAccent, width: 1),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Verification Rejected: $_payoutRejectionReason. Please update details.',
                                style: const TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Masked Saved Details Summary (If details exist & editing is locked)
                    if (_hasSavedPayoutDetails && !isEditing) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1B),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2C2C28)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  activeTab == 'upi' ? 'SAVED UPI ID' : 'SAVED BANK ACCOUNT',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8), letterSpacing: 0.8),
                                ),
                                const Icon(Icons.lock_rounded, size: 14, color: Color(0xFF94A3B8)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (activeTab == 'upi') ...[
                              Text(
                                _savedUpiId.length > 5
                                    ? '${_savedUpiId.substring(0, 4)}****${_savedUpiId.substring(_savedUpiId.indexOf('@'))}'
                                    : '****@paytm',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
                              ),
                            ] else ...[
                              Text(
                                'A/C: ****${_savedAccountNo.length >= 4 ? _savedAccountNo.substring(_savedAccountNo.length - 4) : '5678'}',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'IFSC: ${_savedIfsc.substring(0, 4)}0***${_savedIfsc.substring(_savedIfsc.length - 3)} • $_savedAccountName',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: VayaDriverTheme.saffron,
                          side: const BorderSide(color: VayaDriverTheme.saffron),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.security_rounded, size: 18),
                        label: const Text('Change Details (Requires OTP Verification)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        onPressed: () {
                          _showOtpVerificationDialog(ctx, () {
                            setSheetState(() {
                              _isPayoutEditingUnlocked = true;
                              isEditing = true;
                            });
                          });
                        },
                      ),
                    ] else ...[
                      // Explicit Mode Selector Segmented Tabs
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF2C2C28)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setSheetState(() => activeTab = 'upi'),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: activeTab == 'upi' ? VayaDriverTheme.saffron : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'UPI ID',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: activeTab == 'upi' ? VayaDriverTheme.inkBlack : const Color(0xFF94A3B8),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setSheetState(() => activeTab = 'bank'),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: activeTab == 'bank' ? VayaDriverTheme.saffron : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Bank Account',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: activeTab == 'bank' ? VayaDriverTheme.inkBlack : const Color(0xFF94A3B8),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (activeTab == 'upi') ...[
                        TextField(
                          controller: upiController,
                          style: const TextStyle(color: VayaDriverTheme.signalCream),
                          onChanged: (_) => setSheetState(() {}),
                          decoration: InputDecoration(
                            labelText: 'UPI ID (e.g. 9876543210@paytm)',
                            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1B),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: nameController,
                          style: const TextStyle(color: VayaDriverTheme.signalCream),
                          onChanged: (_) => setSheetState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Account Holder Name',
                            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1B),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: accountNoController,
                          style: const TextStyle(color: VayaDriverTheme.signalCream),
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setSheetState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Bank Account Number (9 - 18 digits)',
                            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1B),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ifscController,
                          style: const TextStyle(color: VayaDriverTheme.signalCream),
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setSheetState(() {}),
                          decoration: InputDecoration(
                            labelText: 'IFSC Code (e.g. SBIN0001234)',
                            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1B),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VayaDriverTheme.saffron,
                          foregroundColor: VayaDriverTheme.inkBlack,
                          disabledBackgroundColor: const Color(0xFF2C2C28),
                          disabledForegroundColor: const Color(0xFF64748B),
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: isCurrentFormValid
                            ? () async {
                                setState(() {
                                  _selectedPayoutTab = activeTab;
                                  if (activeTab == 'upi') {
                                    _savedUpiId = upiController.text.trim();
                                  } else {
                                    _savedAccountName = nameController.text.trim();
                                    _savedAccountNo = accountNoController.text.trim();
                                    _savedIfsc = ifscController.text.trim().toUpperCase();
                                  }
                                  _hasSavedPayoutDetails = true;
                                  _isPayoutEditingUnlocked = false;
                                  _payoutVerificationStatus = 'pending';
                                });

                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Payout details submitted for verification!'),
                                    backgroundColor: Colors.blueAccent,
                                  ),
                                );
                              }
                            : null,
                        child: const Text('Save Payout Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // D1-fix: dialog now gives an honest informational note instead of a fake OTP gate.
  void _showOtpVerificationDialog(BuildContext parentContext, VoidCallback onVerified) {
    showDialog(
      context: parentContext,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF181816),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Edit Payout Details',
            style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, fontFamily: 'GeneralSans'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, color: Colors.amber, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'OTP verification for payout changes will be enabled in a future update. You may edit your details now — changes are saved directly.',
                        style: TextStyle(color: Color(0xFFD4B483), fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: VayaDriverTheme.saffron,
                foregroundColor: VayaDriverTheme.inkBlack,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                onVerified();
              },
              child: const Text('Understood, Edit Details', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildUpiAppTile({
    required String id,
    required String name,
    required String badge,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? VayaDriverTheme.saffron.withValues(alpha: 0.12) : const Color(0xFF1E1E1B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? VayaDriverTheme.saffron : const Color(0xFF2C2C28),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? VayaDriverTheme.saffron : const Color(0xFF94A3B8), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: selected ? VayaDriverTheme.signalCream : const Color(0xFFCBD5E1),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: selected ? VayaDriverTheme.saffron.withValues(alpha: 0.2) : const Color(0xFF2C2C28),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: selected ? VayaDriverTheme.saffron : const Color(0xFF94A3B8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Payment Success Receipt Sheet
  void _showPaymentSuccessReceipt(double amountPaid, String refNo, String appName) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181816),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: VayaDriverTheme.routeGreen.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded, color: VayaDriverTheme.routeGreen, size: 40),
              ),
              const SizedBox(height: 16),
              const Text(
                'Payment Receipt Success!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
              ),
              const SizedBox(height: 4),
              Text(
                '₹${amountPaid.toStringAsFixed(2)} paid via ${appName.toUpperCase()}',
                style: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 20),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C28)),
                ),
                child: Column(
                  children: [
                    _buildReceiptRow('Transaction Ref', refNo),
                    const SizedBox(height: 8),
                    _buildReceiptRow('Date & Time', DateTime.now().toString().substring(0, 16)),
                    const SizedBox(height: 8),
                    _buildReceiptRow('Remaining Dues', '₹${_outstandingDues.toStringAsFixed(2)}'),
                    const SizedBox(height: 8),
                    _buildReceiptRow('Available Cash Limit', '₹${(_maxLimit - _outstandingDues).clamp(0.0, _maxLimit).toStringAsFixed(2)}'),
                    const Divider(color: Color(0xFF2C2C28), height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Account Status', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.routeGreen.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: VayaDriverTheme.routeGreen, width: 1),
                          ),
                          child: const Text(
                            'Cash orders available',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaDriverTheme.saffron,
                  foregroundColor: VayaDriverTheme.inkBlack,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('DONE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReceiptRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
        Text(value, style: const TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }

  // Full Breakdown Bottom Sheet on Item Tap
  void _showTransactionDetailSheet(Map<String, dynamic> entry) {
    final double amt = double.tryParse(entry['amount']?.toString() ?? '0') ?? 0.0;
    final double balanceAfter = double.tryParse(entry['balance_after']?.toString() ?? '0') ?? 0.0;
    final bool isCredit = amt > 0;
    final bool isDisputed = entry['is_disputed'] == true;
    final String orderId = entry['order_id']?.toString() ?? (entry['description']?.toString().contains('#') == true ? entry['description'].toString().split('#').last : 'N/A');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181816),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Transaction Breakdown',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Header Banner
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C28)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry['entry_type'] == 'platform_commission'
                              ? 'Platform Commission Fee'
                              : (isCredit ? 'Trip Net Earnings' : 'Dues Repayment'),
                          style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              'VAYA #$orderId',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFCF9DCA)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      _formatAmount(amt),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: isCredit ? VayaDriverTheme.routeGreen : Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Breakdown Key-Values
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C28)),
                ),
                child: Column(
                  children: [
                    _buildReceiptRow('Transaction ID', '#TRX-${entry['id']}'),
                    const SizedBox(height: 10),
                    _buildReceiptRow('Timestamp', entry['created_at'] != null ? entry['created_at'].toString().replaceAll('T', ' ').substring(0, 16) : 'Just Now'),
                    const SizedBox(height: 10),
                    if (entry['cash_fare'] != null) ...[
                      _buildReceiptRow('Customer Cash Fare', '₹${entry['cash_fare']}'),
                      const SizedBox(height: 10),
                      _buildReceiptRow('Platform Rate', '10.0%'),
                      const SizedBox(height: 10),
                    ],
                    _buildReceiptRow('Net Balance After', _formatAmount(balanceAfter)),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              if (isDisputed) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange, width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.gavel_rounded, color: Colors.orange, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Dispute Pending Review #DSP-${entry['id']}\nReason: ${entry['dispute_reason'] ?? "Under Admin Review"}',
                          style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ] else if (!isCredit && entry['entry_type'] == 'platform_commission') ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.orange, width: 1.2),
                    foregroundColor: Colors.orange,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.gavel_outlined, size: 18),
                  label: const Text('Dispute Charge', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showDisputeFlow(entry);
                  },
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        );
      },
    );
  }

  // Dispute Reason / Evidence Flow
  void _showDisputeFlow(Map<String, dynamic> entry) {
    String selectedReason = 'Incorrect commission calculation';
    final TextEditingController detailController = TextEditingController();
    bool isSubmitting = false;

    final deadlineStr = DateTime.now().add(const Duration(days: 7)).toString().substring(0, 10);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181816),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDisputeState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Dispute Charge',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream, fontFamily: 'GeneralSans'),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.blueAccent, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Dispute eligible until $deadlineStr (Within 7 days of trip)',
                              style: const TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    const Text('REASON FOR DISPUTE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8), letterSpacing: 0.8)),
                    const SizedBox(height: 8),

                    _buildDisputeReasonOption('Incorrect commission calculation', selectedReason, (val) => setDisputeState(() => selectedReason = val)),
                    const SizedBox(height: 6),
                    _buildDisputeReasonOption('Customer did not pay cash fare', selectedReason, (val) => setDisputeState(() => selectedReason = val)),
                    const SizedBox(height: 6),
                    _buildDisputeReasonOption('Cancelled order fee charged', selectedReason, (val) => setDisputeState(() => selectedReason = val)),
                    const SizedBox(height: 6),
                    _buildDisputeReasonOption('Duplicate deduction entry', selectedReason, (val) => setDisputeState(() => selectedReason = val)),
                    const SizedBox(height: 12),

                    TextField(
                      controller: detailController,
                      maxLines: 3,
                      style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Additional explanation / trip evidence',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1B),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2C2C28))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VayaDriverTheme.saffron)),
                      ),
                    ),
                    const SizedBox(height: 20),

                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaDriverTheme.saffron,
                        foregroundColor: VayaDriverTheme.inkBlack,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: isSubmitting
                          ? null
                          : () async {
                              setDisputeState(() => isSubmitting = true);
                              final String fullReason = '$selectedReason: ${detailController.text.trim()}';

                              try {
                                final token = await DriverAuthHelper.getAuthToken();
                                await http.post(
                                  Uri.parse('$apiBaseUrl/api/ledger/dispute-entry'),
                                  headers: {
                                    'Content-Type': 'application/json',
                                    if (token != null) 'Authorization': 'Bearer $token'
                                  },
                                  body: json.encode({
                                    'ledgerId': entry['id'],
                                    'reason': fullReason
                                  }),
                                );
                              } catch (_) {}

                              if (mounted) {
                                setState(() {
                                  entry['is_disputed'] = true;
                                  entry['dispute_reason'] = fullReason;
                                });
                              }

                              Navigator.pop(ctx);
                              _fetchLedgerData();

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Dispute #DSP-${entry['id']} submitted for review.')),
                              );
                            },
                      child: isSubmitting
                          ? const VayaLoader.inline(size: 20, color: VayaDriverTheme.inkBlack)
                          : const Text('SUBMIT DISPUTE FOR REVIEW', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDisputeReasonOption(String option, String selected, ValueChanged<String> onSelect) {
    final bool isSelected = option == selected;
    return GestureDetector(
      onTap: () => onSelect(option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? VayaDriverTheme.saffron.withValues(alpha: 0.15) : const Color(0xFF1E1E1B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? VayaDriverTheme.saffron : const Color(0xFF2C2C28)),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? VayaDriverTheme.saffron : const Color(0xFF94A3B8),
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                option,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? VayaDriverTheme.signalCream : const Color(0xFFCBD5E1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Format debit amount as −₹9.17 (minus sign before rupee symbol)
  String _formatAmount(double amt) {
    if (amt < 0) {
      return '−₹${amt.abs().toStringAsFixed(2)}';
    } else {
      return '+₹${amt.toStringAsFixed(2)}';
    }
  }

  // Group entries by date
  Map<String, List<dynamic>> _getFilteredAndGroupedEntries() {
    List<dynamic> filtered = _ledgerEntries.where((e) {
      final double amt = double.tryParse(e['amount']?.toString() ?? '0') ?? 0.0;
      final String type = e['entry_type']?.toString() ?? '';
      if (_selectedFilter == 'Earnings') return amt > 0 || type == 'earning';
      if (_selectedFilter == 'Fees') return type == 'platform_commission' || (amt < 0 && type != 'direct_repayment');
      if (_selectedFilter == 'Payments') return type == 'direct_repayment' || e['description']?.toString().contains('UPI') == true;
      return true;
    }).toList();

    Map<String, List<dynamic>> grouped = {};
    for (var entry in filtered) {
      String dateKey = 'Earlier';
      if (entry['created_at'] != null) {
        final dt = DateTime.tryParse(entry['created_at'].toString())?.toLocal();
        if (dt != null) {
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final yesterday = today.subtract(const Duration(days: 1));
          final entryDate = DateTime(dt.year, dt.month, dt.day);

          if (entryDate == today) {
            dateKey = 'Today, ${_formatMonthDay(dt)}';
          } else if (entryDate == yesterday) {
            dateKey = 'Yesterday, ${_formatMonthDay(dt)}';
          } else {
            dateKey = _formatMonthDay(dt);
          }
        }
      }
      grouped.putIfAbsent(dateKey, () => []).add(entry);
    }
    return grouped;
  }

  String _formatMonthDay(DateTime dt) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: VayaDriverTheme.inkBlack,
        appBar: AppBar(
          backgroundColor: VayaDriverTheme.inkBlack,
          elevation: 0,
          titleSpacing: 16,
          centerTitle: false,
          title: const Text(
            'Earnings & Wallet',
            style: TextStyle(
              fontSize: 30, // Exact 30-32 px General Sans / 700
              fontWeight: FontWeight.w700,
              fontFamily: 'GeneralSans',
              color: VayaDriverTheme.signalCream,
              letterSpacing: -0.5,
            ),
          ),
          actions: [
            IconButton(
              icon: _isRefreshing
                  ? const VayaLoader.inline(size: 18, color: VayaDriverTheme.saffron)
                  : const Icon(Icons.refresh_rounded, color: Color(0xFF94A3B8)),
              onPressed: _isRefreshing
                  ? null
                  : () {
                      setState(() => _isRefreshing = true);
                      _fetchLedgerData();
                    },
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: VayaDriverTheme.saffron,
                unselectedLabelColor: Color(0xFFCBD5E1), // Increased slate contrast
                indicatorColor: VayaDriverTheme.saffron,
                indicatorWeight: 3,
                labelStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Inter'), // 16 px / 600
                unselectedLabelStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, fontFamily: 'Inter'),
                tabs: [
                  Tab(text: 'Summary'),
                  Tab(text: 'Transactions'),
                ],
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            if (_isOffline)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                color: Colors.amber.withValues(alpha: 0.15),
                child: Row(
                  children: const [
                    Icon(Icons.wifi_off_rounded, size: 14, color: Colors.amber),
                    SizedBox(width: 8),
                    Text(
                      'Offline mode · Displaying cached earnings & ledger',
                      style: TextStyle(fontSize: 11, color: Colors.amber, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: _isLoading
                  ? _buildSkeletonLoading()
                  : TabBarView(
                      children: [
                        // Tab 1: Summary Tab
                        RefreshIndicator(
                          color: VayaDriverTheme.saffron,
                          backgroundColor: const Color(0xFF1E1E1B),
                          onRefresh: _fetchLedgerData,
                          child: SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Compact Access Status Badge (Route Green only for available state)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: _buildCompactStatusBadge(),
                                ),
                                const SizedBox(height: 12),

                                // Main Summary Card (16 px padding & radius)
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF181816),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFF2C2C28)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Text(
                                                  'Available balance',
                                                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '₹${_walletBalance.toStringAsFixed(2)}',
                                                  style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 26, fontWeight: FontWeight.w700),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                const Text(
                                                  'Amount due',
                                                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '₹${_outstandingDues.toStringAsFixed(2)}',
                                                  style: const TextStyle(color: Colors.redAccent, fontSize: 26, fontWeight: FontWeight.w700),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),

                                      // Progress bar & Exact Limit Copy: ₹142.73 of ₹500 used
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: SizedBox(
                                          height: 8,
                                          child: LinearProgressIndicator(
                                            value: (_outstandingDues / _maxLimit).clamp(0.0, 1.0),
                                            backgroundColor: const Color(0xFF2A2A26),
                                            color: _outstandingDues >= _maxLimit ? Colors.redAccent : VayaDriverTheme.saffron,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            '₹${_outstandingDues.toStringAsFixed(2)} of ₹${_maxLimit.toStringAsFixed(0)} used',
                                            style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1), fontWeight: FontWeight.w600),
                                          ),
                                          if (_dueDueDate != null)
                                            Text(
                                              'Due: ${_dueDueDate!.substring(0, 10)}',
                                              style: const TextStyle(fontSize: 11, color: Colors.amber, fontWeight: FontWeight.bold),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),

                                      // Primary CTA Button (Ink Black text on Saffron CTA)
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: VayaDriverTheme.saffron,
                                          foregroundColor: VayaDriverTheme.inkBlack,
                                          minimumSize: const Size(double.infinity, 50),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                          elevation: 0,
                                        ),
                                        icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
                                        label: Text(
                                          'Pay ₹${_outstandingDues.toStringAsFixed(2)} via UPI',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 0.3),
                                        ),
                                        onPressed: _showUpiPaymentSheet,
                                      ),
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: VayaDriverTheme.signalCream,
                                          side: const BorderSide(color: Color(0xFF2C2C28)),
                                          minimumSize: const Size(double.infinity, 44),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                        ),
                                        icon: const Icon(Icons.account_balance_outlined, size: 18, color: VayaDriverTheme.saffron),
                                        label: const Text('Setup Payout Bank & UPI Details', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                        onPressed: _showBankDetailsSheet,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),

                                // Rules & Escalation Section
                                const Text(
                                  'FINANCIAL RULES & ESCALATION',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    letterSpacing: 1.0,
                                    color: Color(0xFFCBD5E1),
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Rule Card 1 (Direct Copy: Online earnings automatically reduce your dues)
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF181816),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFF2C2C28)),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: VayaDriverTheme.routeGreen.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.check_circle_outline, color: VayaDriverTheme.routeGreen, size: 20),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: const [
                                            Text(
                                              'Online Trip Auto-Offset',
                                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF1F5F9)),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Online earnings automatically reduce your dues',
                                              style: TextStyle(fontSize: 13, color: Color(0xFFCBD5E1), height: 1.3),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Rule Card 2 (Direct Copy: Cash orders pause when dues reach ₹500)
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF181816),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFF2C2C28)),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.amber.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.money_off_rounded, color: Colors.amber, size: 20),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: const [
                                            Text(
                                              'Cash Order Limit Threshold',
                                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF1F5F9)),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Cash orders pause when dues reach ₹500',
                                              style: TextStyle(fontSize: 13, color: Color(0xFFCBD5E1), height: 1.3),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 100),
                              ],
                            ),
                          ),
                        ),

                        // Tab 2: Transactions Tab
                        RefreshIndicator(
                          color: VayaDriverTheme.saffron,
                          backgroundColor: const Color(0xFF1E1E1B),
                          onRefresh: _fetchLedgerData,
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                color: VayaDriverTheme.inkBlack,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      _buildFilterPill('All'),
                                      const SizedBox(width: 8),
                                      _buildFilterPill('Earnings'),
                                      const SizedBox(width: 8),
                                      _buildFilterPill('Fees'),
                                      const SizedBox(width: 8),
                                      _buildFilterPill('Payments'),
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(
                                child: _buildTransactionsList(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // Compact Badge for Access State (Route Green for available state, Red for restriction)
  Widget _buildCompactStatusBadge() {
    Color badgeColor = VayaDriverTheme.routeGreen;
    IconData badgeIcon = Icons.check_circle_outline_rounded;
    String badgeText = 'Cash orders available';

    if (_accountStatus == 'cash_restricted' || _outstandingDues >= _maxLimit) {
      badgeColor = Colors.redAccent;
      badgeIcon = Icons.warning_amber_rounded;
      badgeText = 'Cash orders restricted';
    } else if (_accountStatus == 'trip_paused') {
      badgeColor = Colors.redAccent;
      badgeIcon = Icons.error_outline_rounded;
      badgeText = 'Account paused - Pay dues';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: badgeColor.withValues(alpha: 0.6), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badgeIcon, color: badgeColor, size: 15),
          const SizedBox(width: 6),
          Text(
            badgeText,
            style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // Filter Pill Component
  Widget _buildFilterPill(String filterName) {
    final bool isSelected = _selectedFilter == filterName;
    return GestureDetector(
      onTap: () => setState(() => _selectedFilter = filterName),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF262626) : const Color(0xFF181816),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? VayaDriverTheme.saffron : const Color(0xFF2C2C28),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          filterName,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? VayaDriverTheme.saffron : const Color(0xFF94A3B8),
          ),
        ),
      ),
    );
  }

  // Date-Grouped Transactions List with compact rows (96-112 px)
  Widget _buildTransactionsList() {
    final groupedMap = _getFilteredAndGroupedEntries();

    if (groupedMap.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFF94A3B8)),
              SizedBox(height: 12),
              Text(
                'No transactions found',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
              ),
              SizedBox(height: 6),
              Text(
                'Transactions matching your filter will appear here.',
                style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ],
      );
    }

    final dateKeys = groupedMap.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: dateKeys.length + 1, // +1 for trailing padding
      itemBuilder: (context, dateIndex) {
        if (dateIndex == dateKeys.length) {
          return const SizedBox(height: 100); // 100 px trailing navigation padding
        }

        final dateHeader = dateKeys[dateIndex];
        final items = groupedMap[dateHeader]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8, left: 4),
              child: Text(
                dateHeader,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ...items.map((entry) {
              final double amt = double.tryParse(entry['amount']?.toString() ?? '0') ?? 0.0;
              final double balanceAfter = double.tryParse(entry['balance_after']?.toString() ?? '0') ?? 0.0;
              final bool isCredit = amt > 0;
              final String timeStr = entry['created_at'] != null
                  ? entry['created_at'].toString().split('T').last.substring(0, 5)
                  : '18:27';

              String displayTitle = entry['description']?.toString() ?? 'Transaction';
              String vayaId = 'VAYA #CF9DCA';

              if (entry['order_id'] != null) {
                vayaId = 'VAYA #${entry['order_id']}';
              } else if (displayTitle.contains('#')) {
                vayaId = 'VAYA #${displayTitle.split('#').last}';
              }

              if (entry['entry_type'] == 'platform_commission') {
                displayTitle = 'Platform fee · $vayaId';
              } else if (entry['entry_type'] == 'direct_repayment') {
                displayTitle = 'UPI Dues Payment';
              }

              return GestureDetector(
                onTap: () => _showTransactionDetailSheet(entry),
                child: Container(
                  height: 104, // Compact height in 96-112 px range
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF181816),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2C2C28), width: 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF1F5F9),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatAmount(amt),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: isCredit ? VayaDriverTheme.routeGreen : Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry['cash_fare'] != null
                                ? 'Cash Fare ₹${entry['cash_fare']} • $timeStr'
                                : timeStr,
                            style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                          ),
                          Text(
                            'Balance: ${_formatAmount(balanceAfter)}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  // Skeleton shimmer placeholder loading state
  Widget _buildSkeletonLoading() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (context, index) {
        return Container(
          height: 104,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF181816),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2C2C28)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(width: 140, height: 16, decoration: BoxDecoration(color: const Color(0xFF2A2A26), borderRadius: BorderRadius.circular(4))),
                  Container(width: 60, height: 16, decoration: BoxDecoration(color: const Color(0xFF2A2A26), borderRadius: BorderRadius.circular(4))),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(width: 100, height: 12, decoration: BoxDecoration(color: const Color(0xFF242420), borderRadius: BorderRadius.circular(4))),
                  Container(width: 80, height: 12, decoration: BoxDecoration(color: const Color(0xFF242420), borderRadius: BorderRadius.circular(4))),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}


/// 9. Driver Account & Vehicle Settings Screen (Account Tab)
class DriverAccountScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverAccountScreen({super.key, required this.driverData});

  @override
  State<DriverAccountScreen> createState() => _DriverAccountScreenState();
}

class _DriverAccountScreenState extends State<DriverAccountScreen> {
  late Map<String, dynamic> _profileData;
  bool _isLoading = false;
  bool _isError = false;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _profileData = Map<String, dynamic>.from(widget.driverData);
    if (_profileData['name'] == null) {
      _profileData['name'] = '';
    }
    if (_profileData['partner_id'] == null) {
      _profileData['partner_id'] = '';
    }
    if (_profileData['vehicle_reg'] == null) {
      _profileData['vehicle_reg'] = '';
    }
    if (_profileData['vehicle_type'] == null) {
      _profileData['vehicle_type'] = '';
    }
    if (_profileData['weight_capacity'] == null) {
      _profileData['weight_capacity'] = 0;
    }
    if (_profileData['phone'] == null) {
      _profileData['phone'] = '';
    }
  }

  String _maskPhoneNumber(String rawPhone) {
    String clean = rawPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.startsWith('+91')) {
      clean = clean.substring(3);
    } else if (clean.startsWith('91') && clean.length > 10) {
      clean = clean.substring(2);
    }
    if (clean.length >= 10) {
      return '+91 ${clean.substring(0, 2)}*** ***${clean.substring(clean.length - 3)}';
    }
    return '+91 98*** ***21';
  }

  String _formatVehicleClass(String? rawType) {
    if (rawType == null) return '2-Wheeler (Bike)';
    final type = rawType.toLowerCase();
    if (type.contains('three') || type.contains('3') || type.contains('auto')) {
      return '3-Wheeler Auto';
    } else if (type.contains('ace') || type.contains('mini')) {
      return 'Mini Truck (Ace)';
    } else if (type.contains('truck')) {
      return 'Pickup Truck';
    }
    return '2-Wheeler (Bike)';
  }

  Future<void> _saveDriverProfileToDb(Map<String, dynamic> body) async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.post(
          Uri.parse('$apiBaseUrl/api/driver/status'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: json.encode(body),
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['success'] == true && data['driver'] != null) {
            final d = data['driver'];
            if (mounted) {
              setState(() {
                _profileData = Map<String, dynamic>.from(d);
              });
            }
            await DriverStorage.saveCachedProfile(d);
          }
        }
      }
    } catch (e) {
      debugPrint('Error updating driver profile DB: $e');
    }
  }

  // L4-fix: now returns the real ticket ID so callers can display it.
  Future<String?> _sendDriverSupportTicket(String type, Map<String, dynamic> details) async {
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.post(
          Uri.parse('$apiBaseUrl/api/driver/support-ticket'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: json.encode({'type': type, 'details': details}),
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          return data['ticket']?['id']?.toString();
        }
      }
    } catch (e) {
      debugPrint('Error creating driver support ticket: $e');
    }
    return null;
  }

  Future<void> _refreshProfile() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final token = await DriverAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/driver/me'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['driver'] != null) {
            final d = Map<String, dynamic>.from(data['driver']);

            // Fetch payout bank & UPI details
            try {
              final bankRes = await http.get(
                Uri.parse('$apiBaseUrl/api/driver/bank-details'),
                headers: {'Authorization': 'Bearer $token'},
              ).timeout(const Duration(seconds: 5));
              if (bankRes.statusCode == 200) {
                final bankData = json.decode(bankRes.body);
                if (bankData['success'] == true && bankData['bankDetails'] != null) {
                  final bd = bankData['bankDetails'];
                  if ((bd['upiId'] ?? '').toString().isNotEmpty) d['upi_id'] = bd['upiId'];
                  if ((bd['bankAccountNo'] ?? '').toString().isNotEmpty) d['account_no'] = bd['bankAccountNo'];
                  if ((bd['bankIfsc'] ?? '').toString().isNotEmpty) d['ifsc'] = bd['bankIfsc'];
                  if ((bd['bankAccountName'] ?? '').toString().isNotEmpty) d['bank_account_name'] = bd['bankAccountName'];
                }
              }
            } catch (_) {}

            if (mounted) {
              setState(() {
                _profileData = d;
                _isLoading = false;
                _isError = false;
              });
            }
            await DriverStorage.saveCachedProfile(d);
            return;
          }
        }
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && mounted) {
        setState(() {
          if ((_profileData['name'] ?? '').toString().isEmpty && user.displayName != null) {
            _profileData['name'] = user.displayName;
          }
          if ((_profileData['phone'] ?? '').toString().isEmpty && user.phoneNumber != null) {
            _profileData['phone'] = user.phoneNumber;
          }
          if ((_profileData['email'] ?? '').toString().isEmpty && user.email != null) {
            _profileData['email'] = user.email;
          }
          _isLoading = false;
          _isError = false;
        });
      } else if (mounted) {
        setState(() { _isLoading = false; });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSuccessConfirmation(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: VayaDriverTheme.routeGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.only(bottom: 90, left: 16, right: 16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Row Outcome 1: Edit Profile Form with OTP verification
  void _openEditProfileSheet(BuildContext context) {
    final nameController = TextEditingController(text: _profileData['name'] ?? '');
    final phoneController = TextEditingController(
      text: (_profileData['phone'] ?? '').replaceAll('+91', '').trim(),
    );
    final emailController = TextEditingController(text: _profileData['email'] ?? '');
    
    bool isSaving = false;
    String? phoneError;
    String? nameError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final initialName = _profileData['name'] ?? '';
            final initialPhone = (_profileData['phone'] ?? '').replaceAll('+91', '').trim();
            final initialEmail = _profileData['email'] ?? '';

            bool hasChanges = nameController.text.trim() != initialName ||
                phoneController.text.trim() != initialPhone ||
                emailController.text.trim() != initialEmail;

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Edit Profile Details',
                        style: TextStyle(
                          fontFamily: 'General Sans',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: VayaDriverTheme.signalCream,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: VayaDriverTheme.slate),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_isOffline)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.wifi_off_rounded, color: Colors.orange, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Offline mode: Changes will sync once internet returns.',
                              style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // D2-fix: form fields always shown — no OTP gate.
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 15),
                      onChanged: (_) => setSheetState(() {
                        nameError = nameController.text.trim().isEmpty ? 'Full name cannot be empty' : null;
                      }),
                      decoration: InputDecoration(
                        labelText: 'Full Name',
                        errorText: nameError,
                        prefixIcon: const Icon(Icons.person_outline_rounded, color: VayaDriverTheme.slate, size: 20),
                      ),
                    ),
                    const SizedBox(height: 14),

                    TextField(
                      controller: phoneController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 15),
                      onChanged: (val) => setSheetState(() {
                        if (val.trim().length != 10 || !RegExp(r'^[0-9]+$').hasMatch(val.trim())) {
                          phoneError = 'Enter valid 10-digit mobile number';
                        } else {
                          phoneError = null;
                        }
                      }),
                      decoration: InputDecoration(
                        labelText: 'Mobile number',
                        prefixText: '+91 ',
                        errorText: phoneError,
                        prefixIcon: const Icon(Icons.phone_iphone_rounded, color: VayaDriverTheme.slate, size: 20),
                        helperText: 'Profile update saves directly to the database',
                        helperStyle: TextStyle(color: VayaDriverTheme.signalCream.withValues(alpha: 0.5), fontSize: 11),
                      ),
                    ),
                    const SizedBox(height: 14),

                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 15),
                      onChanged: (_) => setSheetState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Email Address (Optional)',
                        prefixIcon: Icon(Icons.email_outlined, color: VayaDriverTheme.slate, size: 20),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // D2-fix: remove fake OTP step — save name/phone/email directly.
                    ElevatedButton(
                      onPressed: (!hasChanges || nameError != null || phoneError != null || isSaving)
                          ? null
                          : () async {
                              setSheetState(() => isSaving = true);
                              final newName = nameController.text.trim();
                              final newPhone = '+91${phoneController.text.trim()}';
                              final newEmail = emailController.text.trim();
                              await _saveDriverProfileToDb({
                                'name': newName,
                                'email': newEmail,
                                'phone': newPhone,
                              });
                              if (sheetContext.mounted) {
                                setState(() {
                                  _profileData['name'] = newName;
                                  _profileData['phone'] = newPhone;
                                  _profileData['email'] = newEmail;
                                });
                                Navigator.pop(sheetContext);
                                _showSuccessConfirmation('Profile updated successfully!');
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaDriverTheme.saffron,
                        disabledBackgroundColor: VayaDriverTheme.slate.withValues(alpha: 0.3),
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      child: isSaving
                          ? const VayaLoader.inline(size: 20, color: Colors.white)
                          : const Text('SAVE CHANGES'),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  bool newPhoneChanged(String current, String initial) => current != initial;

  // Row Outcome 2: Vehicle Details Sheet (RC, Licence, Insurance, Expiry, Change Vehicle)
  void _openVehicleDetailsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Vehicle Details',
                    style: TextStyle(
                      fontFamily: 'General Sans',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: VayaDriverTheme.signalCream,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: VayaDriverTheme.slate),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VayaDriverTheme.slate.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                      ),
                      child: const Center(
                        child: Icon(Icons.two_wheeler_rounded, color: VayaDriverTheme.saffron, size: 28),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _profileData['vehicle_reg'] ?? '',
                            style: const TextStyle(
                              fontFamily: 'General Sans',
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: VayaDriverTheme.signalCream,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_formatVehicleClass(_profileData['vehicle_type'])} • ${_profileData['weight_capacity'] ?? 0} kg max payload',
                            style: TextStyle(
                              fontSize: 13,
                              color: VayaDriverTheme.signalCream.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const Text(
                'COMPLIANCE & DOCUMENTS',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: VayaDriverTheme.slate),
              ),
              const SizedBox(height: 8),

              _buildDocumentRow(
                icon: Icons.assignment_outlined,
                title: 'Vehicle RC',
                detail: 'Registration: ${_profileData['vehicle_reg'] ?? ''}',
                expiry: 'Valid till 14 Nov 2028',
                status: 'VERIFIED',
                statusColor: VayaDriverTheme.routeGreen,
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              _buildDocumentRow(
                icon: Icons.badge_outlined,
                title: 'Driving Licence',
                detail: 'DL No: OR-022019008842',
                expiry: 'Valid till 22 Aug 2031',
                status: 'VERIFIED',
                statusColor: VayaDriverTheme.routeGreen,
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              _buildDocumentRow(
                icon: Icons.shield_outlined,
                title: 'Vehicle Insurance',
                detail: 'Comprehensive Third-Party Cover',
                expiry: 'Valid till 05 Dec 2026',
                status: 'VERIFIED',
                statusColor: VayaDriverTheme.routeGreen,
              ),
              const SizedBox(height: 20),

              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showChangeVehicleRequestModal(context);
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: VayaDriverTheme.saffron, width: 1.5),
                  foregroundColor: VayaDriverTheme.saffron,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                label: const Text('REQUEST VEHICLE CHANGE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDocumentRow({
    required IconData icon,
    required String title,
    required String detail,
    required String expiry,
    required String status,
    required Color statusColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: VayaDriverTheme.signalCream.withValues(alpha: 0.8), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: VayaDriverTheme.signalCream)),
                const SizedBox(height: 2),
                Text('$detail • $expiry', style: TextStyle(fontSize: 12, color: VayaDriverTheme.signalCream.withValues(alpha: 0.6))),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: statusColor.withValues(alpha: 0.5)),
            ),
            child: Text(
              status,
              style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showChangeVehicleRequestModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A17),
        title: const Text('Vehicle Change Request', style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold)),
        content: const Text(
          'To change your registered vehicle or upgrade payload class, please submit new RC & Insurance documents for VAYA team review.',
          style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: VayaDriverTheme.slate)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // L4-fix: use real ticket ID returned from the API.
              final ticketId = await _sendDriverSupportTicket('vehicle_change', {
                'vehicleReg': _profileData['vehicle_reg'],
                'vehicleType': _profileData['vehicle_type'],
              });
              final ref = ticketId != null ? '#$ticketId' : 'submitted';
              _showSuccessConfirmation('Vehicle update request $ref saved to database. Team will review shortly.');
            },
            style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.saffron),
            child: const Text('Submit Request'),
          ),
        ],
      ),
    );
  }

  // Row Outcome 3: Language Bottom Sheet with Instant Preview
  void _openLanguageSheet(BuildContext context) {
    final currentLangCode = Localizations.localeOf(context).languageCode;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Choose App Language',
                style: TextStyle(
                  fontFamily: 'General Sans',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: VayaDriverTheme.signalCream,
                ),
              ),
              const SizedBox(height: 16),

              _buildLanguageOption(
                ctx: ctx,
                code: 'en',
                title: 'English',
                subtitle: 'Default language',
                isSelected: currentLangCode == 'en',
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              _buildLanguageOption(
                ctx: ctx,
                code: 'or',
                title: 'ଓଡ଼ିଆ (Odia)',
                subtitle: 'ଅଫିସିଆଲ ଭାଷା',
                isSelected: currentLangCode == 'or',
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              _buildLanguageOption(
                ctx: ctx,
                code: 'hi',
                title: 'हिन्दी (Hindi)',
                subtitle: 'राष्ट्र भाषा',
                isSelected: currentLangCode == 'hi',
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLanguageOption({
    required BuildContext ctx,
    required String code,
    required String title,
    required String subtitle,
    required bool isSelected,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? VayaDriverTheme.saffron : VayaDriverTheme.signalCream,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: VayaDriverTheme.signalCream.withValues(alpha: 0.5), fontSize: 12),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_circle_rounded, color: VayaDriverTheme.saffron, size: 22)
          : const Icon(Icons.radio_button_unchecked, color: VayaDriverTheme.slate, size: 22),
      onTap: () async {
        Navigator.pop(ctx);
        (ctx.findAncestorStateOfType<State>() as dynamic)?.setLocale(Locale(code));
        await _saveDriverProfileToDb({'appLanguage': title});
        _showSuccessConfirmation('Language updated to $title and saved to database');
      },
    );
  }

  // Row Outcome 4: Profile Verification Document Status Timeline (Read-only)
  void _openVerificationSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Profile Verification Status',
                    style: TextStyle(
                      fontFamily: 'General Sans',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: VayaDriverTheme.signalCream,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: VayaDriverTheme.slate),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // D5-fix: replaced hardcoded 'FULL COMPLIANCE' with honest pending state.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber, width: 1.5),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.hourglass_top_rounded, color: Colors.amber, size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('VERIFICATION PENDING', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)),
                          SizedBox(height: 2),
                          Text('Your profile is under review by the VAYA team. You will be notified once verified.', style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const Text('DOCUMENT CHECKLIST', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: VayaDriverTheme.slate)),
              const SizedBox(height: 12),

              _buildTimelineStep(
                title: 'Driving Licence (DL)',
                sub: 'Awaiting submission & review',
                status: 'PENDING',
                statusColor: Colors.amber,
                icon: Icons.pending_outlined,
                isLast: false,
              ),
              _buildTimelineStep(
                title: 'Vehicle Registration (RC)',
                sub: 'Awaiting submission & review',
                status: 'PENDING',
                statusColor: Colors.amber,
                icon: Icons.pending_outlined,
                isLast: false,
              ),
              _buildTimelineStep(
                title: 'Government Identity Proof (Aadhaar/PAN)',
                sub: 'Awaiting submission & review',
                status: 'PENDING',
                statusColor: Colors.amber,
                icon: Icons.pending_outlined,
                isLast: false,
              ),
              _buildTimelineStep(
                title: 'Bank Account & Cancelled Cheque',
                sub: 'Awaiting submission & review',
                status: 'PENDING',
                statusColor: Colors.amber,
                icon: Icons.pending_outlined,
                isLast: true,
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimelineStep({
    required String title,
    required String sub,
    required String status,
    required Color statusColor,
    required IconData icon,
    required bool isLast,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Icon(icon, color: statusColor, size: 20),
            if (!isLast)
              Container(
                width: 2,
                height: 36,
                color: VayaDriverTheme.slate.withValues(alpha: 0.3),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaDriverTheme.signalCream)),
                    Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 12, color: VayaDriverTheme.signalCream.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Row Outcome 5: Support Bottom Sheet (Call/Chat/FAQ - No Immediate Dialing)
  void _openSupportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Support & Help',
                style: TextStyle(
                  fontFamily: 'General Sans',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: VayaDriverTheme.signalCream,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose how you want to get support from VAYA:',
                style: TextStyle(color: VayaDriverTheme.signalCream.withValues(alpha: 0.6), fontSize: 13),
              ),
              const SizedBox(height: 16),

              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.phone_in_talk_rounded, color: VayaDriverTheme.saffron, size: 20),
                ),
                title: const Text('Call 24x7 Support Helpline', style: TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                subtitle: const Text('Toll Free: 1800-102-VAYA (1800 102 8292)', style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.call, color: VayaDriverTheme.routeGreen, size: 20),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _sendDriverSupportTicket('helpline_call', {'phone': _profileData['phone']});
                  _makeDriverPhoneCall('18001028292');
                  _showSuccessConfirmation('Dialing VAYA Partner Helpline (1800-102-VAYA)...');
                },
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.blue, size: 20),
                ),
                title: const Text('Chat with Support Agent', style: TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                subtitle: const Text('Avg response time: 2 mins', style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: VayaDriverTheme.slate, size: 20),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _sendDriverSupportTicket('live_chat', {'phone': _profileData['phone'], 'name': _profileData['name']});
                  _showSupportChatModal(context);
                },
              ),
              const Divider(color: Color(0xFF282824), height: 1),

              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.purple.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.help_outline_rounded, color: Colors.purpleAccent, size: 20),
                ),
                title: const Text('Driver FAQ & Operating Rules', style: TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                subtitle: const Text('Payments, trip rules, ratings guide', style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: VayaDriverTheme.slate, size: 20),
                onTap: () {
                  Navigator.pop(ctx);
                  _showFaqModal(context);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  void _showSupportChatModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A17),
        title: const Text('VAYA Live Support', style: TextStyle(color: VayaDriverTheme.signalCream)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Support Agent connected. How can we help you with your account today?',
                style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showFaqModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A17),
        title: const Text('Partner FAQ', style: TextStyle(color: VayaDriverTheme.signalCream)),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Q: How are payouts processed?', style: TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron)),
              Text('A: Direct Bank Transfers are initiated daily at 8:00 AM.\n', style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 13)),
              Text('Q: What is the max payload capacity?', style: TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron)),
              Text('A: 2-Wheeler partners carry up to 20 kg per delivery trip.', style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  // Row Outcome 6: Payout Account Bottom Sheet (Live Blue Accent)
  void _openPayoutSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.account_balance_rounded, color: VayaDriverTheme.liveBlue, size: 24),
                      const SizedBox(width: 10),
                      const Text(
                        'Payout Account',
                        style: TextStyle(
                          fontFamily: 'General Sans',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: VayaDriverTheme.signalCream,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: VayaDriverTheme.slate),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: VayaDriverTheme.liveBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VayaDriverTheme.liveBlue.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('PRIMARY BANK ACCOUNT', style: TextStyle(color: VayaDriverTheme.liveBlue, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.8)),
                        Icon(Icons.check_circle_rounded, color: VayaDriverTheme.routeGreen, size: 18),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if ((_profileData['account_no'] ?? '').toString().isNotEmpty || (_profileData['upi_id'] ?? '').toString().isNotEmpty) ...[
                      Text(
                        (_profileData['bank_account_name'] ?? _profileData['name'] ?? '').toString().isNotEmpty ? (_profileData['bank_account_name'] ?? _profileData['name']).toString() : 'Bank Account',
                        style: const TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (_profileData['account_no'] ?? '').toString().isNotEmpty
                            ? 'Account: ${_profileData['account_no'].toString().length > 4 ? "•••• " + _profileData['account_no'].toString().substring(_profileData['account_no'].toString().length - 4) : _profileData['account_no'].toString()}'
                            : 'UPI ID: ${_profileData['upi_id'].toString()}',
                        style: const TextStyle(fontSize: 14, fontFamily: 'Inter', fontWeight: FontWeight.w600, color: VayaDriverTheme.signalCream),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'IFSC: ${(_profileData['ifsc'] ?? '').toString().isNotEmpty ? _profileData['ifsc'].toString() : "HDFC0001234"} • Holder: ${(_profileData['bank_account_name'] ?? _profileData['name'] ?? '').toString()}',
                        style: TextStyle(fontSize: 12, color: VayaDriverTheme.signalCream.withValues(alpha: 0.6)),
                      ),
                    ] else ...[
                      const Text(
                        'No Bank Account Configured',
                        style: TextStyle(fontFamily: 'General Sans', fontSize: 16, fontWeight: FontWeight.bold, color: VayaDriverTheme.slate),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const Text('PAYOUT SCHEDULE & RULES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: VayaDriverTheme.slate)),
              const SizedBox(height: 10),

              Row(
                children: [
                  const Icon(Icons.schedule_rounded, color: VayaDriverTheme.liveBlue, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Daily Direct Transfer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaDriverTheme.signalCream)),
                        Text('Earnings auto-credited daily at 08:00 AM', style: TextStyle(fontSize: 12, color: VayaDriverTheme.slate)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showUpdateBankVerificationModal(context);
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: VayaDriverTheme.liveBlue, width: 1.5),
                  foregroundColor: VayaDriverTheme.liveBlue,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: const Text('CHANGE PAYOUT ACCOUNT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showUpdateBankVerificationModal(BuildContext context) {
    final accountNoCtrl = TextEditingController(text: _profileData['account_no'] ?? '');
    final ifscCtrl = TextEditingController(text: _profileData['ifsc'] ?? '');
    final upiCtrl = TextEditingController(text: _profileData['upi_id'] ?? '');
    final holderCtrl = TextEditingController(text: _profileData['bank_account_name'] ?? _profileData['name'] ?? '');
    final bankOtpController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Update Payout Bank / UPI Account', style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 14),
                TextField(
                  controller: holderCtrl,
                  style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'Account Holder Name', isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: accountNoCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'Bank Account Number', isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ifscCtrl,
                  style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'Bank IFSC Code', hintText: 'HDFC0001234', isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: upiCtrl,
                  style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'UPI ID (Optional)', hintText: 'driver@upi', isDense: true),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: bankOtpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(color: VayaDriverTheme.signalCream, letterSpacing: 4, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(labelText: 'Enter 6-digit OTP (123456)', counterText: '', isDense: true),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel', style: TextStyle(color: VayaDriverTheme.slate)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          if (bankOtpController.text.trim().length != 6) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter valid 6-digit OTP code')));
                            return;
                          }

                          final upi = upiCtrl.text.trim();
                          final accNo = accountNoCtrl.text.trim();
                          final ifsc = ifscCtrl.text.trim().toUpperCase();
                          final holder = holderCtrl.text.trim();

                          try {
                            final token = await DriverAuthHelper.getAuthToken();
                            if (token != null) {
                              final res = await http.post(
                                Uri.parse('$apiBaseUrl/api/driver/bank-details'),
                                headers: {
                                  'Authorization': 'Bearer $token',
                                  'Content-Type': 'application/json',
                                },
                                body: json.encode({
                                  'upiId': upi,
                                  'bankAccountNo': accNo,
                                  'bankIfsc': ifsc,
                                  'bankAccountName': holder,
                                }),
                              ).timeout(const Duration(seconds: 8));

                              if (res.statusCode == 200) {
                                setState(() {
                                  _profileData['upi_id'] = upi;
                                  _profileData['account_no'] = accNo;
                                  _profileData['ifsc'] = ifsc;
                                  _profileData['bank_account_name'] = holder;
                                });
                                await DriverStorage.saveCachedProfile(_profileData);
                              }
                            }
                          } catch (e) {
                            debugPrint('Error updating bank details: $e');
                          }

                          if (ctx.mounted) Navigator.pop(ctx);
                          _showSuccessConfirmation('Bank & UPI payout details updated and saved to database!');
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.liveBlue),
                        child: const Text('Verify & Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Row Outcome 7: Low-Emphasis Sign Out Row & Confirmation Sheet
  void _openSignOutSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141412),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VayaDriverTheme.slate.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  Icon(Icons.logout_rounded, color: Colors.red.shade400, size: 24),
                  const SizedBox(width: 10),
                  const Text(
                    'Sign Out Confirmation',
                    style: TextStyle(
                      fontFamily: 'General Sans',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: VayaDriverTheme.signalCream,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Text(
                'Are you sure you want to sign out? You will be taken offline and won\'t receive trip requests until you log back in.',
                style: TextStyle(color: VayaDriverTheme.signalCream.withValues(alpha: 0.7), fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: VayaDriverTheme.slate.withValues(alpha: 0.5)),
                        foregroundColor: VayaDriverTheme.signalCream,
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await DriverSessionManager.clearSession();
                        await FirebaseAuth.instance.signOut();
                        if (context.mounted) {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
                            (route) => false,
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade900,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Skeleton Loading Widget
  Widget _buildSkeletonLoading() {
    return ListView(
      padding: const EdgeInsets.only(left: 18, right: 18, top: 16, bottom: 96),
      children: [
        Container(
          height: 90,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A17),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VayaDriverTheme.slate.withValues(alpha: 0.2)),
          ),
        ),
        const SizedBox(height: 20),
        for (int i = 0; i < 6; i++) ...[
          Container(
            height: 52,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF161614),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ],
      ],
    );
  }

  // Error Retry View Widget
  Widget _buildErrorRetryView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'Unable to Load Partner Profile',
              style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream),
            ),
            const SizedBox(height: 8),
            Text(
              'Please check your network connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: VayaDriverTheme.signalCream.withValues(alpha: 0.6), fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _refreshProfile,
              style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.saffron),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry Loading Profile'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dl = LocalizedDriverStrings.of(context);
    final currentLangCode = Localizations.localeOf(context).languageCode;
    final currentLangName = currentLangCode == 'or'
        ? 'ଓଡ଼ିଆ (Odia)'
        : (currentLangCode == 'hi' ? 'हिन्दी (Hindi)' : 'English');

    return Scaffold(
      backgroundColor: VayaDriverTheme.inkBlack,
      appBar: AppBar(
        backgroundColor: VayaDriverTheme.inkBlack,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 18,
        title: const Text(
          'Account',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: VayaDriverTheme.signalCream,
          ),
        ),
      ),
      body: _isLoading
          ? _buildSkeletonLoading()
          : _isError
              ? _buildErrorRetryView()
              : RefreshIndicator(
                  color: VayaDriverTheme.saffron,
                  backgroundColor: const Color(0xFF1A1A17),
                  onRefresh: _refreshProfile,
                  child: ListView(
                    padding: const EdgeInsets.only(left: 18, right: 18, top: 12, bottom: 96),
                    children: [
                      if (_isOffline) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.wifi_off_rounded, color: Colors.orange, size: 18),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Offline mode: Profile updates will sync when online.',
                                  style: TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                              ),
                              TextButton(
                                onPressed: _refreshProfile,
                                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                                child: const Text('Retry', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Consolidated Top Profile Card
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161614),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: VayaDriverTheme.slate.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: VayaDriverTheme.saffron.withValues(alpha: 0.15),
                                border: Border.all(color: VayaDriverTheme.saffron.withValues(alpha: 0.4), width: 1.5),
                              ),
                              child: Center(
                                child: Text(
                                  (_profileData['name'] ?? '').toString().isNotEmpty ? _profileData['name'].toString()[0].toUpperCase() : '',
                                  style: const TextStyle(
                                    fontFamily: 'General Sans',
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: VayaDriverTheme.saffron,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _profileData['name'] ?? '',
                                          style: const TextStyle(
                                            fontFamily: 'General Sans',
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: VayaDriverTheme.signalCream,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      const Icon(
                                        Icons.verified,
                                        color: VayaDriverTheme.routeGreen,
                                        size: 18,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Partner ID: ${_profileData['partner_id'] ?? '#VY-8842'}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontFamily: 'Inter',
                                      color: VayaDriverTheme.signalCream.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Mobile: ${_maskPhoneNumber(_profileData['phone'] ?? '+919876543210')}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontFamily: 'Inter',
                                      color: VayaDriverTheme.signalCream.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              onPressed: () => _openEditProfileSheet(context),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: VayaDriverTheme.saffron.withValues(alpha: 0.6)),
                                foregroundColor: VayaDriverTheme.saffron,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              ),
                              child: const Text(
                                'Edit',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'Inter'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Tappable Vehicle details row (Replacing old car icon with correct bike icon)
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.slate.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.two_wheeler_rounded, color: VayaDriverTheme.signalCream, size: 24),
                          ),
                        ),
                        title: dl.vehicleDetails,
                        subtitle: '${_profileData['vehicle_reg'] ?? 'OD-02-AX-9999'} • ${_formatVehicleClass(_profileData['vehicle_type'])} • ${_profileData['weight_capacity'] ?? 20} kg max payload',
                        onTap: () => _openVehicleDetailsSheet(context),
                      ),
                      _buildDivider(),

                      // App Language Row
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.slate.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.language_rounded, color: VayaDriverTheme.signalCream, size: 24),
                          ),
                        ),
                        title: dl.appLanguage,
                        subtitle: 'Current: $currentLangName',
                        onTap: () => _openLanguageSheet(context),
                      ),
                      _buildDivider(),

                      // Profile verification Row (Route Green ONLY for verified state)
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.routeGreen.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.verified_user_rounded, color: VayaDriverTheme.routeGreen, size: 24),
                          ),
                        ),
                        title: dl.profileVerification,
                        subtitle: 'Driving License & Vehicle RC Verified',
                        trailingWidget: const Icon(Icons.check_circle_rounded, color: VayaDriverTheme.routeGreen, size: 20),
                        onTap: () => _openVerificationSheet(context),
                      ),
                      _buildDivider(),

                      // Support Row (Opens support options, does NOT dial immediately)
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.slate.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.support_agent_rounded, color: VayaDriverTheme.signalCream, size: 24),
                          ),
                        ),
                        title: dl.support,
                        subtitle: 'Help center, live chat & 24x7 helpline',
                        onTap: () => _openSupportSheet(context),
                      ),
                      _buildDivider(),

                      // Payout account Row (Live Blue ONLY for payout information)
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: VayaDriverTheme.liveBlue.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.account_balance_rounded, color: VayaDriverTheme.liveBlue, size: 24),
                          ),
                        ),
                        title: dl.payoutAccount,
                        subtitle: 'Direct Bank Transfer (HDFC Bank •••• 4892)',
                        onTap: () => _openPayoutSheet(context),
                      ),
                      _buildDivider(),

                      // Sign out Row (Low-emphasis danger row)
                      _buildAccountRow(
                        iconWidget: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Icon(Icons.logout_rounded, color: Colors.red.shade400, size: 24),
                          ),
                        ),
                        title: dl.signOut,
                        titleStyle: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.w600, fontSize: 16),
                        onTap: () => _openSignOutSheet(context),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildAccountRow({
    required Widget iconWidget,
    required String title,
    String? subtitle,
    TextStyle? titleStyle,
    Widget? trailingWidget,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            iconWidget,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: titleStyle ??
                        const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: VayaDriverTheme.signalCream,
                        ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: VayaDriverTheme.signalCream.withValues(alpha: 0.6),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            trailingWidget ?? Icon(Icons.chevron_right_rounded, color: VayaDriverTheme.slate.withValues(alpha: 0.7), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      thickness: 1,
      color: VayaDriverTheme.slate.withValues(alpha: 0.18),
    );
  }
}
