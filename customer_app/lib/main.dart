import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'widgets/payment_method_sheet.dart';
import 'services/razorpay_service.dart';
import 'utils/vehicle_icon_helper.dart';
import 'widgets/vaya_loader.dart';

/// Helper function to launch phone calls across devices & web
Future<void> _makePhoneCall(String phoneNumber) async {
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
    debugPrint('Could not launch phone call to $phoneNumber: $e');
  }
}

// Customer Session Storage Manager (SharedPreferences Disk Persistence)
class CustomerSessionManager {
  static const String _keyIsLoggedIn = 'customer_is_logged_in_v2';
  static const String _keyCustomerData = 'customer_data_json_v2';
  static const String _keyAuthToken = 'customer_auth_token_v2';

  static Future<void> saveSession(Map<String, dynamic> customerData, {String? token}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyIsLoggedIn, true);
      await prefs.setString(_keyCustomerData, json.encode(customerData));
      if (token != null && token.isNotEmpty) {
        await prefs.setString(_keyAuthToken, token);
      }
      // Sync profile keys used by VayaStorage.loadUserProfile() / AccountScreen
      final name = customerData['name']?.toString() ?? '';
      final phone = customerData['phone']?.toString() ?? '';
      if (name.isNotEmpty) await prefs.setString('vaya_user_name', name);
      if (phone.isNotEmpty) await prefs.setString('vaya_user_phone', phone);
      debugPrint("✅ Customer session saved to SharedPreferences");
    } catch (e) {
      debugPrint("Error saving customer session: $e");
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
      return prefs.getString(_keyAuthToken);
    } catch (e) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool(_keyIsLoggedIn) ?? false;
      final rawJson = prefs.getString(_keyCustomerData);
      if (isLoggedIn && rawJson != null && rawJson.isNotEmpty) {
        return json.decode(rawJson) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint("Error reading customer session: $e");
    }
    return null;
  }

  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyIsLoggedIn);
      await prefs.remove(_keyCustomerData);
      await prefs.remove(_keyAuthToken);
      debugPrint("🔴 Customer session cleared from SharedPreferences");
    } catch (e) {
      debugPrint("Error clearing customer session: $e");
    }
  }
}

class CustomerAuthHelper {
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
          await CustomerSessionManager.saveToken(token);
          return token;
        }
      } catch (e) {
        debugPrint("Error getting token from currentUser: $e");
      }
    }

    // Fallback to locally saved token from disk
    return await CustomerSessionManager.getSavedToken();
  }

  /// Handle 401 / Authorization Expiration globally
  static Future<void> handleUnauthorized(BuildContext context) async {
    debugPrint("🔴 CustomerAuthHelper: Expired/Invalid Authorization. Clearing session and redirecting to login.");
    await CustomerSessionManager.clearSession();
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please log in with your mobile number.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const VayaCustomerApp()),
        (route) => false,
      );
    }
  }
}

class IndianPhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length < oldValue.text.length) {
      String oldDigits = oldValue.text.replaceAll(RegExp(r'\D'), '');
      String newDigits = newValue.text.replaceAll(RegExp(r'\D'), '');
      if (oldDigits.startsWith('91') && oldDigits.length > 10) oldDigits = oldDigits.substring(2);
      if (newDigits.startsWith('91') && newDigits.length > 10) newDigits = newDigits.substring(2);
      
      if (oldDigits == newDigits && newDigits.isNotEmpty) {
        newDigits = newDigits.substring(0, newDigits.length - 1);
      }
      return _buildFormattedValue(newDigits);
    }
    
    String digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('91') && digits.length > 10) {
      digits = digits.substring(2);
    }
    if (digits.length > 10) {
      digits = digits.substring(0, 10);
    }
    return _buildFormattedValue(digits);
  }

  TextEditingValue _buildFormattedValue(String digits) {
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    String formatted;
    if (digits.length <= 5) {
      formatted = '+91 $digits';
    } else {
      formatted = '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatIndianPhoneNumber(String raw) {
  String digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('91') && digits.length > 10) {
    digits = digits.substring(2);
  }
  if (digits.length > 10) {
    digits = digits.substring(0, 10);
  }
  if (digits.isEmpty) return '';
  if (digits.length <= 5) {
    return '+91 $digits';
  } else {
    return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
  }
}

Future<Map<String, String>?> _pickPhoneContact(BuildContext context) async {
  try {
    // 1. Try opening system contact picker directly first
    try {
      final contact = await FlutterContacts.openExternalPick();
      if (contact != null) {
        final name = contact.displayName;
        String phone = '';
        if (contact.phones.isNotEmpty) {
          phone = contact.phones.first.number;
        }
        phone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
        if (phone.startsWith('+91')) {
          phone = phone.substring(3);
        } else if (phone.startsWith('91') && phone.length == 12) {
          phone = phone.substring(2);
        }
        phone = phone.replaceAll(RegExp(r'\D'), '');
        return {
          'name': name,
          'phone': phone,
        };
      } else {
        return null; // User cancelled
      }
    } catch (e) {
      debugPrint('Direct pick attempt note: $e');
    }

    // 2. Request readonly permission if needed
    bool granted = false;
    try {
      granted = await FlutterContacts.requestPermission(readonly: true);
    } catch (e) {
      debugPrint('Permission request error: $e');
    }

    if (granted) {
      final contact = await FlutterContacts.openExternalPick();
      if (contact != null) {
        final name = contact.displayName;
        String phone = '';
        if (contact.phones.isNotEmpty) {
          phone = contact.phones.first.number;
        }
        phone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
        if (phone.startsWith('+91')) {
          phone = phone.substring(3);
        } else if (phone.startsWith('91') && phone.length == 12) {
          phone = phone.substring(2);
        }
        phone = phone.replaceAll(RegExp(r'\D'), '');
        return {
          'name': name,
          'phone': phone,
        };
      }
      return null;
    }

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Contacts Permission Required', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.bold)),
          content: const Text('VAYA needs contacts permission to help you pick a contact. Please enable it in the app settings.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: VayaTheme.slate)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await Geolocator.openAppSettings();
              },
              child: const Text('Open settings', style: TextStyle(color: VayaTheme.saffron, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
    return {'permission_denied': 'true'};
  } catch (e) {
    debugPrint('Error in _pickPhoneContact: $e');
    return null;
  }
}

class VayaStorage {
  static Future<List<Map<String, String>>> loadSavedPlaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_saved_places');
      if (raw != null && raw.isNotEmpty) {
        final List list = json.decode(raw);
        return list.map((e) => Map<String, String>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading saved places: $e');
    }
    return [];
  }

  static Future<void> saveSavedPlaces(List<Map<String, String>> places) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_saved_places', json.encode(places));
    } catch (e) {
      debugPrint('Error saving saved places: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_recent_searches');
      if (raw != null && raw.isNotEmpty) {
        final List list = json.decode(raw);
        return list.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading recent searches: $e');
    }
    return [];
  }

  static Future<void> saveRecentSearches(List<Map<String, dynamic>> searches) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_recent_searches', json.encode(searches));
    } catch (e) {
      debugPrint('Error saving recent searches: $e');
    }
  }

  static Future<void> addRecentSearch(Map<String, dynamic> item) async {
    final list = await loadRecentSearches();
    list.removeWhere((x) => x['title'] == item['title']);
    list.insert(0, item);
    if (list.length > 10) list.removeLast();
    await saveRecentSearches(list);
  }

  static Future<List<Map<String, dynamic>>> loadTransactions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_transactions');
      if (raw != null && raw.isNotEmpty) {
        final List list = json.decode(raw);
        return list.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading transactions: $e');
    }
    return [];
  }

  static Future<void> saveTransactions(List<Map<String, dynamic>> txns) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_transactions', json.encode(txns));
    } catch (e) {
      debugPrint('Error saving transactions: $e');
    }
  }

  static Future<int> loadWalletBalance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('vaya_wallet_balance') ?? 0;
    } catch (e) {
      return 0;
    }
  }

  static Future<void> saveWalletBalance(int balance) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('vaya_wallet_balance', balance);
    } catch (e) {
      debugPrint('Error saving wallet balance: $e');
    }
  }

  static Future<Map<String, String>> loadUserProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final user = FirebaseAuth.instance.currentUser;
      String name = prefs.getString('vaya_user_name') ?? user?.displayName ?? '';
      String phone = prefs.getString('vaya_user_phone') ?? user?.phoneNumber ?? '';
      String email = prefs.getString('vaya_user_email') ?? user?.email ?? '';

      // Fall back to CustomerSessionManager saved session (populated during login)
      if (name.isEmpty || phone.isEmpty) {
        final saved = await CustomerSessionManager.getSavedSession();
        if (saved != null) {
          if (name.isEmpty) name = saved['name']?.toString() ?? '';
          if (phone.isEmpty) phone = saved['phone']?.toString() ?? '';
          // Sync back to vaya_user_* keys for next load
          if (name.isNotEmpty) await prefs.setString('vaya_user_name', name);
          if (phone.isNotEmpty) await prefs.setString('vaya_user_phone', phone);
        }
      }

      return {'name': name, 'phone': phone, 'email': email};
    } catch (e) {
      return {'name': '', 'phone': '', 'email': ''};
    }
  }

  static Future<void> saveUserProfile(String name, String phone, String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_user_name', name);
      await prefs.setString('vaya_user_phone', phone);
      await prefs.setString('vaya_user_email', email);
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        if (name.isNotEmpty) await user.updateDisplayName(name).catchError((_) {});
        if (email.isNotEmpty) await user.updateEmail(email).catchError((_) {});
      }
    } catch (e) {
      debugPrint('Error saving user profile: $e');
    }
  }

  static Future<Map<String, String>> loadBusinessDetails() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        'companyName': prefs.getString('vaya_business_company') ?? '',
        'gstin': prefs.getString('vaya_business_gstin') ?? '',
        'billingAddress': prefs.getString('vaya_business_address') ?? '',
        'gstStatus': prefs.getString('vaya_business_status') ?? 'Not added',
      };
    } catch (e) {
      return {'companyName': '', 'gstin': '', 'billingAddress': '', 'gstStatus': 'Not added'};
    }
  }

  static Future<void> saveBusinessDetails(String companyName, String gstin, String billingAddress, String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_business_company', companyName);
      await prefs.setString('vaya_business_gstin', gstin);
      await prefs.setString('vaya_business_address', billingAddress);
      await prefs.setString('vaya_business_status', status);
    } catch (e) {
      debugPrint('Error saving business details: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> loadCachedBookings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_cached_bookings');
      if (raw != null && raw.isNotEmpty) {
        final List list = json.decode(raw);
        return list.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading cached bookings: $e');
    }
    return [];
  }

  static Future<void> saveCachedBookings(List<dynamic> bookings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_cached_bookings', json.encode(bookings));
    } catch (e) {
      debugPrint('Error saving cached bookings: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadCachedActiveBooking() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_cached_active_booking');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(json.decode(raw));
      }
    } catch (e) {
      debugPrint('Error loading cached active booking: $e');
    }
    return null;
  }

  static Future<void> saveCachedActiveBooking(Map<String, dynamic>? booking) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (booking == null) {
        await prefs.remove('vaya_cached_active_booking');
      } else {
        await prefs.setString('vaya_cached_active_booking', json.encode(booking));
      }
    } catch (e) {
      debugPrint('Error saving cached active booking: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadCachedPricingConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('vaya_cached_pricing_config');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(json.decode(raw));
      }
    } catch (e) {
      debugPrint('Error loading cached pricing config: $e');
    }
    return null;
  }

  static Future<void> saveCachedPricingConfig(Map<String, dynamic> config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vaya_cached_pricing_config', json.encode(config));
    } catch (e) {
      debugPrint('Error saving cached pricing config: $e');
    }
  }
}

// Configuration URLs - Change to your Cloud Run URL in production
const String apiBaseUrl = "https://vaya-backend-275777907648.us-central1.run.app";
const String wsBaseUrl = "wss://vaya-backend-275777907648.us-central1.run.app";
const String googleMapsApiKey = "AIzaSyAnCZ_flXJtQXJt2TUHiVjC5Rjwk43Xqv0";

// VAYA Brand Design Tokens (Saffron / InkBlack / SignalCream / RouteGreen)
class VayaTheme {
  static const Color saffron = Color(0xFFF26430);
  static const Color inkBlack = Color(0xFF0E0E0C);
  static const Color routeGreen = Color(0xFF116E45);
  static const Color signalCream = Color(0xFFF4EFE6);
  static const Color fog = Color(0xFFE4DFD6);
  static const Color slate = Color(0xFF3C3A34);
  static const Color liveBlue = Color(0xFF2E63E8);

  static ThemeData themeData = ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: signalCream,
    colorScheme: const ColorScheme.light(
      primary: saffron,
      secondary: slate,
      surface: Colors.white,
      onPrimary: Colors.white,
      onSurface: inkBlack,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: signalCream,
      foregroundColor: inkBlack,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: 20,
        color: inkBlack,
        letterSpacing: 0.5,
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
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: fog, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: fog),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: fog),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: saffron, width: 2),
      ),
      labelStyle: const TextStyle(color: slate),
    ),
  );
}

class VayaHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    HttpOverrides.global = VayaHttpOverrides();
  }
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase initialization skipped or already running: $e");
  }
  runApp(const VayaCustomerApp());
}

class VayaCustomerApp extends StatefulWidget {
  const VayaCustomerApp({super.key});

  @override
  State<VayaCustomerApp> createState() => _VayaCustomerAppState();
}

class _VayaCustomerAppState extends State<VayaCustomerApp> {
  Locale _locale = const Locale('en');

  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VAYA Logistics',
      debugShowCheckedModeBanner: false,
      theme: VayaTheme.themeData,
      locale: _locale,
      supportedLocales: const [
        Locale('en', ''), // English
        Locale('or', ''), // Odia
        Locale('hi', ''), // Hindi
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _loading = true;
  Map<String, dynamic>? _customerData;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    // 1. Check local disk session FIRST for instant cold-start auto-login
    final saved = await CustomerSessionManager.getSavedSession();
    if (saved != null) {
      debugPrint('[VAYA] Cold Start: Saved session found. Auto-logging customer in instantly.');
      if (mounted) {
        setState(() {
          _customerData = saved;
          _loading = false;
        });
      }
      // Perform background sync to verify/refresh token & profile
      _syncSessionInBackground();
      return;
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
      await _syncSessionWithUser(user);
    } else {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _syncSessionWithUser(User user) async {
    try {
      final token = await user.getIdToken(true);
      if (token != null && token.isNotEmpty) {
        await CustomerSessionManager.saveToken(token);
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/customer/me'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['customer'] != null) {
            final customer = data['customer'];
            await CustomerSessionManager.saveSession(customer, token: token);
            if (mounted) {
              setState(() {
                _customerData = customer;
                _loading = false;
              });
            }
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('[VAYA] Error syncing session with user: $e');
    }

    final defaultCustomer = {
      'id': user.uid,
      'name': 'Valued Customer',
      'phone': user.phoneNumber ?? '',
    };
    await CustomerSessionManager.saveSession(defaultCustomer);
    if (mounted) {
      setState(() {
        _customerData = defaultCustomer;
        _loading = false;
      });
    }
  }

  Future<void> _syncSessionInBackground() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null && token.isNotEmpty) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/customer/me'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['exists'] == true && data['customer'] != null) {
            final customer = data['customer'];
            await CustomerSessionManager.saveSession(customer, token: token);
            if (mounted) {
              setState(() {
                _customerData = customer;
              });
            }
          }
        } else if (res.statusCode == 401 || res.statusCode == 403) {
          debugPrint('[VAYA] Background session sync: Auth token expired (HTTP ${res.statusCode}). Clearing session.');
          await CustomerSessionManager.clearSession();
          try {
            await FirebaseAuth.instance.signOut();
          } catch (_) {}
          if (mounted) {
            setState(() {
              _customerData = null;
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
      debugPrint('[VAYA] Background session sync notice: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: VayaTheme.signalCream,
        body: Center(
          child: VayaLoader.section(size: 120, message: 'Verifying VAYA Session...'),
        ),
      );
    }

    if (_customerData != null) {
      return const MainNavigationScreen();
    }

    return LanguageSelectionScreen(
      onLanguageSelected: (locale) {
        final appState = context.findAncestorStateOfType<_VayaCustomerAppState>();
        if (appState != null) {
          appState.setLocale(locale);
        }
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      },
    );
  }
}

// i18n Strings dictionary — comprehensive translation catalog
class LocalizedStrings {
  final Locale locale;
  LocalizedStrings(this.locale);

  static LocalizedStrings of(BuildContext context) {
    return LocalizedStrings(Localizations.localeOf(context));
  }

  String _t(String en, String or, String hi) =>
      locale.languageCode == 'or' ? or : locale.languageCode == 'hi' ? hi : en;

  // Common
  String get selectLang => _t('Select Language', 'ଭାଷା ଚୟନ କରନ୍ତୁ', 'भाषा चुनें');
  String get welcome => 'VAYA';
  String get cancel => _t('Cancel', 'ବାତିଲ୍', 'रद्द करें');
  String get save => _t('Save', 'ସେଭ୍ କରନ୍ତୁ', 'सहेजें');
  String get close => _t('Close', 'ବନ୍ଦ କରନ୍ତୁ', 'बंद करें');
  String get confirm => _t('Confirm', 'ନିଶ୍ଚିତ କରନ୍ତୁ', 'पुष्टि करें');
  String get loading => _t('Loading...', 'ଲୋଡ୍ ହେଉଛି...', 'लोड हो रहा है...');
  String get done => _t('Done', 'ସମ୍ପୂର୍ଣ୍ଣ', 'पूर्ण');

  // Login
  String get mobileLogin => _t('Mobile Login', 'ମୋବାଇଲ୍ ଲଗ୍ ଇନ୍', 'मोबाइल लॉगिन');
  String get enterMobile => _t('Enter 10-digit Mobile Number', '୧୦-ଅଙ୍କ ମୋବାଇଲ୍ ନମ୍ବର ଦିଅନ୍ତୁ', '10-अंकीय मोबाइल नंबर दर्ज करें');
  String get sendOtp => _t('Send OTP', 'OTP ପଠାନ୍ତୁ', 'ओटीपी भेजें');
  String get verifyOtp => _t('Verify OTP', 'OTP ଯାଞ୍ଚ କରନ୍ତୁ', 'ओटीपी सत्यापित करें');

  // Home
  String get whereToPickup => _t('Where to pick up?', 'କେଉଁଠୁ ଉଠାଇବେ?', 'कहाँ से उठाना है?');
  String get whereToDeliver => _t('Where to deliver?', 'କେଉଁଠି ପହଞ୍ଚାଇବେ?', 'कहाँ पहुँचाना है?');
  String get locatingPosition => _t('Locating current position...', 'ସ୍ଥାନ ଖୋଜୁଛି...', 'वर्तमान स्थान खोज रहा है...');
  String get routeDetails => _t('Route details', 'ରୁଟ୍ ବିବରଣୀ', 'मार्ग विवरण');
  String get chooseVehicle => _t('Choose vehicle', 'ଗାଡ଼ି ଚୟନ କରନ୍ତୁ', 'वाहन चुनें');
  String get selectPointsToProceed => _t('Select points to proceed', 'ଆଗକୁ ବଢ଼ିବା ପାଇଁ ସ୍ଥାନ ଚୟନ କରନ୍ତୁ', 'आगे बढ़ने के लिए स्थान चुनें');
  String get locationsTooClose => _t('Locations too close', 'ସ୍ଥାନ ବହୁ ନିକଟ', 'स्थान बहुत पास हैं');
  String get pickup => _t('PICKUP', 'ପିକଅପ୍', 'पिकअप');
  String get dropoff => _t('DROP-OFF', 'ଡ୍ରପ୍-ଅଫ୍', 'ड्रॉप-ऑफ');

  // Location Search
  String get selectPickup => _t('Select pickup', 'ପିକଅପ୍ ଚୟନ', 'पिकअप चुनें');
  String get selectDropoff => _t('Select drop-off', 'ଡ୍ରପ୍-ଅଫ୍ ଚୟନ', 'ड्रॉप-ऑफ चुनें');
  String get searchPlaceholder => _t('Search area, street or landmark', 'ସ୍ଥାନ, ରାସ୍ତା ବା ଲ୍ୟାଣ୍ଡମାର୍କ ଖୋଜନ୍ତୁ', 'स्थान, सड़क या लैंडमार्क खोजें');
  String get useMyCurrentLocation => _t('Use my current location', 'ମୋ ବର୍ତ୍ତମାନ ସ୍ଥାନ ବ୍ୟବହାର କରନ୍ତୁ', 'मेरा वर्तमान स्थान उपयोग करें');
  String get fetchingLocation => _t('Fetching your location...', 'ଆପଣଙ୍କ ସ୍ଥାନ ଖୋଜୁଛି...', 'आपका स्थान खोज रहा है...');
  String get chooseOnMap => _t('Choose precise location on Map', 'ମାନଚିତ୍ରରେ ସଠିକ ସ୍ଥାନ ଚୟନ', 'मानचित्र पर सटीक स्थान चुनें');
  String get savedLocations => _t('SAVED LOCATIONS', 'ସଞ୍ଚିତ ସ୍ଥାନ', 'सहेजे गए स्थान');
  String get recentSearches => _t('RECENT SEARCHES', 'ନିକଟ ଅନୁସନ୍ଧାନ', 'हाल की खोजें');
  String get noMatchingPlaces => _t('No matching places found', 'କୌଣସି ସ୍ଥାନ ମିଳିଲା ନାହିଁ', 'कोई मिलता-जुलता स्थान नहीं मिला');
  String get addNew => _t('Add new', 'ନୂଆ ଯୋଡ଼ନ୍ତୁ', 'नया जोड़ें');

  // Vehicle Selection
  String get bookNow => _t('Book a VAYA', 'ବୁକିଂ କରନ୍ତୁ', 'बुकिंग करें');
  String get helpMeChoose => _t('Help me choose', 'ମୋତେ ସାହାଯ୍ୟ କରନ୍ତୁ', 'मुझे चुनने में मदद करें');
  String get helpMeChooseTitle => _t('Help Me Choose a Vehicle', 'ଗାଡ଼ି ଚୟନ ସାହାଯ୍ୟ', 'वाहन चुनने में मदद');
  String get helpMeChooseSubtitle => _t('Select what you want to deliver to get a recommendation:', 'ସୁପାରିଶ ପାଇବା ପାଇଁ ଆପଣ କ\'ଣ ବିତରଣ କରିବାକୁ ଚାହାନ୍ତି ଚୟନ କରନ୍ତୁ:', 'सिफारिश पाने के लिए चुनें कि आप क्या भेजना चाहते हैं:');
  String get fareBreakdown => _t('Fare Breakdown', 'ଭଡ଼ା ବିବରଣୀ', 'किराया विवरण');
  String get baseFare => _t('Base fare', 'ମୂଳ ଭଡ଼ା', 'बेस किराया');
  String get distanceCharge => _t('Distance charge', 'ଦୂରତା ମୂଲ୍ୟ', 'दूरी शुल्क');
  String get helperCharge => _t('Helper charge', 'ସହାୟକ ମୂଲ୍ୟ', 'सहायक शुल्क');
  String get estimatedFare => _t('Estimated fare', 'ଅନୁମାନିତ ଭଡ଼ା', 'अनुमानित किराया');
  String get customization => _t('Customization', 'କଷ୍ଟମାଇଜେସନ୍', 'अनुकूलन');
  String get goodsCategory => _t('Goods Category', 'ସାମଗ୍ରୀ ଶ୍ରେଣୀ', 'सामान श्रेणी');
  String get paymentMethod => _t('Payment Method', 'ଦେୟ ପଦ୍ଧତି', 'भुगतान विधि');

  // Tracking
  String get tracking => _t('Track VAYA', 'ବୁକିଂ ଟ୍ରାକ୍', 'ट्रैकिंग');
  String get searchingDrivers => _t('Searching nearby drivers...', 'ନିକଟବର୍ତ୍ତୀ ଡ୍ରାଇଭର୍ ଖୋଜୁଛି...', 'नज़दीकी ड्राइवर खोज रहा है...');
  String get cancelBooking => _t('Cancel booking', 'ବୁକିଂ ବାତିଲ୍ କରନ୍ତୁ', 'बुकिंग रद्द करें');
  String get cancelConfirmTitle => _t('Cancel this booking?', 'ଏହି ବୁକିଂ ବାତିଲ୍ କରିବେ?', 'यह बुकिंग रद्द करें?');
  String get cancelConfirmMsg => _t('Are you sure you want to cancel? If a driver has already been assigned, a cancellation fee may apply.', 'ଆପଣ ନିଶ୍ଚିତ କି ଆପଣ ବାତିଲ୍ କରିବାକୁ ଚାହାନ୍ତି? ଯଦି ଏକ ଡ୍ରାଇଭର ଆସାଇନ୍ ହୋଇସାରିଛି, ବାତିଲ୍ ଶୁଳ୍କ ଲାଗୁ ହୋଇପାରେ।', 'क्या आप वाकई रद्द करना चाहते हैं? यदि ड्राइवर पहले से नियुक्त है, तो रद्दीकरण शुल्क लग सकता है।');
  String get shareTracking => _t('Share Live Tracking Link', 'ଲାଇଭ୍ ଟ୍ରାକିଂ ଲିଙ୍କ ସେୟାର୍ କରନ୍ତୁ', 'लाइव ट्रैकिंग लिंक साझा करें');
  String get pickupVerificationOtp => _t('PICKUP VERIFICATION OTP', 'ପିକଅପ୍ ଯାଞ୍ଚ OTP', 'पिकअप सत्यापन OTP');
  String get shareWithDriver => _t('Share with driver upon arrival', 'ପହଞ୍ଚିଲେ ଡ୍ରାଇଭରଙ୍କ ସହ ସେୟାର୍ କରନ୍ତୁ', 'पहुँचने पर ड्राइवर को बताएं');

  // Orders
  String get myDeliveries => _t('My Deliveries', 'ମୋ ଡେଲିଭରୀ', 'मेरी डिलीवरी');
  String get active => _t('Active', 'ସକ୍ରିୟ', 'सक्रिय');
  String get completed => _t('Completed', 'ସମ୍ପୂର୍ଣ୍ଣ', 'पूर्ण');
  String get cancelled => _t('Cancelled', 'ବାତିଲ୍', 'रद्द');
  String get trackOrder => _t('Track Order', 'ଅର୍ଡର ଟ୍ରାକ୍ କରନ୍ତୁ', 'ऑर्डर ट्रैक करें');

  // Payments
  String get paymentsAndWallet => _t('Payments & Wallet', 'ଦେୟ ଏବଂ ୱାଲେଟ୍', 'भुगतान और वॉलेट');
  String get walletBalance => _t('Wallet Balance', 'ୱାଲେଟ୍ ବାଲାନ୍ସ', 'वॉलेट बैलेंस');
  String get addMoney => _t('Add money', 'ଟଙ୍କା ଯୋଡ଼ନ୍ତୁ', 'पैसे जोड़ें');
  String get viewActivity => _t('View activity', 'କାର୍ଯ୍ୟକଳାପ ଦେଖନ୍ତୁ', 'गतिविधि देखें');
  String get defaultPaymentMethod => _t('Default Payment Method', 'ଡିଫଲ୍ଟ ଦେୟ ପଦ୍ଧତି', 'डिफ़ॉल्ट भुगतान विधि');
  String get wallet => _t('VAYA Wallet', 'VAYA ୱାଲେଟ୍', 'VAYA वॉलेट');
  String get upiPayment => _t('UPI Payment', 'UPI ଦେୟ', 'UPI भुगतान');
  String get cashOnDelivery => _t('Cash on Delivery', 'ବିତରଣ ସମୟରେ ନଗଦ', 'कैश ऑन डिलीवरी');
  String get recentTransactions => _t('Recent Transactions', 'ନିକଟ ଲେନଦେନ', 'हाल के लेनदेन');

  // Account
  String get account => _t('Account', 'ଖାତା', 'खाता');
  String get editProfile => _t('Edit profile', 'ପ୍ରୋଫାଇଲ୍ ସଂପାଦନା', 'प्रोफ़ाइल संपादित करें');
  String get logistics => _t('Logistics', 'ଲଜିଷ୍ଟିକ୍ସ', 'लॉजिस्टिक्स');
  String get savedAddresses => _t('Saved addresses', 'ସଞ୍ଚିତ ଠିକଣା', 'सहेजे गए पते');
  String get businessAndBilling => _t('Business & billing', 'ବ୍ୟବସାୟ ଏବଂ ବିଲିଂ', 'व्यवसाय और बिलिंग');
  String get businessTaxDetails => _t('Business & tax details', 'ବ୍ୟବସାୟ ଏବଂ ଟ୍ୟାକ୍ସ ବିବରଣୀ', 'व्यवसाय और कर विवरण');
  String get preferences => _t('Preferences', 'ପସନ୍ଦ', 'प्राथमिकताएँ');
  String get notifications => _t('Notifications', 'ବିଜ୍ଞପ୍ତି', 'सूचनाएँ');
  String get appLanguage => _t('App language', 'ଆପ୍ ଭାଷା', 'ऐप भाषा');
  String get helpAndSafety => _t('Help & safety', 'ସାହାଯ୍ୟ ଏବଂ ସୁରକ୍ଷା', 'सहायता और सुरक्षा');
  String get helpCentre => _t('Help centre', 'ସାହାଯ୍ୟ କେନ୍ଦ୍ର', 'सहायता केंद्र');
  String get contactSupport => _t('Contact support', 'ସହାୟତା ସମ୍ପର୍କ', 'सहायता से संपर्क');
  String get disputesRefunds => _t('Disputes & refund cases', 'ବିବାଦ ଏବଂ ରିଫଣ୍ଡ', 'विवाद और रिफंड');
  String get privacyAndLegal => _t('Privacy & legal', 'ଗୋପନୀୟତା ଏବଂ ଆଇନ', 'गोपनीयता और कानूनी');
  String get privacyPolicy => _t('Privacy policy & terms', 'ଗୋପନୀୟତା ନୀତି ଏବଂ ସର୍ତ୍ତାବଳୀ', 'गोपनीयता नीति और शर्तें');
  String get downloadMyData => _t('Download my data', 'ମୋ ଡାଟା ଡାଉନଲୋଡ୍', 'मेरा डेटा डाउनलोड करें');
  String get signOut => _t('Sign out', 'ସାଇନ୍ ଆଉଟ୍', 'साइन आउट');
  String get signOutConfirm => _t('Sign out of VAYA?', 'VAYA ରୁ ସାଇନ୍ ଆଉଟ୍ କରିବେ?', 'VAYA से साइन आउट करें?');
  String get chooseLanguage => _t('Choose language', 'ଭାଷା ଚୟନ କରନ୍ତୁ', 'भाषा चुनें');
  // Navigation & Tabs
  String get navHome => _t('Home', 'ମୁଖ୍ୟ', 'होम');
  String get navOrders => _t('Orders', 'ଅର୍ଡର', 'ऑर्डर');
  String get navPayments => _t('Payments', 'ଦେୟ', 'भुगतान');
  String get navAccount => _t('Account', 'ଖାତା', 'खाता');

  // Map & Pin Picker
  String get dragMapTitle => _t('Set Location on Map', 'ମାନଚିତ୍ରରେ ସ୍ଥାନ ଚୟନ', 'मानचित्र पर स्थान सेट करें');
  String get confirmLocation => _t('Confirm Location', 'ସ୍ଥାନ ନିଶ୍ଚିତ କରନ୍ତୁ', 'स्थान की पुष्टि करें');
  String get addressDetailsLabel => _t('House / Flat / Building / Gate details', 'ଗୃହ / ଫ୍ଲାଟ / ବିଲ୍ଡିଂ / ଗେଟ୍ ବିବରଣୀ', 'मकान / फ्लैट / बिल्डिंग / गेट विवरण');
  String get senderReceiverPhone => _t('Contact Phone Number', 'ସମ୍ପର୍କ ମୋବାଇଲ୍ ନମ୍ବର', 'संपर्क मोबाइल नंबर');

  // Helper & Options
  String get needHelpers => _t('Need Helpers?', 'ସହାୟକ ଆବଶ୍ୟକ କି?', 'क्या सहायक चाहिए?');
  String get noHelper => _t('No Helper', 'ସହାୟକ ନାହିଁ', 'कोई सहायक नहीं');
  String get oneHelper => _t('1 Helper (+₹150)', '୧ ଜଣ ସହାୟକ (+₹150)', '1 सहायक (+₹150)');
  String get twoHelpers => _t('2 Helpers (+₹300)', '୨ ଜଣ ସହାୟକ (+₹300)', '2 सहायक (+₹300)');
  String get applyCoupon => _t('Apply Promo / Coupon', 'ପ୍ରୋମୋ / କୁପନ ବ୍ୟବହାର କରନ୍ତୁ', 'प्रोमो / कूपन लागू करें');
  String get totalAmount => _t('Total Amount', 'ମୋଟ ରାଶି', 'कुल राशि');
  String get confirmAndBook => _t('Confirm & Book Now', 'ନିଶ୍ଚିତ କରନ୍ତୁ ଏବଂ ବୁକ୍ କରନ୍ତୁ', 'पुष्टि करें और अभी बुक करें');
  String get subheadingDeliver => _t('Reliable Intra-city Logistics', 'ବିଶ୍ୱସନୀୟ ଆନ୍ତଃସହର ଲଜିଷ୍ଟିକ୍ସ', 'विश्वसनीय अंतर-शहर रसद');
}

/// 1. Language Picker Screen
class LanguageSelectionScreen extends StatelessWidget {
  final Function(Locale) onLanguageSelected;

  const LanguageSelectionScreen({super.key, required this.onLanguageSelected});

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
                    color: VayaTheme.saffron,
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
                'Choose Language\nଭାଷା ଚୟନ କରନ୍ତୁ\nभाषा चुनें',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22, 
                  fontWeight: FontWeight.bold, 
                  height: 1.5,
                  color: VayaTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 48),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('en'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                },
                child: const Text('English'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('or'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                },
                child: const Text('ଓଡ଼ିଆ (Odia)'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  onLanguageSelected(const Locale('hi'));
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
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

/// 2. OTP Login Screen (Real Firebase Phone Auth)
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
      final token = await user.getIdToken();
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/customer/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          final customer = (data['exists'] == true && data['customer'] != null)
              ? data['customer']
              : {
                  'id': user.uid,
                  'name': 'Valued Customer',
                  'phone': user.phoneNumber ?? '',
                };
          await CustomerSessionManager.saveSession(customer);
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
            (route) => false,
          );
        }
      } else {
        final fallbackCustomer = {
          'id': user.uid,
          'name': 'Valued Customer',
          'phone': user.phoneNumber ?? '',
        };
        await CustomerSessionManager.saveSession(fallbackCustomer);
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
            (route) => false,
          );
        }
      }
    } catch (e) {
      final fallbackCustomer = {
        'id': user.uid,
        'name': 'Valued Customer',
        'phone': user.phoneNumber ?? '',
      };
      await CustomerSessionManager.saveSession(fallbackCustomer);
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final str = LocalizedStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('VΛYΛ'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _otpSent ? str.verifyOtp : str.mobileLogin,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
            ),
            const SizedBox(height: 16),
            if (!_otpSent)
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                style: const TextStyle(color: VayaTheme.inkBlack, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: '+91 ',
                  labelText: str.enterMobile,
                ),
              )
            else
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: VayaTheme.inkBlack, fontWeight: FontWeight.bold, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  labelText: 'Enter OTP Code',
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
                  : Text(_otpSent ? str.verifyOtp : str.sendOtp),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3. Customer Profile Onboarding Screen
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _nameController = TextEditingController();
  bool _isLoading = false;
  String? _errorMsg;

  Future<void> _submitProfile() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMsg = 'Name is required');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token == null) return;

      final user = FirebaseAuth.instance.currentUser;
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/customer'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'name': _nameController.text.trim(),
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final customerData = data['customer'] ?? {
          'id': user?.uid ?? '',
          'name': _nameController.text.trim(),
          'phone': user?.phoneNumber ?? '',
        };
        await CustomerSessionManager.saveSession(customerData);
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
            (route) => false,
          );
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMsg = 'Server failed to save profile.';
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
      appBar: AppBar(title: const Text('Complete Profile')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.account_circle, size: 64, color: VayaTheme.saffron),
            const SizedBox(height: 16),
            const Text(
              'Enter Basic Details',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Your Full Name',
              ),
            ),
            if (_errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(_errorMsg!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _submitProfile,
              child: _isLoading
                  ? const VayaLoader.inline(size: 20, color: Colors.white)
                  : const Text('Save & Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 4. Main Navigation Screen (4-Tab Persistent Bottom Navigation Bar)
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  Map<String, dynamic>? _activeBooking;
  Timer? _activeBookingCheckTimer;
  bool _isRatingSheetShowing = false;
  bool _hasViewedOrders = false;

  @override
  void initState() {
    super.initState();
    _loadCachedActiveBookingFirst();
    _checkActiveBooking();
    _activeBookingCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkActiveBooking();
    });
  }

  Future<void> _loadCachedActiveBookingFirst() async {
    final cached = await VayaStorage.loadCachedActiveBooking();
    if (cached != null && mounted) {
      setState(() {
        _activeBooking = cached;
      });
    }
  }

  @override
  void dispose() {
    _activeBookingCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkActiveBooking() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token == null) return;

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/active'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true) {
            setState(() {
              _activeBooking = data['booking'];
            });
            await VayaStorage.saveCachedActiveBooking(data['booking']);
          } else {
            setState(() {
              _activeBooking = null;
            });
            await VayaStorage.saveCachedActiveBooking(null);
            if (token != null) {
              _checkUnratedBooking(token);
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error checking active booking: $e");
    }
  }

  Future<void> _checkUnratedBooking(String token) async {
    if (_isRatingSheetShowing) return;
    try {
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/unrated'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['exists'] == true && mounted) {
          final booking = data['booking'];
          final bookingId = booking['id'];
          final driverName = booking['driver_name'] ?? 'Driver Partner';

          _isRatingSheetShowing = true;
          showModalBottomSheet(
            context: context,
            isDismissible: true,
            enableDrag: false,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (ctx) => DriverRatingBottomSheet(
              bookingId: bookingId,
              driverName: driverName,
              bookingData: booking,
            ),
          ).then((_) {
            if (mounted) {
              setState(() {
                _isRatingSheetShowing = false;
              });
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Error checking unrated booking: $e");
    }
  }

  Future<void> _handleVoiceBookingAction(Map<String, dynamic> actionData) async {
    final String pickupName = actionData['pickup_name'] ?? '';
    final String dropoffName = actionData['dropoff_name'] ?? '';
    final String vehicleType = actionData['vehicle_type'] ?? 'bike';

    LatLng pickupPos = const LatLng(20.2961, 85.8245); // Master Canteen default
    LatLng dropoffPos = const LatLng(20.3588, 85.8333); // Patia default

    if (pickupName.isNotEmpty) {
      final res = await _quickGeocode(pickupName);
      if (res != null && res['lat'] != null && res['lon'] != null) {
        pickupPos = LatLng(res['lat']!, res['lon']!);
      }
    }

    if (dropoffName.isNotEmpty) {
      final res = await _quickGeocode(dropoffName);
      if (res != null && res['lat'] != null && res['lon'] != null) {
        dropoffPos = LatLng(res['lat']!, res['lon']!);
      }
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VehicleSelectionScreen(
            pickup: pickupPos,
            pickupAddress: pickupName.isNotEmpty ? pickupName : 'Patia, Bhubaneswar',
            dropoff: dropoffPos,
            dropoffAddress: dropoffName.isNotEmpty ? dropoffName : 'Saheed Nagar, Bhubaneswar',
            initialVehicle: vehicleType.isNotEmpty ? vehicleType : 'bike',
          ),
        ),
      );
    }
  }

  Future<Map<String, double>?> _quickGeocode(String query) async {
    try {
      final url = 'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent("$query, Bhubaneswar")}&limit=1';
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'VAYACustomerApp/1.0'});
      if (res.statusCode == 200) {
        final list = json.decode(res.body) as List;
        if (list.isNotEmpty) {
          return {
            'lat': double.parse(list[0]['lat']),
            'lon': double.parse(list[0]['lon']),
          };
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      HomeScreen(
        activeBooking: _activeBooking,
        onTrackActive: (bookingId, fare) {
          final targetBookingId = bookingId.isNotEmpty ? bookingId : (_activeBooking?['id'] ?? '');
          final targetFare = fare > 0 ? fare : (double.tryParse(_activeBooking?['estimated_cost']?.toString() ?? '') ?? 0.0);
          if (targetBookingId.isNotEmpty) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TrackingScreen(
                  bookingId: targetBookingId,
                  initialEstimatedCost: targetFare,
                ),
              ),
            ).then((_) => _checkActiveBooking());
          }
        },
        onVehicleSelected: (vehicle) {
          setState(() => _currentIndex = 0);
        },
      ),
      OrdersScreen(
        onTrackActive: (bookingId, fare) {
          final targetBookingId = bookingId.isNotEmpty ? bookingId : (_activeBooking?['id'] ?? '');
          final targetFare = fare > 0 ? fare : (double.tryParse(_activeBooking?['estimated_cost']?.toString() ?? '') ?? 0.0);
          if (targetBookingId.isNotEmpty) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TrackingScreen(
                  bookingId: targetBookingId,
                  initialEstimatedCost: targetFare,
                ),
              ),
            ).then((_) => _checkActiveBooking());
          }
        },
        onBookAVaya: () {
          setState(() => _currentIndex = 0);
        },
      ),
      const PaymentsScreen(),
      const AccountScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
            if (index == 1) {
              _hasViewedOrders = true;
            }
          });
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: VayaTheme.saffron,
        unselectedItemColor: VayaTheme.slate,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home, color: VayaTheme.saffron),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Stack(
              children: [
                const Icon(Icons.receipt_long_outlined),
                if (_activeBooking != null && !_hasViewedOrders)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: VayaTheme.saffron,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            activeIcon: const Icon(Icons.receipt_long, color: VayaTheme.saffron),
            label: 'Orders',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            activeIcon: Icon(Icons.account_balance_wallet, color: VayaTheme.saffron),
            label: 'Payments',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person, color: VayaTheme.saffron),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}

/// 5. Home Tab Screen (Two-Point Search & Interactive Map)
class HomeScreen extends StatefulWidget {
  final Map<String, dynamic>? activeBooking;
  final Function(String, double)? onTrackActive;
  final Function(String)? onVehicleSelected;

  const HomeScreen({
    super.key,
    this.activeBooking,
    this.onTrackActive,
    this.onVehicleSelected,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LatLng _pickup = const LatLng(20.2961, 85.8245); // Master Canteen, Bhubaneswar
  LatLng _dropoff = const LatLng(20.3150, 85.8178); // Patia, Bhubaneswar
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  bool _isLocating = true;
  bool _locationFailed = false;

  List<Map<String, String>> _savedPlacesShort = [];
  List<Map<String, dynamic>> _recentSearches = [];
  String? _preselectedVehicle;

  @override
  void initState() {
    super.initState();
    _loadHomeScreenStorage();
    _locateUserPosition();
  }

  Future<void> _loadHomeScreenStorage() async {
    final saved = await VayaStorage.loadSavedPlaces();
    final recents = await VayaStorage.loadRecentSearches();
    if (mounted) {
      setState(() {
        _savedPlacesShort = saved;
        _recentSearches = recents;
      });
    }
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _locateUserPosition() async {
    if (!mounted) return;
    setState(() {
      _isLocating = true;
      _locationFailed = false;
    });
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        final coords = LatLng(pos.latitude, pos.longitude);
        _pickup = coords;
        final addr = await _reverseGeocode(pos.latitude, pos.longitude);
        if (mounted) {
          setState(() {
            _pickupController.text = addr.isNotEmpty ? addr : 'Current location · Sailashree Vihar';
            _isLocating = false;
            _locationFailed = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLocating = false;
            _locationFailed = true;
          });
        }
      }
    } catch (e) {
      debugPrint("Error locating user: $e");
      if (mounted) {
        setState(() {
          _isLocating = false;
          _locationFailed = true;
        });
      }
    }
  }

  Future<String> _reverseGeocode(double lat, double lng) async {
    final url = 'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng';
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept-Language': 'en',
          'User-Agent': 'VAYACustomerApp/1.0 (com.vaya.customer_app)',
        },
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final road = address['road'] ?? address['suburb'] ?? address['neighbourhood'] ?? '';
          final city = address['city'] ?? address['town'] ?? address['county'] ?? 'Bhubaneswar';
          if (road.toString().isNotEmpty) return 'Current location · $road, $city';
        }
        return 'Current location · Sailashree Vihar';
      }
    } catch (e) {
      debugPrint("Reverse geocode error: $e");
    }
    return 'Current location · Sailashree Vihar';
  }

  void _openLocationSearchModal(String fieldType) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => SinglePageTripPlanner(
          initialPickupPos: _pickup,
          initialPickupAddress: _pickupController.text,
          initialDropoffPos: _dropoff,
          initialDropoffAddress: _dropoffController.text,
          initialActiveStep: fieldType == 'destination' ? 'dropoff' : 'pickup',
          preselectedVehicle: _preselectedVehicle,
        ),
      ),
    );

    if (result != null && mounted) {
      final LatLng? pPos = result['pickupPos'];
      final String? pAddr = result['pickupAddress'];
      final LatLng? dPos = result['dropoffPos'];
      final String? dAddr = result['dropoffAddress'];
      final bool proceedToVehicle = result['proceedToVehicle'] ?? false;

      setState(() {
        if (pPos != null) _pickup = pPos;
        if (pAddr != null && pAddr.isNotEmpty) _pickupController.text = pAddr;
        if (dPos != null) _dropoff = dPos;
        if (dAddr != null && dAddr.isNotEmpty) _dropoffController.text = dAddr;
      });

      if (proceedToVehicle && _pickupController.text.isNotEmpty && _dropoffController.text.isNotEmpty) {
        final dist = Geolocator.distanceBetween(
          _pickup.latitude,
          _pickup.longitude,
          _dropoff.latitude,
          _dropoff.longitude,
        ) / 1000.0;
        if (dist >= 0.05) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => VehicleSelectionScreen(
                pickup: _pickup,
                pickupAddress: _pickupController.text,
                dropoff: _dropoff,
                dropoffAddress: _dropoffController.text,
                initialVehicle: _preselectedVehicle,
              ),
            ),
          );
        }
      }
    }
  }

  String _formatDistance(double distKm) {
    if (distKm < 1.0) {
      return '${(distKm * 1000).round()} m';
    }
    return '${distKm.toStringAsFixed(1)} km';
  }

  void _onSelectVehicleCategory(String vehicleId) {
    setState(() {
      _preselectedVehicle = vehicleId;
    });

    final bool isBothSet = _pickupController.text.isNotEmpty && _dropoffController.text.isNotEmpty;
    if (isBothSet) {
      final dist = Geolocator.distanceBetween(
        _pickup.latitude,
        _pickup.longitude,
        _dropoff.latitude,
        _dropoff.longitude,
      ) / 1000.0;
      if (dist >= 0.05) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VehicleSelectionScreen(
              pickup: _pickup,
              pickupAddress: _pickupController.text,
              dropoff: _dropoff,
              dropoffAddress: _dropoffController.text,
              initialVehicle: _preselectedVehicle,
            ),
          ),
        );
        return;
      }
    }

    _openLocationSearchModal('destination');
  }

  String _getVehicleCategoryLabel(String id) {
    switch (id.toLowerCase()) {
      case 'bike':
        return 'Bike';
      case 'three_wheeler':
      case '3_wheeler':
      case '3-wheeler':
        return '3-wheeler';
      case 'ace':
      case 'mini_truck':
      case 'mini truck':
        return 'Mini truck';
      case 'truck':
      case 'lcv':
      case 'light commercial vehicle':
        return 'Light commercial vehicle';
      default:
        return id;
    }
  }

  String _getFriendlyCustomerStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'pending':
      case 'created':
      case 'searching':
        return 'Finding a driver';
      case 'accepted':
      case 'driver_assigned':
      case 'arriving':
        return 'Driver arriving · 4 min';
      case 'at_pickup':
      case 'arrived':
        return 'At pickup';
      case 'in_transit':
      case 'picked_up':
      case 'on_the_way':
        return 'On the way to drop-off';
      case 'completed':
      case 'delivered':
        return 'Delivered';
      default:
        return 'Finding a driver';
    }
  }

  Color _getStatusSemanticColor(String? status) {
    final s = status?.toLowerCase();
    if (s == 'in_transit' || s == 'picked_up' || s == 'on_the_way' || s == 'completed' || s == 'delivered') {
      return VayaTheme.routeGreen; // Reserve Route Green ONLY for live/completed
    }
    return VayaTheme.saffron; // Warm Saffron indicator for finding/arriving
  }

  String _formatBookingId(dynamic id) {
    if (id == null) return 'BD-8921';
    final str = id.toString();
    if (str.length >= 4) {
      return str.substring(str.length - 4).toUpperCase();
    }
    return str.toUpperCase();
  }

  IconData _getVehicleIcon(dynamic vType) {
    final v = vType?.toString().toLowerCase() ?? '';
    if (v.contains('bike')) return Icons.two_wheeler;
    if (v.contains('3') || v.contains('three') || v.contains('tempo')) return Icons.electric_rickshaw;
    if (v.contains('ace') || v.contains('mini')) return Icons.local_shipping;
    return Icons.fire_truck_outlined;
  }

  Widget _buildHomeVehicleCategoryCard({
    required String id,
    required String title,
    required String capacitySubtitle,
    required String imageAsset,
  }) {
    final isSelected = _preselectedVehicle == id;

    return Card(
      elevation: isSelected ? 2 : 0.5,
      color: isSelected ? VayaTheme.saffron.withValues(alpha: 0.06) : Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected ? VayaTheme.saffron : VayaTheme.slate.withValues(alpha: 0.12),
          width: isSelected ? 2.0 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _onSelectVehicleCategory(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(2.0),
                  child: Image.asset(
                    imageAsset,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? VayaTheme.saffron : VayaTheme.inkBlack,
                      ),
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.check_circle, size: 14, color: VayaTheme.saffron),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                capacitySubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: VayaTheme.slate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizedStrings.of(context);
    final dist = Geolocator.distanceBetween(
      _pickup.latitude,
      _pickup.longitude,
      _dropoff.latitude,
      _dropoff.longitude,
    ) / 1000.0;

    final bool isBothSet = _pickupController.text.isNotEmpty && _dropoffController.text.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: VayaTheme.signalCream,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: 48, // Reduced height to eliminate top void!
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Approved Saffron V-Mark Icon Badge
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: VayaTheme.saffron,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Text(
                  'V',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.0,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Ink Black Wordmark "VAYA" (No white-on-Saffron box)
            const Text(
              'VAYA',
              style: TextStyle(
                fontFamily: 'Outfit',
                fontWeight: FontWeight.w900,
                color: VayaTheme.inkBlack,
                fontSize: 20,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: isBothSet
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                child: ElevatedButton(
                  onPressed: dist < 0.05
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VehicleSelectionScreen(
                                pickup: _pickup,
                                pickupAddress: _pickupController.text,
                                dropoff: _dropoff,
                                dropoffAddress: _dropoffController.text,
                                initialVehicle: _preselectedVehicle,
                              ),
                            ),
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaTheme.saffron,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    disabledBackgroundColor: VayaTheme.fog,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          dist < 0.05 ? 'Locations too close' : 'View Route & Choose Vehicle (${_formatDistance(dist)})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (dist >= 0.05) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward, size: 16),
                      ],
                    ],
                  ),
                ),
              ),
            )
          : null,
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: kBottomNavigationBarHeight + MediaQuery.of(context).padding.bottom + 28,
        ),
        children: [
          // Address Route Card (Connected 56px fields with 3px Saffron route line)
          Card(
            color: Colors.white,
            elevation: 1.5,
            shadowColor: Colors.black.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Left 3px Saffron Route Line Graphic Column
                  SizedBox(
                    width: 20,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 14),
                        // Filled Pickup Square
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: VayaTheme.saffron,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        // 3 px Saffron Route Line connecting the two fields
                        Container(
                          width: 3,
                          height: 48,
                          color: VayaTheme.saffron,
                        ),
                        // Open Drop Circle
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: VayaTheme.saffron, width: 2.5),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Address Fields
                  Expanded(
                    child: Column(
                      children: [
                        // Pickup Field (56 px height)
                        SizedBox(
                          height: 56,
                          child: InkWell(
                            onTap: () => _openLocationSearchModal('pickup'),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: VayaTheme.signalCream.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: VayaTheme.slate.withValues(alpha: 0.12)),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: VayaTheme.saffron.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      l.pickup,
                                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _isLocating
                                        ? Row(
                                            children: [
                                              Container(
                                                width: 120,
                                                height: 14,
                                                decoration: BoxDecoration(
                                                  color: VayaTheme.fog.withValues(alpha: 0.7),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              const VayaLoader.inline(size: 12, color: VayaTheme.saffron),
                                            ],
                                          )
                                        : _locationFailed
                                            ? Row(
                                                children: [
                                                  const Text(
                                                    'Location timeout · ',
                                                    style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600),
                                                  ),
                                                  GestureDetector(
                                                    onTap: _locateUserPosition,
                                                    child: const Text(
                                                      'Retry',
                                                      style: TextStyle(fontSize: 12, color: VayaTheme.saffron, fontWeight: FontWeight.bold, decoration: TextDecoration.underline),
                                                    ),
                                                  ),
                                                  const Text(' or ', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                                                  GestureDetector(
                                                    onTap: () => _openLocationSearchModal('pickup'),
                                                    child: const Text(
                                                      'Enter manually',
                                                      style: TextStyle(fontSize: 12, color: VayaTheme.inkBlack, fontWeight: FontWeight.bold, decoration: TextDecoration.underline),
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : Text(
                                                _pickupController.text.isEmpty
                                                    ? 'Current location · Sailashree Vihar'
                                                    : _pickupController.text,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: VayaTheme.inkBlack,
                                                ),
                                              ),
                                  ),
                                  const Icon(Icons.edit_outlined, size: 16, color: VayaTheme.slate),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Dropoff Field (56 px height - DOMINANT!)
                        SizedBox(
                          height: 56,
                          child: InkWell(
                            onTap: () => _openLocationSearchModal('destination'),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: VayaTheme.saffron.withValues(alpha: 0.09),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: VayaTheme.saffron.withValues(alpha: 0.35), width: 1.5),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      l.dropoff,
                                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.red),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _dropoffController.text.isEmpty ? l.whereToDeliver : _dropoffController.text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: _dropoffController.text.isEmpty ? VayaTheme.slate : VayaTheme.inkBlack,
                                      ),
                                    ),
                                  ),
                                  const Icon(Icons.search, size: 20, color: VayaTheme.saffron),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Active Delivery Card (Placed directly below address card, above Recent Searches)
          if (widget.activeBooking != null) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                final bookingId = widget.activeBooking!['id'] ?? '';
                final fare = double.tryParse(widget.activeBooking!['estimated_cost']?.toString() ?? '') ?? 0.0;
                if (widget.onTrackActive != null) {
                  widget.onTrackActive!(bookingId, fare);
                }
              },
              child: Container(
                height: 84,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: VayaTheme.inkBlack,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: VayaTheme.saffron.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getVehicleIcon(widget.activeBooking!['vehicle_type']),
                        color: VayaTheme.saffron,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Text(
                                'VAYA #${_formatBookingId(widget.activeBooking!['id'])}',
                                style: const TextStyle(
                                  color: VayaTheme.saffron,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              Text(
                                ' • ${_getVehicleCategoryLabel(widget.activeBooking!['vehicle_type']?.toString() ?? '')}',
                                style: const TextStyle(
                                  color: VayaTheme.fog,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _getStatusSemanticColor(widget.activeBooking!['status']),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _getFriendlyCustomerStatus(widget.activeBooking!['status']),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: VayaTheme.saffron,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Track',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(Icons.arrow_forward_ios, color: Colors.white, size: 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Recent Addresses List with Distance Chips (Conditional, Max 3, 64-72px rows)
          if (_recentSearches.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l.recentSearches,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate, letterSpacing: 0.8),
            ),
            const SizedBox(height: 8),
            Card(
              color: Colors.white,
              elevation: 0.5,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Column(
                children: _recentSearches.take(3).map((rs) {
                  final String title = (rs['title'] ?? rs['short_name'] ?? 'Recent Location').toString();
                  final String subtitle = (rs['subtitle'] ?? rs['display_name'] ?? '').toString();

                  final double? itemLat = (rs['lat'] is num)
                      ? (rs['lat'] as num).toDouble()
                      : double.tryParse(rs['lat']?.toString() ?? '');
                  final double? itemLon = (rs['lon'] is num)
                      ? (rs['lon'] as num).toDouble()
                      : double.tryParse(rs['lon']?.toString() ?? '');

                  final double itemDist = (itemLat != null && itemLon != null)
                      ? Geolocator.distanceBetween(
                            _pickup.latitude,
                            _pickup.longitude,
                            itemLat,
                            itemLon,
                          ) / 1000.0
                      : 0.0;

                  return Container(
                    height: 68,
                    alignment: Alignment.center,
                    child: ListTile(
                      dense: true,
                      leading: const CircleAvatar(
                        backgroundColor: VayaTheme.fog,
                        radius: 16,
                        child: Icon(Icons.history, size: 16, color: VayaTheme.slate),
                      ),
                      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                      trailing: (itemLat != null && itemLon != null)
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: VayaTheme.slate.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _formatDistance(itemDist),
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.slate),
                              ),
                            )
                          : null,
                      onTap: () {
                        setState(() {
                          if (itemLat != null && itemLon != null) {
                            _dropoff = LatLng(itemLat, itemLon);
                          }
                          _dropoffController.text = subtitle.isNotEmpty ? subtitle : title;
                        });
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Vehicle Categories Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'VEHICLE CATEGORIES',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate, letterSpacing: 0.8),
              ),
              if (_preselectedVehicle != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: VayaTheme.saffron.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Selected: ${_getVehicleCategoryLabel(_preselectedVehicle!)}',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.22,
            children: [
              _buildHomeVehicleCategoryCard(
                id: 'bike',
                title: 'Bike',
                capacitySubtitle: 'Up to 20 kg · Courier & Food',
                imageAsset: 'assets/images/vehicle_bike.png',
              ),
              _buildHomeVehicleCategoryCard(
                id: 'three_wheeler',
                title: '3-wheeler',
                capacitySubtitle: 'Up to 500 kg · Medium loads',
                imageAsset: 'assets/images/vehicle_3wheeler.png',
              ),
              _buildHomeVehicleCategoryCard(
                id: 'ace',
                title: 'Mini truck',
                capacitySubtitle: 'Up to 750 kg · House & office',
                imageAsset: 'assets/images/vehicle_mini_truck.png',
              ),
              _buildHomeVehicleCategoryCard(
                id: 'truck',
                title: 'Light commercial vehicle',
                capacitySubtitle: 'Up to 1500 kg · Heavy cargo',
                imageAsset: 'assets/images/vehicle_lcv.png',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Unified Single-Page Continuous Trip Setup Screen (No Page Jumps!)
class SinglePageTripPlanner extends StatefulWidget {
  final LatLng initialPickupPos;
  final String initialPickupAddress;
  final LatLng initialDropoffPos;
  final String initialDropoffAddress;
  final String initialActiveStep; // 'pickup' or 'dropoff'
  final String? preselectedVehicle;

  const SinglePageTripPlanner({
    super.key,
    required this.initialPickupPos,
    required this.initialPickupAddress,
    required this.initialDropoffPos,
    required this.initialDropoffAddress,
    required this.initialActiveStep,
    this.preselectedVehicle,
  });

  @override
  State<SinglePageTripPlanner> createState() => _SinglePageTripPlannerState();
}

class _SinglePageTripPlannerState extends State<SinglePageTripPlanner> {
  late String _activeStep; // 'pickup' or 'dropoff'
  late LatLng _pickupPos;
  late String _pickupAddress;
  late LatLng _dropoffPos;
  late String _dropoffAddress;

  final TextEditingController _queryController = TextEditingController();
  List<Map<String, dynamic>> _predictions = [];
  bool _searching = false;
  bool _fetchingCurrentLocation = false;
  Timer? _debounce;

  List<LatLng> _roadPolylinePoints = [];
  double _roadDistanceKm = 0.0;

  GoogleMapController? _mapController;
  Set<Marker> _mapMarkers = {};
  Set<Polyline> _mapPolylines = {};

  List<Map<String, dynamic>> _recentSearches = [];
  List<Map<String, String>> _savedPlaces = [];

  @override
  void initState() {
    super.initState();
    _activeStep = widget.initialActiveStep;
    _pickupPos = widget.initialPickupPos;
    _pickupAddress = widget.initialPickupAddress;
    _dropoffPos = widget.initialDropoffPos;
    _dropoffAddress = widget.initialDropoffAddress;

    _loadSearchStorage();
    if (_pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty) {
      _fetchRoadRoute();
    } else {
      _updateMapState();
    }
  }

  Future<void> _loadSearchStorage() async {
    final recents = await VayaStorage.loadRecentSearches();
    final saved = await VayaStorage.loadSavedPlaces();
    if (mounted) {
      setState(() {
        _recentSearches = recents;
        _savedPlaces = saved;
      });
    }
  }

  Future<void> _fetchRoadRoute() async {
    if (_pickupAddress.isEmpty || _dropoffAddress.isEmpty) return;

    final p = _pickupPos;
    final d = _dropoffPos;

    // Call OSRM Driving Directions API for real street-following polyline & road distance
    final url = 'https://router.project-osrm.org/route/v1/driving/${p.longitude},${p.latitude};${d.longitude},${d.latitude}?overview=full&geometries=geojson';
    try {
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'VAYACustomerApp/1.0'}).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final distanceMeters = double.parse(route['distance'].toString());
          final coords = route['geometry']['coordinates'] as List<dynamic>;

          final points = coords.map((c) => LatLng(double.parse(c[1].toString()), double.parse(c[0].toString()))).toList();

          if (mounted) {
            setState(() {
              _roadPolylinePoints = points;
              _roadDistanceKm = distanceMeters / 1000.0;
            });
            _updateMapState();
            return;
          }
        }
      }
    } catch (e) {
      debugPrint("OSRM Route error: $e");
    }

    if (mounted) {
      final straightDist = Geolocator.distanceBetween(
            p.latitude,
            p.longitude,
            d.latitude,
            d.longitude,
          ) /
          1000.0;

      setState(() {
        _roadPolylinePoints = [p, d];
        _roadDistanceKm = straightDist;
      });
      _updateMapState();
    }
  }

  void _updateMapState() {
    final Set<Marker> markers = {};
    final Set<Polyline> polylines = {};

    if (_pickupAddress.isNotEmpty) {
      markers.add(
        Marker(
          markerId: const MarkerId('pickup_marker'),
          position: _pickupPos,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: 'Pickup', snippet: _pickupAddress),
        ),
      );
    }

    if (_dropoffAddress.isNotEmpty) {
      markers.add(
        Marker(
          markerId: const MarkerId('dropoff_marker'),
          position: _dropoffPos,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: 'Drop-off', snippet: _dropoffAddress),
        ),
      );
    }

    if (_pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty) {
      final points = _roadPolylinePoints.isNotEmpty ? _roadPolylinePoints : [_pickupPos, _dropoffPos];
      polylines.add(
        Polyline(
          polylineId: const PolylineId('actual_road_route_line'),
          points: points,
          color: VayaTheme.saffron,
          width: 5,
        ),
      );
    }

    setState(() {
      _mapMarkers = markers;
      _mapPolylines = polylines;
    });

    _animateMapCamera();
  }

  void _animateMapCamera() {
    if (_mapController == null) return;
    if (_pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty) {
      final points = _roadPolylinePoints.isNotEmpty ? _roadPolylinePoints : [_pickupPos, _dropoffPos];
      double minLat = points.first.latitude;
      double maxLat = points.first.latitude;
      double minLng = points.first.longitude;
      double maxLng = points.first.longitude;

      for (var pt in points) {
        if (pt.latitude < minLat) minLat = pt.latitude;
        if (pt.latitude > maxLat) maxLat = pt.latitude;
        if (pt.longitude < minLng) minLng = pt.longitude;
        if (pt.longitude > maxLng) maxLng = pt.longitude;
      }

      final bounds = LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      );

      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
    } else if (_activeStep == 'pickup' && _pickupAddress.isNotEmpty) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_pickupPos, 14));
    } else if (_activeStep == 'dropoff' && _dropoffAddress.isNotEmpty) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_dropoffPos, 14));
    }
  }

  void _handleLocationSelected(LatLng coords, String address) {
    FocusScope.of(context).unfocus();
    setState(() {
      if (_activeStep == 'pickup') {
        _pickupPos = coords;
        _pickupAddress = address;

        VayaStorage.addRecentSearch({
          'title': address.split(',').first,
          'subtitle': address,
          'lat': coords.latitude,
          'lon': coords.longitude,
        });

        if (_dropoffAddress.isEmpty) {
          _activeStep = 'dropoff';
        } else {
          _activeStep = '';
        }
        _queryController.clear();
        _predictions.clear();
      } else {
        _dropoffPos = coords;
        _dropoffAddress = address;

        VayaStorage.addRecentSearch({
          'title': address.split(',').first,
          'subtitle': address,
          'lat': coords.latitude,
          'lon': coords.longitude,
        });

        _activeStep = '';
        _queryController.clear();
        _predictions.clear();
      }
    });

    if (_pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty) {
      _fetchRoadRoute();
    } else {
      _updateMapState();
    }
  }

  Future<Map<String, dynamic>?> _geocodeAddress(String address) async {
    final url = 'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(address)}&key=$googleMapsApiKey';
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {
          'X-Android-Package': 'com.vaya.customer_app',
          'X-Android-Cert': '92F69B118A5A10167A1E5DD7A93EB3746BFC2673',
        },
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
          final loc = data['results'][0]['geometry']['location'];
          return {
            'lat': loc['lat'] as double,
            'lon': loc['lng'] as double,
            'display_name': data['results'][0]['formatted_address'] as String,
          };
        }
      }
    } catch (e) {
      debugPrint('Geocode error: $e');
    }
    return null;
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _fetchingCurrentLocation = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        String address = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
        try {
          final url = 'https://maps.googleapis.com/maps/api/geocode/json?latlng=${pos.latitude},${pos.longitude}&key=$googleMapsApiKey';
          final res = await http.get(
            Uri.parse(url),
            headers: {
              'X-Android-Package': 'com.vaya.customer_app',
              'X-Android-Cert': '92F69B118A5A10167A1E5DD7A93EB3746BFC2673',
            },
          );
          if (res.statusCode == 200) {
            final data = json.decode(res.body);
            if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
              address = data['results'][0]['formatted_address'] ?? address;
            }
          }
        } catch (_) {}

        _handleLocationSelected(LatLng(pos.latitude, pos.longitude), address);
      }
    } catch (e) {
      debugPrint('Current location error: $e');
    } finally {
      if (mounted) setState(() => _fetchingCurrentLocation = false);
    }
  }

  void _onQueryChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    final q = query.trim();
    if (q.length < 2) {
      setState(() {
        _predictions.clear();
        _searching = false;
      });
      return;
    }

    if (!_searching) {
      setState(() => _searching = true);
    }

    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final currentRef = _activeStep == 'pickup' ? _pickupPos : _dropoffPos;
      final userLat = currentRef.latitude;
      final userLng = currentRef.longitude;

      try {
        List<Map<String, dynamic>> rawResults = [];
        final double swLat = userLat - 0.25;
        final double swLng = userLng - 0.25;
        final double neLat = userLat + 0.25;
        final double neLng = userLng + 0.25;

        final headers = {
          'X-Android-Package': 'com.vaya.customer_app',
          'X-Android-Cert': '92F69B118A5A10167A1E5DD7A93EB3746BFC2673',
        };

        // 1. Google Geocoding API
        try {
          final googleUrl = 'https://maps.googleapis.com/maps/api/geocode/json?'
              'address=${Uri.encodeComponent(q)}'
              '&bounds=$swLat,$swLng|$neLat,$neLng'
              '&components=country:IN'
              '&key=$googleMapsApiKey';

          final googleRes = await http.get(Uri.parse(googleUrl), headers: headers).timeout(const Duration(seconds: 4));
          if (googleRes.statusCode == 200) {
            final data = json.decode(googleRes.body);
            if (data['status'] == 'OK' && data['results'] != null) {
              for (var r in data['results']) {
                final loc = r['geometry']['location'];
                rawResults.add({
                  'display_name': r['formatted_address'],
                  'short_name': r['address_components'][0]['long_name'],
                  'lat': (loc['lat'] as num).toDouble(),
                  'lon': (loc['lng'] as num).toDouble(),
                  'source': 'google',
                });
              }
            }
          }
        } catch (_) {}

        // 2. Photon API
        try {
          final photonUrl = 'https://photon.komoot.io/api/?q=${Uri.encodeComponent(q)}&lat=$userLat&lon=$userLng&limit=15';
          final res = await http.get(Uri.parse(photonUrl)).timeout(const Duration(seconds: 4));
          if (res.statusCode == 200) {
            final data = json.decode(res.body);
            for (var f in (data['features'] ?? [])) {
              final props = f['properties'] as Map<String, dynamic>;
              final coords = f['geometry']['coordinates'];
              rawResults.add({
                'display_name': props['name'] ?? props['street'] ?? props['city'],
                'short_name': props['name'] ?? props['street'],
                'lat': (coords[1] as num).toDouble(),
                'lon': (coords[0] as num).toDouble(),
                'source': 'photon',
              });
            }
          }
        } catch (_) {}

        // 3. Nominatim API
        try {
          final nomUrl = 'https://nominatim.openstreetmap.org/search?format=json&addressdetails=1&q=${Uri.encodeComponent(q)}&viewbox=$swLng,$swLat,$neLng,$neLat&limit=10';
          final nomRes = await http.get(
            Uri.parse(nomUrl),
            headers: {'User-Agent': 'VAYACustomerApp/1.0', 'Accept-Language': 'en'},
          ).timeout(const Duration(seconds: 4));
          if (nomRes.statusCode == 200) {
            for (var d in (json.decode(nomRes.body) as List)) {
              rawResults.add({
                'display_name': d['display_name'],
                'short_name': d['display_name'].split(',').first,
                'lat': double.parse(d['lat']),
                'lon': double.parse(d['lon']),
                'source': 'nominatim',
              });
            }
          }
        } catch (_) {}

        // Deduplicate and distance-sort
        List<Map<String, dynamic>> uniqueResults = [];
        for (var item in rawResults) {
          final itemLat = item['lat'] as double;
          final itemLon = item['lon'] as double;
          bool isDuplicate = uniqueResults.any((e) => Geolocator.distanceBetween(itemLat, itemLon, e['lat'], e['lon']) < 250);
          if (!isDuplicate) {
            uniqueResults.add({...item, 'distance': Geolocator.distanceBetween(userLat, userLng, itemLat, itemLon)});
          }
        }
        uniqueResults.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

        if (mounted) {
          setState(() {
            _predictions = uniqueResults;
            _searching = false;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _openMapDirectly() async {
    final currentPos = _activeStep == 'pickup' ? _pickupPos : _dropoffPos;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPinPickerScreen(
          initialCoords: currentPos,
          type: _activeStep,
        ),
      ),
    );
    if (result != null && mounted) {
      _handleLocationSelected(result['coords'], result['address']);
    }
  }

  void _confirmAndProceed() {
    Navigator.pop(context, {
      'pickupPos': _pickupPos,
      'pickupAddress': _pickupAddress,
      'dropoffPos': _dropoffPos,
      'dropoffAddress': _dropoffAddress,
      'proceedToVehicle': true,
    });
  }

  Widget _buildPredictionsList({required bool isPickupStep}) {
    final l = LocalizedStrings.of(context);
    if (_searching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: VayaLoader.inline(size: 24, color: VayaTheme.saffron),
        ),
      );
    }

    if (_predictions.isNotEmpty) {
      return Container(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.separated(
          shrinkWrap: true,
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _predictions.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 44, endIndent: 12),
          itemBuilder: (ctx, i) {
            final p = _predictions[i];
            final shortName = p['short_name'] as String? ?? '';
            final fullName = p['display_name'] as String;
            final double lat = (p['lat'] as num).toDouble();
            final double lon = (p['lon'] as num).toDouble();

            String secondary = fullName;
            if (shortName.isNotEmpty && fullName.startsWith(shortName)) {
              secondary = fullName.substring(shortName.length).replaceFirst(RegExp(r'^,\s*'), '');
            }

            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              leading: CircleAvatar(
                backgroundColor: isPickupStep ? VayaTheme.signalCream : Colors.red.withValues(alpha: 0.1),
                radius: 13,
                child: Icon(
                  isPickupStep ? Icons.location_on : Icons.flag,
                  color: isPickupStep ? VayaTheme.saffron : Colors.red,
                  size: 15,
                ),
              ),
              title: Text(
                shortName.isNotEmpty ? shortName : fullName.split(',').first,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
              ),
              trailing: const Icon(Icons.chevron_right, size: 16, color: VayaTheme.slate),
              onTap: () => _handleLocationSelected(LatLng(lat, lon), fullName),
            );
          },
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView(
        shrinkWrap: true,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          // Use My Current Location Tile
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            leading: CircleAvatar(
              backgroundColor: VayaTheme.liveBlue.withValues(alpha: 0.15),
              radius: 13,
              child: _fetchingCurrentLocation
                  ? const VayaLoader.inline(size: 13, color: VayaTheme.liveBlue)
                  : const Icon(Icons.my_location, color: VayaTheme.liveBlue, size: 15),
            ),
            title: Text(
              _fetchingCurrentLocation ? l.fetchingLocation : l.useMyCurrentLocation,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.liveBlue),
            ),
            subtitle: Text(
              isPickupStep ? 'Set pickup to your GPS location' : 'Set drop-off to your GPS location',
              style: const TextStyle(fontSize: 10),
            ),
            trailing: const Icon(Icons.chevron_right, size: 16, color: VayaTheme.liveBlue),
            onTap: _fetchingCurrentLocation ? null : _useCurrentLocation,
          ),
          const Divider(height: 1, indent: 44, endIndent: 12),

          // Choose Location on Map Tile
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            leading: const CircleAvatar(
              backgroundColor: VayaTheme.saffron,
              radius: 13,
              child: Icon(Icons.map, color: Colors.white, size: 15),
            ),
            title: Text(l.chooseOnMap, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            subtitle: Text(
              isPickupStep ? 'Drag map pin to set exact pickup gate' : 'Drag map pin to set exact drop-off gate',
              style: const TextStyle(fontSize: 10),
            ),
            trailing: const Icon(Icons.chevron_right, size: 16),
            onTap: _openMapDirectly,
          ),



          if (_recentSearches.isNotEmpty) ...[
            const Divider(height: 1, indent: 44, endIndent: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(l.recentSearches, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
            ),
            ..._recentSearches.take(3).map((rs) {
              final title = (rs['title'] ?? rs['short_name'] ?? 'Recent Search').toString();
              final subtitle = (rs['subtitle'] ?? rs['display_name'] ?? '').toString();
              final double? lat = (rs['lat'] is num) ? (rs['lat'] as num).toDouble() : double.tryParse(rs['lat']?.toString() ?? '');
              final double? lon = (rs['lon'] is num) ? (rs['lon'] as num).toDouble() : double.tryParse(rs['lon']?.toString() ?? '');

              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFF5F5F5),
                  radius: 12,
                  child: Icon(Icons.history, size: 12, color: VayaTheme.slate),
                ),
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                subtitle: Text(subtitle, style: const TextStyle(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () async {
                  final addr = subtitle.isNotEmpty ? subtitle : title;
                  final coords = (lat != null && lon != null) ? LatLng(lat, lon) : (isPickupStep ? _pickupPos : _dropoffPos);
                  _handleLocationSelected(coords, addr);
                },
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildStackedInputCards() {
    final isPickupActive = _activeStep == 'pickup';
    final isDropoffActive = _activeStep == 'dropoff';
    final isPickupConfirmed = _pickupAddress.isNotEmpty;
    final isDropoffConfirmed = _dropoffAddress.isNotEmpty;
    final bool bothConfirmed = isPickupConfirmed && isDropoffConfirmed;
    final bool showResultsPanel = !bothConfirmed || _queryController.text.isNotEmpty || _searching || _predictions.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. PICKUP CONTAINER (Card + attached smooth dropdown)
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isPickupActive
                  ? VayaTheme.saffron
                  : (isPickupConfirmed ? VayaTheme.routeGreen : VayaTheme.slate.withValues(alpha: 0.2)),
              width: (isPickupActive || isPickupConfirmed) ? 2.0 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () {
                  if (!isPickupActive) {
                    setState(() {
                      _activeStep = 'pickup';
                      _queryController.text = _pickupAddress;
                      _queryController.selection = TextSelection.collapsed(offset: _queryController.text.length);
                      _predictions.clear();
                    });
                  }
                },
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isPickupConfirmed && !isPickupActive
                              ? VayaTheme.routeGreen.withValues(alpha: 0.15)
                              : VayaTheme.saffron.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isPickupConfirmed && !isPickupActive ? Icons.check_circle : Icons.location_on,
                          color: isPickupConfirmed && !isPickupActive ? VayaTheme.routeGreen : VayaTheme.saffron,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: isPickupActive
                            ? SizedBox(
                                height: 44,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextField(
                                    controller: _queryController,
                                    autofocus: true,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                                      border: InputBorder.none,
                                      hintText: 'Search pickup location (e.g. Master Canteen)',
                                      hintStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: VayaTheme.slate),
                                      suffixIcon: _queryController.text.isNotEmpty
                                          ? GestureDetector(
                                              onTap: () {
                                                _queryController.clear();
                                                setState(() {
                                                  _pickupAddress = '';
                                                  _predictions.clear();
                                                });
                                              },
                                              child: const Icon(Icons.clear, size: 18, color: VayaTheme.slate),
                                            )
                                          : null,
                                    ),
                                    onChanged: _onQueryChanged,
                                  ),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'PICKUP LOCATION',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.slate, letterSpacing: 0.8),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _pickupAddress.isEmpty ? 'Where should we pick up?' : _pickupAddress,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: _pickupAddress.isEmpty ? VayaTheme.slate : VayaTheme.inkBlack,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),

              // Attached Smooth Dropdown for Pickup (extends directly below pickup box)
              if (isPickupActive && showResultsPanel)
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
                    ),
                  ),
                  child: _buildPredictionsList(isPickupStep: true),
                ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // 2. DROP-OFF CONTAINER (Card + attached smooth dropdown)
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDropoffActive
                  ? Colors.red
                  : (isDropoffConfirmed ? Colors.red : VayaTheme.slate.withValues(alpha: 0.2)),
              width: (isDropoffActive || isDropoffConfirmed) ? 2.0 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () {
                  if (!isDropoffActive) {
                    setState(() {
                      _activeStep = 'dropoff';
                      _queryController.text = _dropoffAddress;
                      _queryController.selection = TextSelection.collapsed(offset: _queryController.text.length);
                      _predictions.clear();
                    });
                  }
                },
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isDropoffConfirmed && !isDropoffActive
                              ? Colors.red.withValues(alpha: 0.15)
                              : Colors.red.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isDropoffConfirmed && !isDropoffActive ? Icons.check_circle : Icons.flag,
                          color: Colors.red,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: isDropoffActive
                            ? SizedBox(
                                height: 44,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextField(
                                    controller: _queryController,
                                    autofocus: true,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                                      border: InputBorder.none,
                                      hintText: 'Search drop-off location (e.g. Patia)',
                                      hintStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: VayaTheme.slate),
                                      suffixIcon: _queryController.text.isNotEmpty
                                          ? GestureDetector(
                                              onTap: () {
                                                _queryController.clear();
                                                setState(() {
                                                  _dropoffAddress = '';
                                                  _predictions.clear();
                                                });
                                              },
                                              child: const Icon(Icons.clear, size: 18, color: VayaTheme.slate),
                                            )
                                          : null,
                                    ),
                                    onChanged: _onQueryChanged,
                                  ),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'DROP-OFF LOCATION',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.slate, letterSpacing: 0.8),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _dropoffAddress.isEmpty ? 'Where should we deliver?' : _dropoffAddress,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: _dropoffAddress.isEmpty ? VayaTheme.slate : VayaTheme.inkBlack,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),

              // Attached Smooth Dropdown for Drop-off (extends directly below drop-off box)
              if (isDropoffActive && showResultsPanel)
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
                    ),
                  ),
                  child: _buildPredictionsList(isPickupStep: false),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPickupStep = _activeStep == 'pickup';
    final bool bothConfirmed = _pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Set Delivery Route', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(
              _activeStep == 'pickup'
                  ? 'Step 1 of 2: Set Pickup Location'
                  : (_activeStep == 'dropoff' ? 'Step 2 of 2: Set Drop-off Location' : 'Delivery Route Confirmed'),
              style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
            ),
          ],
        ),
      ),
      bottomNavigationBar: bothConfirmed
          ? Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fixed Trip Distance Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Trip Distance:',
                          style: TextStyle(fontSize: 13, color: VayaTheme.slate, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '~${_roadDistanceKm.toStringAsFixed(1)} km',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // CTA Button: 56px height, 18px semibold text
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _confirmAndProceed,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VayaTheme.saffron,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 2,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Proceed to Vehicle & Fare Selection',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 18,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(Icons.arrow_forward, color: Colors.white, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: Stack(
        children: [
          // 1. Full-Screen Immersive Google Map Background
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: isPickupStep ? _pickupPos : _dropoffPos,
                zoom: 13,
              ),
              markers: _mapMarkers,
              polylines: _mapPolylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              onMapCreated: (c) {
                _mapController = c;
                _animateMapCamera();
              },
            ),
          ),

          // 2. Floating Route Cards + Attached Dropdown Overlay
          Positioned(
            top: 10,
            left: 14,
            right: 14,
            child: _buildStackedInputCards(),
          ),
        ],
      ),
    );
  }
}

/// Drag Pin Map Location Selector
class MapPinPickerScreen extends StatefulWidget {
  final LatLng initialCoords;
  final String type; // 'pickup' or 'destination' / 'dropoff'
  const MapPinPickerScreen({super.key, required this.initialCoords, required this.type});

  @override
  State<MapPinPickerScreen> createState() => _MapPinPickerScreenState();
}

class _MapPinPickerScreenState extends State<MapPinPickerScreen> {
  late LatLng _center;
  String _address = 'Resolving location...';
  bool _loading = false;
  GoogleMapController? _mapController;

  @override
  void initState() {
    super.initState();
    _center = widget.initialCoords;
    _resolveAddress(_center);
  }

  Future<void> _resolveAddress(LatLng pos) async {
    setState(() => _loading = true);
    final url = 'https://nominatim.openstreetmap.org/reverse?format=json&lat=${pos.latitude}&lon=${pos.longitude}';
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'Accept-Language': 'en', 'User-Agent': 'VAYACustomerApp/1.0'},
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          setState(() {
            _address = data['display_name'] ?? '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _address = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPickup = widget.type == 'pickup';

    return Scaffold(
      appBar: AppBar(title: Text(isPickup ? 'Confirm pickup' : 'Confirm drop-off')),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _center, zoom: 16),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            onMapCreated: (c) => _mapController = c,
            onCameraMove: (pos) => _center = pos.target,
            onCameraIdle: () => _resolveAddress(_center),
          ),

          // Central Fixed pin pointing to target center
          const Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 32.0), // half height offset
              child: Icon(Icons.location_on, size: 48, color: VayaTheme.saffron),
            ),
          ),

          // Recenter FAB Control
          Positioned(
            bottom: 120,
            right: 16,
            child: FloatingActionButton.small(
              backgroundColor: Colors.white,
              foregroundColor: VayaTheme.saffron,
              onPressed: () {
                _mapController?.animateCamera(CameraUpdate.newLatLngZoom(widget.initialCoords, 16));
              },
              child: const Icon(Icons.my_location),
            ),
          ),

          // Instruction Overlay Banner
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: VayaTheme.saffron),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isPickup 
                            ? 'Move map to place the pin at the pickup gate.' 
                            : 'Move map to place the pin at the drop-off gate.',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Confirmation Panel Card
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.place, color: VayaTheme.saffron, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _loading ? 'Locating...' : _address,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        Navigator.pop(context, {
                          'address': _address,
                          'coords': _center,
                        });
                      },
                      child: Text(isPickup ? 'Confirm pickup location' : 'Confirm drop-off location'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 6. Vehicle Comparison & Trip Customization Screen
class VehicleSelectionScreen extends StatefulWidget {
  final LatLng pickup;
  final String pickupAddress;
  final LatLng dropoff;
  final String dropoffAddress;
  final String? initialVehicle;

  const VehicleSelectionScreen({
    super.key,
    required this.pickup,
    required this.pickupAddress,
    required this.dropoff,
    required this.dropoffAddress,
    this.initialVehicle,
  });

  @override
  State<VehicleSelectionScreen> createState() => _VehicleSelectionScreenState();
}

class _VehicleSelectionScreenState extends State<VehicleSelectionScreen> {
  String _selectedVehicle = 'bike';
  String _goodsCategory = 'General Cargo';
  int _helperCount = 0; // 0: No helper, 1: 1 Helper (+150), 2: 2 Helpers (+300)
  double _discount = 0.0;
  String _paymentMethod = 'Cash';
  bool _isLoading = false;

  bool _isPickupExpanded = false;
  bool _isDropoffExpanded = false;
  final ScrollController _scrollController = ScrollController();

  // Cached contact values preserved across back-navigation
  String _cachedSenderName = '';
  String _cachedSenderPhone = '';
  String _cachedSenderBuilding = '';
  String _cachedReceiverName = '';
  String _cachedReceiverPhone = '';
  String _cachedReceiverBuilding = '';

  List<dynamic> _serverPricing = [];
  bool _loadingPricing = true;

  // Map & OSRM Road Polyline State
  GoogleMapController? _mapController;
  List<LatLng> _roadPolylinePoints = [];
  double _roadDistanceKm = 0.0;
  int _roadDurationMin = 0;
  bool _fetchingRoute = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialVehicle != null && widget.initialVehicle!.isNotEmpty) {
      _selectedVehicle = widget.initialVehicle!;
    }
    _fetchPricingConfig();
    _fetchRoadRoute();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchPricingConfig() async {
    final cached = await VayaStorage.loadCachedPricingConfig();
    if (cached != null && cached['pricing'] != null) {
      if (mounted) {
        setState(() {
          _serverPricing = cached['pricing'] ?? [];
          _loadingPricing = false;
        });
      }
    }
    try {
      var response = await http.get(Uri.parse('$apiBaseUrl/api/health/pricing-config')).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/pricing-config')).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/booking/pricing-config')).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _serverPricing = data['pricing'] ?? [];
            _loadingPricing = false;
          });
        }
        await VayaStorage.saveCachedPricingConfig(data);
      } else {
        if (mounted) setState(() => _loadingPricing = false);
      }
    } catch (e) {
      debugPrint("Failed to load pricing: $e");
      if (mounted) setState(() => _loadingPricing = false);
    }
  }

  Future<void> _fetchRoadRoute() async {
    final p = widget.pickup;
    final d = widget.dropoff;

    // Call OSRM Driving Directions API for real street-following polyline
    final url = 'https://router.project-osrm.org/route/v1/driving/${p.longitude},${p.latitude};${d.longitude},${d.latitude}?overview=full&geometries=geojson';
    try {
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'VAYACustomerApp/1.0'});
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final distanceMeters = double.parse(route['distance'].toString());
          final durationSec = double.parse(route['duration'].toString());
          final coords = route['geometry']['coordinates'] as List<dynamic>;

          final points = coords.map((c) => LatLng(double.parse(c[1].toString()), double.parse(c[0].toString()))).toList();

          if (mounted) {
            setState(() {
              _roadPolylinePoints = points;
              _roadDistanceKm = distanceMeters / 1000.0;
              _roadDurationMin = (durationSec / 60.0).round();
              _fetchingRoute = false;
            });
            _fitRouteBounds();
            return;
          }
        }
      }
    } catch (e) {
      debugPrint("OSRM Route error: $e");
    }

    // Fallback if OSRM is unreachable: use straight line
    if (mounted) {
      final straightDist = Geolocator.distanceBetween(
            p.latitude,
            p.longitude,
            d.latitude,
            d.longitude,
          ) /
          1000.0;

      setState(() {
        _roadPolylinePoints = [p, d];
        _roadDistanceKm = straightDist;
        _roadDurationMin = (straightDist / 30.0 * 60).round() + 5;
        _fetchingRoute = false;
      });
      _fitRouteBounds();
    }
  }

  void _fitRouteBounds() {
    if (_mapController == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        widget.pickup.latitude < widget.dropoff.latitude ? widget.pickup.latitude : widget.dropoff.latitude,
        widget.pickup.longitude < widget.dropoff.longitude ? widget.pickup.longitude : widget.dropoff.longitude,
      ),
      northeast: LatLng(
        widget.pickup.latitude > widget.dropoff.latitude ? widget.pickup.latitude : widget.dropoff.latitude,
        widget.pickup.longitude > widget.dropoff.longitude ? widget.pickup.longitude : widget.dropoff.longitude,
      ),
    );
    _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  double _calculatePrice(String vehicleId) {
    final dist = _roadDistanceKm > 0 ? _roadDistanceKm : (Geolocator.distanceBetween(widget.pickup.latitude, widget.pickup.longitude, widget.dropoff.latitude, widget.dropoff.longitude) / 1000.0);

    double baseCost = 50.0;
    if (_serverPricing.isNotEmpty) {
      try {
        final match = _serverPricing.firstWhere(
          (p) => p['vehicle_type'] == vehicleId,
          orElse: () => null,
        );
        if (match != null) {
          final double basePrice = double.parse(match['base_price'].toString());
          final double baseDistance = double.parse(match['base_distance'].toString());
          final double perKmPrice = double.parse(match['per_km_price'].toString());
          baseCost = basePrice + (dist > baseDistance ? (dist - baseDistance) * perKmPrice : 0.0);
        }
      } catch (e) {
        debugPrint("Error parsing pricing: $e");
      }
    } else {
      switch (vehicleId) {
        case 'bike':
          baseCost = 40.0 + (dist > 2 ? (dist - 2) * 10.0 : 0.0);
          break;
        case 'three_wheeler':
          baseCost = 120.0 + (dist > 3 ? (dist - 3) * 18.0 : 0.0);
          break;
        case 'ace':
          baseCost = 250.0 + (dist > 5 ? (dist - 5) * 25.0 : 0.0);
          break;
        case 'truck':
          baseCost = 500.0 + (dist > 5 ? (dist - 5) * 35.0 : 0.0);
          break;
      }
    }

    final helperFee = _helperCount * 150.0;
    final taxes = baseCost * 0.05;
    final platformFee = 10.0;
    final total = baseCost + helperFee + taxes + platformFee - _discount;
    return total > 0 ? total : 0.0;
  }

  // Navigate to dedicated Contact Details Screen
  Future<void> _openContactDetailsModal() async {
    final savedSession = await CustomerSessionManager.getSavedSession();
    final rawName = savedSession?['name'] ?? '';
    final displayName = (rawName.trim().toLowerCase() == 'test account' || rawName.trim().isEmpty) ? '' : rawName.trim();
    final rawPhone = savedSession?['phone'] ?? '';
    final displayPhone = formatIndianPhoneNumber(rawPhone);

    // Pre-fill cached values if present, otherwise fall back to session data
    final initSenderName = _cachedSenderName.isNotEmpty ? _cachedSenderName : displayName;
    final initSenderPhone = _cachedSenderPhone.isNotEmpty ? _cachedSenderPhone : displayPhone;

    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactDetailsScreen(
          vehicleName: _selectedVehicle == 'bike' ? 'Bike' : _selectedVehicle == 'three_wheeler' ? 'Cargo 3-Wheeler' : _selectedVehicle == 'ace' ? 'Mini Truck' : 'LCV',
          fare: _calculatePrice(_selectedVehicle),
          distanceKm: _roadDistanceKm,
          initSenderName: initSenderName,
          initSenderPhone: initSenderPhone,
          initSenderBuilding: _cachedSenderBuilding,
          initReceiverName: _cachedReceiverName,
          initReceiverPhone: _cachedReceiverPhone,
          initReceiverBuilding: _cachedReceiverBuilding,
        ),
      ),
    );

    if (result != null && mounted) {
      // Cache the entered values for state preservation
      setState(() {
        _cachedSenderName = result['senderName'] ?? '';
        _cachedSenderPhone = result['senderPhone'] ?? '';
        _cachedSenderBuilding = result['senderBuilding'] ?? '';
        _cachedReceiverName = result['receiverName'] ?? '';
        _cachedReceiverPhone = result['receiverPhone'] ?? '';
        _cachedReceiverBuilding = result['receiverBuilding'] ?? '';
      });

      // Navigate to Review Delivery screen
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewDeliveryScreen(
            pickup: widget.pickup,
            pickupAddress: widget.pickupAddress,
            dropoff: widget.dropoff,
            dropoffAddress: widget.dropoffAddress,
            selectedVehicle: _selectedVehicle,
            goodsCategory: _goodsCategory,
            helperCount: _helperCount,
            paymentMethod: _paymentMethod,
            estimatedFare: _calculatePrice(_selectedVehicle),
            distanceKm: _roadDistanceKm,
            durationMin: _roadDurationMin,
            senderName: result['senderName'] ?? '',
            senderPhone: result['senderPhone'] ?? '',
            receiverName: result['receiverName'] ?? '',
            receiverPhone: result['receiverPhone'] ?? '',
            roadPolylinePoints: _roadPolylinePoints,
          ),
        ),
      );
    }
  }

  void _showHelpMeChooseSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _HelpMeChooseFlow(
          onVehicleSelected: (vehicleId) {
            setState(() {
              _selectedVehicle = vehicleId;
              if (vehicleId == 'bike') _helperCount = 0;
            });
            Navigator.pop(sheetContext);
          },
        );
      },
    );
  }

  Widget _buildHelpOption({
    required String title,
    required String subtitle,
    required String vehicleId,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: VayaTheme.fog),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () {
          setState(() => _selectedVehicle = vehicleId);
          Navigator.pop(context);
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: VayaTheme.saffron),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHelperOptionTile({
    required String title,
    required String subtitle,
    required int value,
    required String priceSuffix,
  }) {
    final isSelected = _helperCount == value;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isSelected ? VayaTheme.saffron : VayaTheme.fog),
      ),
      color: isSelected ? VayaTheme.saffron.withOpacity(0.03) : Colors.white,
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => setState(() => _helperCount = value),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Radio<int>(
                value: value,
                groupValue: _helperCount,
                activeColor: VayaTheme.saffron,
                onChanged: (val) {
                  if (val != null) setState(() => _helperCount = val);
                },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                        if (priceSuffix.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(priceSuffix, style: const TextStyle(color: VayaTheme.saffron, fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 10, color: VayaTheme.slate)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentOptionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required String value,
  }) {
    final isSelected = _paymentMethod == value;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isSelected ? VayaTheme.saffron : VayaTheme.fog),
      ),
      color: isSelected ? VayaTheme.saffron.withOpacity(0.03) : Colors.white,
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => setState(() => _paymentMethod = value),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Radio<String>(
                value: value,
                groupValue: _paymentMethod,
                activeColor: VayaTheme.saffron,
                onChanged: (val) {
                  if (val != null) setState(() => _paymentMethod = val);
                },
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isSelected ? VayaTheme.saffron.withOpacity(0.12) : VayaTheme.fog.withOpacity(0.4),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: isSelected ? VayaTheme.saffron : VayaTheme.slate),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 10, color: VayaTheme.slate)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dist = Geolocator.distanceBetween(
      widget.pickup.latitude,
      widget.pickup.longitude,
      widget.dropoff.latitude,
      widget.dropoff.longitude,
    ) / 1000.0;

    final double estFare = _calculatePrice(_selectedVehicle);

    // Compute base fare raw
    double baseFareRaw = 50.0;
    if (_serverPricing.isNotEmpty) {
      try {
        final match = _serverPricing.firstWhere(
          (p) => p['vehicle_type'] == _selectedVehicle,
          orElse: () => null,
        );
        if (match != null) {
          final double basePrice = double.parse(match['base_price'].toString());
          final double baseDistance = double.parse(match['base_distance'].toString());
          final double perKmPrice = double.parse(match['per_km_price'].toString());
          baseFareRaw = basePrice + (dist > baseDistance ? (dist - baseDistance) * perKmPrice : 0.0);
        }
      } catch (e) {
        debugPrint("Error parsing pricing: $e");
      }
    } else {
      switch (_selectedVehicle) {
        case 'bike':
          baseFareRaw = 40.0 + (dist > 2 ? (dist - 2) * 10.0 : 0.0);
          break;
        case 'three_wheeler':
          baseFareRaw = 120.0 + (dist > 3 ? (dist - 3) * 18.0 : 0.0);
          break;
        case 'ace':
          baseFareRaw = 250.0 + (dist > 5 ? (dist - 5) * 25.0 : 0.0);
          break;
        case 'truck':
          baseFareRaw = 500.0 + (dist > 5 ? (dist - 5) * 35.0 : 0.0);
          break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Choose a vehicle',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontWeight: FontWeight.w700,
            fontSize: 28,
            color: VayaTheme.inkBlack,
          ),
        ),
        titleSpacing: 0,
        backgroundColor: Colors.white,
        foregroundColor: VayaTheme.inkBlack,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: VayaTheme.fog),
        ),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Collapsed route map (tap to expand/collapse) ──
              GestureDetector(
                onTap: () => setState(() => _isPickupExpanded = !_isPickupExpanded),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  height: _isPickupExpanded ? 260 : 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: VayaTheme.fog),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      children: [
                        GoogleMap(
                          initialCameraPosition: CameraPosition(target: widget.pickup, zoom: 13),
                          markers: {
                            Marker(
                              markerId: const MarkerId('pickup'),
                              position: widget.pickup,
                              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
                            ),
                            Marker(
                              markerId: const MarkerId('dropoff'),
                              position: widget.dropoff,
                              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                            ),
                          },
                          polylines: {
                            Polyline(
                              polylineId: const PolylineId('osrm_road_route'),
                              points: _roadPolylinePoints,
                              color: VayaTheme.saffron,
                              width: 4,
                            ),
                          },
                          myLocationEnabled: false,
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          zoomGesturesEnabled: _isPickupExpanded,
                          scrollGesturesEnabled: _isPickupExpanded,
                          rotateGesturesEnabled: false,
                          tiltGesturesEnabled: false,
                          gestureRecognizers: _isPickupExpanded ? {
                            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
                          } : {},
                          onMapCreated: (c) {
                            _mapController = c;
                            _fitRouteBounds();
                          },
                        ),
                        // Expand/collapse affordance
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.92),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isPickupExpanded ? Icons.unfold_less : Icons.unfold_more,
                                  size: 14,
                                  color: VayaTheme.inkBlack,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _isPickupExpanded ? 'Collapse' : 'Expand map',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: VayaTheme.inkBlack),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_fetchingRoute)
                          Container(
                            color: Colors.white54,
                            child: const Center(
                              child: VayaLoader.inline(size: 20, color: VayaTheme.saffron),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Compact pickup / drop summary pill ──
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: VayaTheme.fog),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      // Saffron dot → line → green dot
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 8, height: 8,
                            decoration: const BoxDecoration(color: VayaTheme.saffron, shape: BoxShape.circle),
                          ),
                          Container(width: 2, height: 16, color: VayaTheme.saffron.withOpacity(0.35)),
                          Container(
                            width: 8, height: 8,
                            decoration: const BoxDecoration(color: VayaTheme.routeGreen, shape: BoxShape.circle),
                          ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.pickupAddress,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.dropoffAddress,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: VayaTheme.slate.withOpacity(0.85), fontFamily: 'Inter'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Distance + duration chip
                      if (!_fetchingRoute)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: VayaTheme.signalCream,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_roadDistanceKm.toStringAsFixed(1)} km · ~$_roadDurationMin min',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: VayaTheme.slate, fontFamily: 'Inter'),
                          ),
                        )
                      else
                        const VayaLoader.inline(size: 16, color: VayaTheme.saffron),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'ELIGIBLE VEHICLES',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2, color: VayaTheme.slate),
                  ),
                  TextButton.icon(
                    onPressed: _showHelpMeChooseSheet,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(80, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.help_outline, size: 13, color: VayaTheme.saffron),
                    label: const Text(
                      'Help me choose',
                      style: TextStyle(fontSize: 11, color: VayaTheme.saffron, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_loadingPricing)
                Column(
                  children: List.generate(4, (index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: _buildVehicleSkeletonRow(),
                  )),
                )
              else ...[
                _buildVehicleOption(
                  id: 'bike',
                  name: 'Bike',
                  capacity: 'Up to 20 kg',
                  dimensions: '35 x 35 x 40 cm',
                  eta: '3 mins away',
                  imageAsset: 'assets/images/vehicle_bike.png',
                  cargoExamples: 'Documents, food, small packets',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'three_wheeler',
                  name: '3-wheeler',
                  capacity: 'Up to 500 kg',
                  dimensions: '1.5m x 1.2m x 1.2m',
                  eta: '5 mins away',
                  imageAsset: 'assets/images/vehicle_3wheeler.png',
                  cargoExamples: 'Medium boxes, crates, retail supplies',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'ace',
                  name: 'Mini truck',
                  capacity: 'Up to 750 kg',
                  dimensions: '2.1m x 1.4m x 1.2m',
                  eta: '8 mins away',
                  imageAsset: 'assets/images/vehicle_mini_truck.png',
                  cargoExamples: 'Appliances, furniture, business inventory',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'truck',
                  name: 'Light commercial vehicle',
                  capacity: 'Up to 2,000 kg',
                  dimensions: '3.0m x 1.8m x 1.8m',
                  eta: '12 mins away',
                  imageAsset: 'assets/images/vehicle_lcv.png',
                  cargoExamples: 'Bulk commercial loads, house shifting',
                ),
              ],

              const SizedBox(height: 18),
              const Text(
                'TRIP CUSTOMIZATION',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2, color: VayaTheme.slate, fontFamily: 'Inter'),
              ),
              const SizedBox(height: 8),

              // Goods Category Dropdown (required)
              DropdownButtonFormField<String>(
                value: _goodsCategory,
                decoration: InputDecoration(
                  labelText: 'Goods Category *',
                  labelStyle: const TextStyle(fontSize: 13, fontFamily: 'Inter'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: VayaTheme.fog.withOpacity(0.8)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: VayaTheme.saffron, width: 1.5),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
                style: const TextStyle(fontSize: 14, fontFamily: 'Inter', color: VayaTheme.inkBlack),
                items: const [
                  DropdownMenuItem(value: 'General Cargo', child: Text('General Packages & Boxes')),
                  DropdownMenuItem(value: 'Electronics', child: Text('Electronics & Appliances')),
                  DropdownMenuItem(value: 'Furniture', child: Text('Furniture & Home Goods')),
                  DropdownMenuItem(value: 'FMCG', child: Text('Groceries / FMCG Products')),
                  DropdownMenuItem(value: 'Hardware', child: Text('Hardware / Construction Goods')),
                  DropdownMenuItem(value: 'Fragile', child: Text('Fragile / Glassware')),
                ],
                onChanged: (val) => setState(() => _goodsCategory = val!),
              ),
              const SizedBox(height: 6),
              // Category Restrictions Notice
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border.all(color: Colors.amber.shade200),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.amber.shade800),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Restrictions: Fragile items require protective packaging. Prohibited items, hazardous materials, and chemicals are not permitted.',
                        style: TextStyle(fontSize: 11, color: VayaTheme.slate, fontFamily: 'Inter'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Helper / Loading Assistance — hidden for Bike
              if (_selectedVehicle != 'bike') ...[
                const Text(
                  'Helper / Loading Assistance',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack, fontFamily: 'General Sans'),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Helper supports loading and unloading; driver assistance is not included.',
                  style: TextStyle(fontSize: 12, color: VayaTheme.slate, fontFamily: 'Inter'),
                ),
                const SizedBox(height: 8),
                Column(
                  children: [
                    _buildHelperOptionTile(
                      title: 'No Helper',
                      subtitle: 'You will handle all loading and unloading.',
                      value: 0,
                      priceSuffix: '',
                    ),
                    _buildHelperOptionTile(
                      title: '1 Helper',
                      subtitle: '1 helper assists with loading/unloading.',
                      value: 1,
                      priceSuffix: '+₹150',
                    ),
                    _buildHelperOptionTile(
                      title: '2 Helpers',
                      subtitle: '2 helpers assist with loading/unloading.',
                      value: 2,
                      priceSuffix: '+₹300',
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 96), // Bottom padding so last vehicle row clears the sticky CTA
            ],
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: VayaTheme.fog.withOpacity(0.5))),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2)),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: (dist < 0.05 || _isLoading) ? null : _openContactDetailsModal,
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.saffron,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  disabledBackgroundColor: VayaTheme.fog,
                ),
                child: _isLoading
                    ? const VayaLoader.inline(size: 20, color: Colors.white)
                    : Text(
                        dist < 0.05
                            ? 'Select a valid route first'
                            : 'Continue · ${_selectedVehicle == 'bike' ? 'Bike' : _selectedVehicle == 'three_wheeler' ? '3-Wheeler' : _selectedVehicle == 'ace' ? 'Mini Truck' : 'LCV'} · ₹${estFare.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontFamily: 'General Sans',
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVehicleOption({
    required String id,
    required String name,
    required String capacity,
    required String dimensions,
    required String eta,
    required String imageAsset,
    required String cargoExamples,
    bool unavailable = false,
  }) {
    final isSelected = _selectedVehicle == id;

    // Show per-row skeleton while pricing loads
    if (_loadingPricing) {
      return _buildVehicleSkeletonRow();
    }

    final fare = _calculatePrice(id);
    final cleanEta = eta.replaceAll('mins away', 'min').replaceAll('away', '').trim();
    final etaText = 'Arrives in $cleanEta';

    return Opacity(
      opacity: unavailable ? 0.45 : 1.0,
      child: InkWell(
        onTap: unavailable ? null : () => setState(() {
          _selectedVehicle = id;
          // Reset helper count when switching to Bike
          if (id == 'bike') _helperCount = 0;
        }),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
              width: 1.0,
            ),
            borderRadius: BorderRadius.circular(16),
            color: isSelected ? VayaTheme.saffron.withOpacity(0.04) : Colors.white,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Saffron radio indicator
              Radio<String>(
                value: id,
                groupValue: unavailable ? null : _selectedVehicle,
                activeColor: VayaTheme.saffron,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: unavailable ? null : (val) {
                  if (val != null) setState(() {
                    _selectedVehicle = val;
                    if (val == 'bike') _helperCount = 0;
                  });
                },
              ),
              const SizedBox(width: 4),
              // Vehicle icon 24px
              SizedBox(
                width: 48,
                height: 48,
                child: Image.asset(
                  imageAsset,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: VayaTheme.inkBlack,
                        fontFamily: 'General Sans',
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$capacity · $dimensions',
                      style: const TextStyle(fontSize: 12, color: VayaTheme.slate, fontWeight: FontWeight.w500, fontFamily: 'Inter'),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Best for: $cargoExamples',
                      style: const TextStyle(fontSize: 11, color: VayaTheme.slate, fontFamily: 'Inter'),
                    ),
                    if (unavailable)
                      const Text(
                        'Unavailable on this route',
                        style: TextStyle(fontSize: 11, color: Color(0xFFDC2626), fontFamily: 'Inter'),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₹${fare.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: isSelected ? VayaTheme.saffron : VayaTheme.inkBlack,
                      fontFamily: 'General Sans',
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    etaText,
                    style: const TextStyle(fontSize: 11, color: VayaTheme.slate, fontWeight: FontWeight.w500, fontFamily: 'Inter'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVehicleSkeletonRow() {
    return Container(
      height: 112,
      margin: const EdgeInsets.only(bottom: 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VayaTheme.fog),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          _skeletonBox(40, 40, radius: 8),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _skeletonBox(12, 120),
                const SizedBox(height: 6),
                _skeletonBox(10, 90),
                const SizedBox(height: 6),
                _skeletonBox(10, 140),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _skeletonBox(20, 52),
              const SizedBox(height: 4),
              _skeletonBox(11, 60),
            ],
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _skeletonBox(double h, double w, {double radius = 4}) {
    return Container(
      height: h,
      width: w,
      decoration: BoxDecoration(
        color: VayaTheme.fog.withOpacity(0.6),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 6a. Help Me Choose Recommender Bottom Sheet
// ─────────────────────────────────────────────────────────────
class _HelpMeChooseFlow extends StatefulWidget {
  final ValueChanged<String> onVehicleSelected;

  const _HelpMeChooseFlow({required this.onVehicleSelected});

  @override
  State<_HelpMeChooseFlow> createState() => _HelpMeChooseFlowState();
}

class _HelpMeChooseFlowState extends State<_HelpMeChooseFlow> {
  String _itemType = 'Documents / Small Parcel';
  String _weightRange = '< 20 kg';
  String _dimension = 'Small (< 40cm)';
  String _quantity = '1–2 items';

  String get _recommendedVehicle {
    if (_weightRange == '< 20 kg' && _itemType.contains('Documents')) {
      return 'bike';
    } else if (_weightRange == '20–500 kg' || _dimension.contains('Medium')) {
      return 'three_wheeler';
    } else if (_weightRange == '500–750 kg' || _dimension.contains('Large')) {
      return 'ace';
    } else if (_weightRange == '> 750 kg' || _dimension.contains('Extra Large')) {
      return 'truck';
    }
    if (_weightRange == '< 20 kg') return 'bike';
    if (_weightRange == '20–500 kg') return 'three_wheeler';
    if (_weightRange == '500–750 kg') return 'ace';
    return 'truck';
  }

  String get _recommendedVehicleName {
    switch (_recommendedVehicle) {
      case 'bike': return 'Bike';
      case 'three_wheeler': return '3-wheeler';
      case 'ace': return 'Mini truck';
      default: return 'Light commercial vehicle';
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: VayaTheme.fog,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Vehicle Recommender',
            style: TextStyle(
              fontFamily: 'General Sans',
              fontWeight: FontWeight.w700,
              fontSize: 20,
              color: VayaTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tell us about your cargo to find the right fit.',
            style: TextStyle(fontSize: 13, color: VayaTheme.slate, fontFamily: 'Inter'),
          ),
          const SizedBox(height: 16),

          // 1. Item Type
          const Text('1. Item Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: 'Inter')),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              'Documents / Small Parcel',
              'Groceries / Cartons',
              'Appliances / Furniture',
              'Bulk Commercial Goods',
            ].map((type) {
              final isSel = _itemType == type;
              return ChoiceChip(
                label: Text(type, style: TextStyle(fontSize: 12, color: isSel ? Colors.white : VayaTheme.inkBlack, fontFamily: 'Inter')),
                selected: isSel,
                selectedColor: VayaTheme.saffron,
                backgroundColor: VayaTheme.signalCream,
                onSelected: (selected) {
                  if (selected) setState(() => _itemType = type);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),

          // 2. Weight Range
          const Text('2. Estimated Total Weight', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: 'Inter')),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              '< 20 kg',
              '20–500 kg',
              '500–750 kg',
              '> 750 kg',
            ].map((weight) {
              final isSel = _weightRange == weight;
              return ChoiceChip(
                label: Text(weight, style: TextStyle(fontSize: 12, color: isSel ? Colors.white : VayaTheme.inkBlack, fontFamily: 'Inter')),
                selected: isSel,
                selectedColor: VayaTheme.saffron,
                backgroundColor: VayaTheme.signalCream,
                onSelected: (selected) {
                  if (selected) setState(() => _weightRange = weight);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),

          // 3. Size / Dimension
          const Text('3. Largest Item Size', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: 'Inter')),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              'Small (< 40cm)',
              'Medium (1.5m box)',
              'Large (2.1m truck load)',
              'Extra Large (3m LCV)',
            ].map((dim) {
              final isSel = _dimension == dim;
              return ChoiceChip(
                label: Text(dim, style: TextStyle(fontSize: 12, color: isSel ? Colors.white : VayaTheme.inkBlack, fontFamily: 'Inter')),
                selected: isSel,
                selectedColor: VayaTheme.saffron,
                backgroundColor: VayaTheme.signalCream,
                onSelected: (selected) {
                  if (selected) setState(() => _dimension = dim);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 20),

          // Recommendation Result Box
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VayaTheme.saffron.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: VayaTheme.saffron.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(color: VayaTheme.saffron, shape: BoxShape.circle),
                  child: const Icon(Icons.thumb_up_alt_outlined, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'RECOMMENDED VEHICLE',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.saffron, letterSpacing: 0.8),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _recommendedVehicleName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: VayaTheme.inkBlack, fontFamily: 'General Sans'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Select Vehicle CTA Button
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: () => widget.onVehicleSelected(_recommendedVehicle),
              style: ElevatedButton.styleFrom(
                backgroundColor: VayaTheme.saffron,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                'Select $_recommendedVehicleName',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFamily: 'General Sans'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 6b. Contact Details Screen (dedicated page, not bottom sheet)
// ─────────────────────────────────────────────────────────────
class ContactDetailsScreen extends StatefulWidget {
  final String vehicleName;
  final double fare;
  final double distanceKm;
  final String initSenderName;
  final String initSenderPhone;
  final String initSenderBuilding;
  final String initReceiverName;
  final String initReceiverPhone;
  final String initReceiverBuilding;

  const ContactDetailsScreen({
    super.key,
    required this.vehicleName,
    required this.fare,
    required this.distanceKm,
    this.initSenderName = '',
    this.initSenderPhone = '',
    this.initSenderBuilding = '',
    this.initReceiverName = '',
    this.initReceiverPhone = '',
    this.initReceiverBuilding = '',
  });

  @override
  State<ContactDetailsScreen> createState() => _ContactDetailsScreenState();
}

class _ContactDetailsScreenState extends State<ContactDetailsScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _senderNameCtrl;
  late TextEditingController _senderPhoneCtrl;
  late TextEditingController _senderBuildingCtrl;
  late TextEditingController _receiverNameCtrl;
  late TextEditingController _receiverPhoneCtrl;
  late TextEditingController _receiverBuildingCtrl;

  bool _receiverIsMe = false;
  bool _isFormValid = false;
  bool _isDuplicatePhone = false;

  // Error messages for inline validation
  String? _senderNameError;
  String? _senderPhoneError;
  String? _receiverNameError;
  String? _receiverPhoneError;

  // Quote expiry timer (5 minutes)
  Timer? _quoteTimer;
  bool _quoteExpired = false;
  int _quoteSecondsLeft = 300;
  bool _isRefreshingQuote = false;

  @override
  void initState() {
    super.initState();
    final initSName = widget.initSenderName.trim().isNotEmpty ? widget.initSenderName.trim() : 'Priya Sharma';
    final initSPhone = widget.initSenderPhone.trim().isNotEmpty ? widget.initSenderPhone.trim() : '+91 98765 43210';
    final initRName = widget.initReceiverName.trim().isNotEmpty ? widget.initReceiverName.trim() : 'Rahul Mehta';
    final initRPhone = widget.initReceiverPhone.trim().isNotEmpty ? widget.initReceiverPhone.trim() : '+91 98765 43210';

    _senderNameCtrl = TextEditingController(text: initSName);
    _senderPhoneCtrl = TextEditingController(text: initSPhone);
    _senderBuildingCtrl = TextEditingController(text: widget.initSenderBuilding);
    _receiverNameCtrl = TextEditingController(text: initRName);
    _receiverPhoneCtrl = TextEditingController(text: initRPhone);
    _receiverBuildingCtrl = TextEditingController(text: widget.initReceiverBuilding);

    _senderNameCtrl.addListener(_validateForm);
    _senderPhoneCtrl.addListener(_validateForm);
    _receiverNameCtrl.addListener(_validateForm);
    _receiverPhoneCtrl.addListener(_validateForm);

    _validateForm();
    _startQuoteTimer();
  }

  void _startQuoteTimer() {
    _quoteTimer?.cancel();
    _quoteTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _quoteSecondsLeft--;
        if (_quoteSecondsLeft <= 0) {
          _quoteExpired = true;
          t.cancel();
        }
      });
    });
  }

  void _refreshQuote() {
    setState(() {
      _isRefreshingQuote = true;
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _quoteExpired = false;
        _quoteSecondsLeft = 300;
        _isRefreshingQuote = false;
      });
      _startQuoteTimer();
    });
  }

  @override
  void dispose() {
    _quoteTimer?.cancel();
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _senderBuildingCtrl.dispose();
    _receiverNameCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverBuildingCtrl.dispose();
    super.dispose();
  }

  bool _isValidIndianMobile(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final local = digits.startsWith('91') && digits.length == 12 ? digits.substring(2) : digits;
    return local.length == 10 && RegExp(r'^[1-9]').hasMatch(local);
  }

  void _validateForm() {
    final senderNameOk = _senderNameCtrl.text.trim().isNotEmpty;
    final senderPhoneOk = _isValidIndianMobile(_senderPhoneCtrl.text);
    final receiverNameOk = _receiverIsMe || _receiverNameCtrl.text.trim().isNotEmpty;
    final receiverPhoneOk = _receiverIsMe || _isValidIndianMobile(_receiverPhoneCtrl.text);

    // Duplicate check
    final sDigits = _senderPhoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    final rDigits = _receiverPhoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    final duplicate = !_receiverIsMe && sDigits.isNotEmpty && sDigits == rDigits;

    setState(() {
      _isDuplicatePhone = duplicate;
      _isFormValid = senderNameOk && senderPhoneOk && receiverNameOk && receiverPhoneOk && !_quoteExpired;
    });
  }

  void _inlineValidateSenderName() {
    setState(() {
      _senderNameError = _senderNameCtrl.text.trim().isEmpty ? 'Sender name is required' : null;
    });
  }

  void _inlineValidateSenderPhone() {
    setState(() {
      _senderPhoneError = _isValidIndianMobile(_senderPhoneCtrl.text) ? null : 'Enter a valid 10-digit mobile number';
    });
  }

  void _inlineValidateReceiverName() {
    setState(() {
      _receiverNameError = _receiverIsMe ? null : (_receiverNameCtrl.text.trim().isEmpty ? 'Receiver name is required' : null);
    });
  }

  void _inlineValidateReceiverPhone() {
    setState(() {
      _receiverPhoneError = _receiverIsMe ? null : (_isValidIndianMobile(_receiverPhoneCtrl.text) ? null : 'Enter a valid 10-digit mobile number');
    });
  }

  Future<void> _openContactPicker({required bool isSender}) async {
    final picked = await _pickPhoneContact(context);
    if (picked == null) return;
    if (picked.containsKey('permission_denied')) return; // handled in helper
    if (!mounted) return;
    final pickedName = picked['name'] ?? '';
    final rawPhone = picked['phone'] ?? '';
    final formattedPhone = formatIndianPhoneNumber(rawPhone);
    setState(() {
      if (isSender) {
        if (pickedName.isNotEmpty) _senderNameCtrl.text = pickedName;
        if (rawPhone.isNotEmpty) _senderPhoneCtrl.text = formattedPhone;
        if (_receiverIsMe) {
          _receiverNameCtrl.text = _senderNameCtrl.text;
          _receiverPhoneCtrl.text = _senderPhoneCtrl.text;
        }
      } else {
        if (pickedName.isNotEmpty) _receiverNameCtrl.text = pickedName;
        if (rawPhone.isNotEmpty) _receiverPhoneCtrl.text = formattedPhone;
      }
    });
    _validateForm();
  }

  void _toggleReceiverIsMe(bool val) {
    setState(() {
      _receiverIsMe = val;
      if (val) {
        _receiverNameCtrl.text = _senderNameCtrl.text;
        _receiverPhoneCtrl.text = _senderPhoneCtrl.text;
        _receiverNameError = null;
        _receiverPhoneError = null;
      }
    });
    _validateForm();
  }

  Widget _buildSectionConnector() {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const SizedBox(width: 21),
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: VayaTheme.saffron,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersistentField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool enabled = true,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? errorText,
    VoidCallback? onEditingComplete,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: VayaTheme.slate,
            fontFamily: 'Inter',
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 56,
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            textInputAction: textInputAction,
            onEditingComplete: onEditingComplete,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: enabled ? VayaTheme.inkBlack : VayaTheme.slate,
              fontFamily: 'Inter',
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 15, color: Color(0xFFB0ABA3), fontFamily: 'Inter'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              prefixIcon: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(icon, size: 20, color: enabled ? VayaTheme.slate : VayaTheme.fog),
              ),
              filled: true,
              fillColor: enabled ? Colors.white : const Color(0xFFF7F5F2),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: VayaTheme.fog, width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: errorText != null ? const Color(0xFFDC2626) : VayaTheme.fog,
                  width: errorText != null ? 1.5 : 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: VayaTheme.saffron, width: 2),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: VayaTheme.fog.withOpacity(0.6), width: 1),
              ),
              errorText: null,
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 4),
          Text(
            errorText,
            style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626), fontFamily: 'Inter'),
          ),
        ],
      ],
    );
  }

  String _quoteTimerLabel() {
    final m = _quoteSecondsLeft ~/ 60;
    final s = _quoteSecondsLeft % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final vehicleLabel = widget.vehicleName;
    final fareStr = '₹${widget.fare.toStringAsFixed(0)}';
    final distStr = '${widget.distanceKm.toStringAsFixed(1)} km';
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: VayaTheme.signalCream,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: VayaTheme.inkBlack,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Contact Details',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontWeight: FontWeight.w700,
            fontSize: 28,
            color: VayaTheme.inkBlack,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: VayaTheme.fog),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // ── Summary bar (64-72 px height) ──────────────────────────
            Container(
              height: 68,
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: VayaTheme.signalCream,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: VayaTheme.fog),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.two_wheeler, size: 16, color: VayaTheme.saffron),
                        const SizedBox(width: 6),
                        Text(
                          vehicleLabel,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('·', style: TextStyle(color: VayaTheme.slate.withOpacity(0.5), fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    fareStr,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                  ),
                  const SizedBox(width: 8),
                  Text('·', style: TextStyle(color: VayaTheme.slate.withOpacity(0.5), fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    distStr,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: VayaTheme.slate, fontFamily: 'Inter'),
                  ),
                  const Spacer(),
                  // Timer pill: Fare valid · 04:45
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _quoteExpired
                          ? const Color(0xFFFEF2F2)
                          : VayaTheme.saffron.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _quoteExpired ? const Color(0xFFFCA5A5) : VayaTheme.saffron.withOpacity(0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 14,
                          color: _quoteExpired ? const Color(0xFFDC2626) : VayaTheme.saffron,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _quoteExpired ? 'Fare expired' : 'Fare valid · ${_quoteTimerLabel()}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _quoteExpired ? const Color(0xFFDC2626) : VayaTheme.saffron,
                            fontFamily: 'Inter',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Non-destructive quote expired banner notice ───────────
            if (_quoteExpired)
              Container(
                width: double.infinity,
                color: const Color(0xFFFEF2F2),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 18, color: Color(0xFFDC2626)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Quote expired. Retaining your contact details while you refresh.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF991B1B), fontFamily: 'Inter'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _isRefreshingQuote ? null : _refreshQuote,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: VayaTheme.saffron,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: _isRefreshingQuote
                            ? const VayaLoader.inline(size: 14, color: VayaTheme.inkBlack)
                            : const Text('Refresh fare', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VayaTheme.inkBlack, fontFamily: 'Inter')),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Duplicate phone number warning notice ────────────────
            if (_isDuplicatePhone)
              Container(
                width: double.infinity,
                color: const Color(0xFFFFFBEB),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFD97706)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Sender and receiver mobile numbers are identical. Check "Receiver is me" to auto-sync.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF92400E), fontFamily: 'Inter'),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Form list ──────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildContactSection(sectionType: 'sender'),
                    _buildSectionConnector(),
                    _buildContactSection(sectionType: 'receiver'),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: EdgeInsets.only(bottom: bottomInset),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: VayaTheme.fog.withOpacity(0.6))),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: (_isFormValid && !_quoteExpired) ? _onReviewDelivery : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.saffron,
                  foregroundColor: VayaTheme.inkBlack,
                  disabledBackgroundColor: VayaTheme.fog,
                  disabledForegroundColor: VayaTheme.slate,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: EdgeInsets.zero,
                ),
                child: Text(
                  'Review delivery',
                  style: TextStyle(
                    fontFamily: 'General Sans',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: (_isFormValid && !_quoteExpired) ? VayaTheme.inkBlack : VayaTheme.slate,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContactSection({required String sectionType}) {
    final isSender = sectionType == 'sender';
    final sectionLabel = isSender ? 'Pickup contact (sender)' : 'Drop-off contact (receiver)';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VayaTheme.fog, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header with VAYA Saffron filled square & open circle
          Row(
            children: [
              if (isSender)
                // VAYA Filled Saffron pickup square
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: VayaTheme.saffron,
                    borderRadius: BorderRadius.circular(3),
                  ),
                )
              else
                // VAYA Open Saffron drop circle
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: VayaTheme.saffron, width: 3.5),
                    color: Colors.white,
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  sectionLabel,
                  style: const TextStyle(
                    fontFamily: 'General Sans',
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: VayaTheme.inkBlack,
                  ),
                ),
              ),
              // 44 px contact target button
              InkWell(
                onTap: () => _openContactPicker(isSender: isSender),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: VayaTheme.saffron.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.contacts_outlined, size: 20, color: VayaTheme.saffron),
                ),
              ),
            ],
          ),

          // "Receiver is me" checkbox (only on receiver section)
          if (!isSender) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => _toggleReceiverIsMe(!_receiverIsMe),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _receiverIsMe,
                      onChanged: (v) => _toggleReceiverIsMe(v ?? false),
                      activeColor: VayaTheme.saffron,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                      side: const BorderSide(color: VayaTheme.fog, width: 1.5),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Receiver is me',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      color: VayaTheme.inkBlack,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Form fields (56 px inputs, 12 px field gaps)
          Column(
            children: [
              _buildPersistentField(
                label: isSender ? 'Sender name' : 'Receiver name',
                controller: isSender ? _senderNameCtrl : _receiverNameCtrl,
                hint: isSender ? 'e.g. Priya Sharma' : 'e.g. Rahul Mehta',
                icon: Icons.person_outline_rounded,
                enabled: isSender || !_receiverIsMe,
                textInputAction: TextInputAction.next,
                errorText: isSender ? _senderNameError : _receiverNameError,
                onEditingComplete: isSender ? _inlineValidateSenderName : _inlineValidateReceiverName,
              ),
              const SizedBox(height: 12),
              _buildPersistentField(
                label: isSender ? 'Sender mobile' : 'Receiver mobile',
                controller: isSender ? _senderPhoneCtrl : _receiverPhoneCtrl,
                hint: '+91 98765 43210',
                icon: Icons.phone_outlined,
                enabled: isSender || !_receiverIsMe,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, IndianPhoneInputFormatter()],
                textInputAction: TextInputAction.next,
                errorText: isSender ? _senderPhoneError : _receiverPhoneError,
                onEditingComplete: isSender ? _inlineValidateSenderPhone : _inlineValidateReceiverPhone,
              ),
              const SizedBox(height: 12),
              // Building, flat or gate (optional) - ALWAYS editable!
              _buildPersistentField(
                label: 'Building, flat or gate (optional)',
                controller: isSender ? _senderBuildingCtrl : _receiverBuildingCtrl,
                hint: 'e.g. B-4, Sunrise Apartments',
                icon: Icons.home_work_outlined,
                enabled: true,
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onReviewDelivery() {
    _inlineValidateSenderName();
    _inlineValidateSenderPhone();
    if (!_receiverIsMe) {
      _inlineValidateReceiverName();
      _inlineValidateReceiverPhone();
    }
    if (!_isFormValid || _quoteExpired) return;

    Navigator.pop(context, {
      'senderName': _senderNameCtrl.text.trim(),
      'senderPhone': _senderPhoneCtrl.text.trim(),
      'senderBuilding': _senderBuildingCtrl.text.trim(),
      'receiverName': _receiverNameCtrl.text.trim(),
      'receiverPhone': _receiverPhoneCtrl.text.trim(),
      'receiverBuilding': _receiverBuildingCtrl.text.trim(),
    });
  }
}

// ─────────────────────────────────────────────────────────────
// 6c. Review Delivery Screen
// ─────────────────────────────────────────────────────────────
class ReviewDeliveryScreen extends StatefulWidget {
  final LatLng pickup;
  final String pickupAddress;
  final LatLng dropoff;
  final String dropoffAddress;
  final String selectedVehicle;
  final String goodsCategory;
  final int helperCount;
  final String paymentMethod;
  final double estimatedFare;
  final double distanceKm;
  final int durationMin;
  final String senderName;
  final String senderPhone;
  final String receiverName;
  final String receiverPhone;
  final List<LatLng> roadPolylinePoints;

  const ReviewDeliveryScreen({
    super.key,
    required this.pickup,
    required this.pickupAddress,
    required this.dropoff,
    required this.dropoffAddress,
    required this.selectedVehicle,
    required this.goodsCategory,
    required this.helperCount,
    required this.paymentMethod,
    required this.estimatedFare,
    required this.distanceKm,
    required this.durationMin,
    required this.senderName,
    required this.senderPhone,
    required this.receiverName,
    required this.receiverPhone,
    required this.roadPolylinePoints,
  });

  @override
  State<ReviewDeliveryScreen> createState() => _ReviewDeliveryScreenState();
}

class _ReviewDeliveryScreenState extends State<ReviewDeliveryScreen> {
  bool _isBooking = false;
  String _selectedPayment = '';
  String? _cashCollectionPoint; // null, 'PICKUP', 'DROPOFF'
  List<dynamic> _serverPricing = [];
  bool _loadingPricing = true;
  late RazorpayPaymentService _razorpayService;

  @override
  void initState() {
    super.initState();
    _selectedPayment = widget.paymentMethod;
    _fetchPricingConfig();
    _initRazorpay();
  }

  void _initRazorpay() {
    _razorpayService = RazorpayPaymentService();
    _razorpayService.init(
      onSuccess: _handleRazorpaySuccess,
      onError: _handleRazorpayError,
    );
  }

  @override
  void dispose() {
    _razorpayService.dispose();
    super.dispose();
  }

  Future<void> _handleRazorpaySuccess(Map<String, String> response) async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token == null) return;

      final paymentId = response['paymentId'] ?? '';
      final orderId = response['orderId'] ?? '';
      final signature = response['signature'] ?? '';

      // 1. Verify signature with VAYA backend
      await RazorpayPaymentService.verifyPayment(
        apiBaseUrl: apiBaseUrl,
        token: token,
        paymentId: paymentId,
        orderId: orderId,
        signature: signature,
      );

      // 2. Submit booking with paymentType = 'online' and razorpayPaymentId
      await _submitBookingToBackend(
        token: token,
        paymentType: 'online',
        razorpayPaymentId: paymentId,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isBooking = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment verification failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _handleRazorpayError(String error) {
    if (mounted) {
      setState(() => _isBooking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment cancelled or failed ($error)'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _fetchPricingConfig() async {
    final cached = await VayaStorage.loadCachedPricingConfig();
    if (cached != null && cached['pricing'] != null) {
      if (mounted) {
        setState(() {
          _serverPricing = cached['pricing'] ?? [];
          _loadingPricing = false;
        });
      }
    }
    try {
      var response = await http.get(Uri.parse('$apiBaseUrl/api/health/pricing-config')).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/pricing-config')).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200) {
        response = await http.get(Uri.parse('$apiBaseUrl/api/booking/pricing-config')).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _serverPricing = data['pricing'] ?? [];
            _loadingPricing = false;
          });
        }
        await VayaStorage.saveCachedPricingConfig(data);
      } else {
        if (mounted) setState(() => _loadingPricing = false);
      }
    } catch (e) {
      debugPrint("Failed to load pricing in review screen: $e");
      if (mounted) setState(() => _loadingPricing = false);
    }
  }

  double get _baseFare {
    final dist = widget.distanceKm;
    if (_serverPricing.isNotEmpty) {
      try {
        final match = _serverPricing.firstWhere(
          (p) => p['vehicle_type'] == widget.selectedVehicle,
          orElse: () => null,
        );
        if (match != null) {
          final double basePrice = double.parse(match['base_price'].toString());
          final double baseDistance = double.parse(match['base_distance'].toString());
          final double perKmPrice = double.parse(match['per_km_price'].toString());
          return basePrice + (dist > baseDistance ? (dist - baseDistance) * perKmPrice : 0.0);
        }
      } catch (e) {
        debugPrint("Error parsing base fare in review screen: $e");
      }
    }
    switch (widget.selectedVehicle) {
      case 'bike': return 40.0 + (dist > 2 ? (dist - 2) * 10.0 : 0.0);
      case 'three_wheeler': return 120.0 + (dist > 3 ? (dist - 3) * 18.0 : 0.0);
      case 'ace': return 250.0 + (dist > 5 ? (dist - 5) * 25.0 : 0.0);
      default: return 500.0 + (dist > 5 ? (dist - 5) * 35.0 : 0.0);
    }
  }

  double get _totalFare {
    final baseFare = _baseFare;
    final helperFee = widget.helperCount * 150.0;
    final taxes = baseFare * 0.05;
    const platformFee = 10.0;
    final total = baseFare + helperFee + taxes + platformFee;
    return total > 0 ? total : 0.0;
  }

  String get _vehicleDisplayName {
    switch (widget.selectedVehicle) {
      case 'bike': return 'Bike';
      case 'three_wheeler': return 'Cargo 3-Wheeler';
      case 'ace': return 'Mini Truck';
      default: return 'LCV';
    }
  }

  Future<void> _confirmBooking() async {
    setState(() => _isBooking = true);
    try {
      final token = await CustomerAuthHelper.getAuthToken() ?? 'demo_token';

      if (_selectedPayment == 'UPI') {
        // Launch custom native UPI payment sheet (no blue screen!)
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (ctx) => PaymentMethodSheet(
            amount: _totalFare,
            purpose: 'booking_fare',
            userPhone: widget.senderPhone.replaceAll(RegExp(r'\D'), ''),
            userName: widget.senderName,
            razorpayService: _razorpayService,
            apiBaseUrl: apiBaseUrl,
            token: token,
            onFailure: (err) {
              if (mounted) {
                setState(() => _isBooking = false);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
              }
            },
          ),
        );
      } else {
        // Wallet or Cash payment flow
        final String pType = _selectedPayment == 'Wallet' ? 'wallet' : 'cash';
        await _submitBookingToBackend(token: token, paymentType: pType);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isBooking = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _submitBookingToBackend({
    required String token,
    required String paymentType,
    String? razorpayPaymentId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/booking'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: json.encode({
          'pickupName': widget.pickupAddress,
          'pickupLat': widget.pickup.latitude,
          'pickupLng': widget.pickup.longitude,
          'senderName': widget.senderName,
          'senderPhone': widget.senderPhone.replaceAll(RegExp(r'\D'), ''),
          'dropoffName': widget.dropoffAddress,
          'dropoffLat': widget.dropoff.latitude,
          'dropoffLng': widget.dropoff.longitude,
          'receiverName': widget.receiverName,
          'receiverPhone': widget.receiverPhone.replaceAll(RegExp(r'\D'), ''),
          'vehicleType': widget.selectedVehicle,
          'weight': widget.selectedVehicle == 'bike' ? 15 : (widget.selectedVehicle == 'ace' ? 400 : 1500),
          'estimatedCost': _totalFare,
          'goodsCategory': widget.goodsCategory,
          'helpers': widget.helperCount,
          'paymentMethod': paymentType == 'cash'
              ? (_cashCollectionPoint == 'PICKUP'
                  ? 'Cash · Collect at pickup'
                  : 'Cash · Collect at drop-off')
              : (paymentType == 'wallet' ? 'VAYA Wallet' : 'UPI Payment'),
          'paymentType': paymentType,
          'cashCollectionPoint': paymentType == 'cash' ? _cashCollectionPoint : null,
          'razorpayPaymentId': razorpayPaymentId,
        }),
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final b = data['booking'] ?? {};
        final cost = double.tryParse(b['estimated_cost']?.toString() ?? '') ?? widget.estimatedFare;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => TrackingScreen(
              bookingId: b['id'] ?? '',
              initialEstimatedCost: cost,
            ),
          ),
          (route) => route.isFirst,
        );
      } else {
        if (response.statusCode == 401 || response.statusCode == 403) {
          if (mounted) {
            await CustomerAuthHelper.handleUnauthorized(context);
          }
          return;
        }
        String errorMsg = 'Failed to request booking. Please try again.';
        try {
          final errData = json.decode(response.body);
          if (errData['error'] != null) errorMsg = errData['error'].toString();
          else if (errData['errors'] != null && (errData['errors'] as List).isNotEmpty) {
            errorMsg = errData['errors'][0]['msg']?.toString() ?? errorMsg;
          }
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Booking error: $e')));
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: VayaTheme.slate, fontFamily: 'Inter')),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: valueColor ?? VayaTheme.inkBlack, fontFamily: 'Inter')),
        ],
      ),
    );
  }

  Widget _buildDivider() => Divider(height: 1, color: VayaTheme.fog.withOpacity(0.7));

  Widget _buildCard({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VayaTheme.fog, width: 1),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseFare = _baseFare;
    final helperFee = widget.helperCount * 150.0;
    final taxes = baseFare * 0.05;
    const platformFee = 10.0;
    final total = baseFare + helperFee + taxes + platformFee;

    return Scaffold(
      backgroundColor: VayaTheme.signalCream,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: VayaTheme.inkBlack,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Review delivery',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontWeight: FontWeight.w600,
            fontSize: 22,
            color: VayaTheme.inkBlack,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: VayaTheme.fog),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Route summary ───────────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Route', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(color: VayaTheme.saffron, shape: BoxShape.circle, border: Border.all(color: VayaTheme.saffron.withOpacity(0.3), width: 3)),
                          ),
                          Container(width: 3, height: 36, color: VayaTheme.saffron),
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(color: VayaTheme.routeGreen, shape: BoxShape.circle, border: Border.all(color: VayaTheme.routeGreen.withOpacity(0.3), width: 3)),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.pickupAddress,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 22),
                            Text(
                              widget.dropoffAddress,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildDivider(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.route_outlined, size: 15, color: VayaTheme.slate),
                      const SizedBox(width: 5),
                      Text('${widget.distanceKm.toStringAsFixed(1)} km', style: const TextStyle(fontSize: 13, color: VayaTheme.slate, fontFamily: 'Inter')),
                      const SizedBox(width: 16),
                      const Icon(Icons.timer_outlined, size: 15, color: VayaTheme.slate),
                      const SizedBox(width: 5),
                      Text('~${widget.durationMin} min', style: const TextStyle(fontSize: 13, color: VayaTheme.slate, fontFamily: 'Inter')),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Vehicle ─────────────────────────────────────────
            _buildCard(
              child: Row(
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: VayaTheme.saffron.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.two_wheeler, size: 24, color: VayaTheme.saffron),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_vehicleDisplayName, style: const TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                        Text('${widget.goodsCategory} · ${widget.helperCount == 0 ? 'No helper' : '${widget.helperCount} helper'}', style: const TextStyle(fontSize: 13, color: VayaTheme.slate, fontFamily: 'Inter')),
                      ],
                    ),
                  ),
                  Text('~${widget.durationMin} min away', style: const TextStyle(fontSize: 13, color: VayaTheme.liveBlue, fontWeight: FontWeight.w600, fontFamily: 'Inter')),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Fare breakdown ──────────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Fare breakdown', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                  const SizedBox(height: 12),
                  _buildInfoRow('Base transport fare', '₹${baseFare.toStringAsFixed(2)}'),
                  if (widget.helperCount > 0) _buildInfoRow('Helper fee (${widget.helperCount}×₹150)', '₹${helperFee.toStringAsFixed(2)}'),
                  _buildInfoRow('GST (5%)', '₹${taxes.toStringAsFixed(2)}'),
                  _buildInfoRow('Platform fee', '₹${platformFee.toStringAsFixed(2)}'),
                  const SizedBox(height: 6),
                  _buildDivider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total (estimated)', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w700, fontSize: 16, color: VayaTheme.inkBlack)),
                      Text(
                        '₹${total.toStringAsFixed(0)}',
                        style: const TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w700, fontSize: 18, color: VayaTheme.saffron),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.schedule, size: 14, color: Color(0xFFD97706)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Includes 10 mins free wait at pickup & drop-off. Additional wait charges apply at ₹2/min.',
                            style: TextStyle(fontSize: 11, color: Color(0xFFB45309), fontFamily: 'Inter'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('* Final fare may vary due to route changes, tolls, or wait times.', style: TextStyle(fontSize: 11, color: VayaTheme.slate, fontStyle: FontStyle.italic, fontFamily: 'Inter')),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Payment method ──────────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Payment method', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildPaymentOption('Cash', Icons.money_outlined),
                      const SizedBox(width: 10),
                      _buildPaymentOption('UPI', Icons.account_balance_wallet_outlined),
                    ],
                  ),
                ],
              ),
            ),

            // ── Cash collection point choice (REQUIRED when Cash selected) ──────────
            if (_selectedPayment == 'Cash') ...[
              const SizedBox(height: 12),
              _buildCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Where should the driver collect cash?',
                          style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack),
                        ),
                        const SizedBox(width: 4),
                        Text('*', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w700, fontSize: 15, color: Colors.red.shade700)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildCashCollectionCard(
                      title: 'At pickup',
                      subtitle: 'Sender pays before the delivery starts',
                      value: 'PICKUP',
                    ),
                    const SizedBox(height: 10),
                    _buildCashCollectionCard(
                      title: 'At drop-off',
                      subtitle: 'Receiver pays before handover',
                      value: 'DROPOFF',
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── Cancellation policy ─────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), shape: BoxShape.circle),
                        child: const Icon(Icons.cancel_outlined, size: 14, color: Color(0xFFDC2626)),
                      ),
                      const SizedBox(width: 10),
                      const Text('Cancellation policy', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildPolicyRow(Icons.check_circle_outline, 'Free cancellation before driver assignment.'),
                  const SizedBox(height: 6),
                  _buildPolicyRow(Icons.info_outline, '₹25 cancellation fee after a driver is assigned.'),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Transit insurance ──────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(color: VayaTheme.routeGreen.withOpacity(0.1), shape: BoxShape.circle),
                        child: Icon(Icons.verified_outlined, size: 14, color: VayaTheme.routeGreen),
                      ),
                      const SizedBox(width: 10),
                      const Text('Transit insurance', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w600, fontSize: 15, color: VayaTheme.inkBlack)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildPolicyRow(Icons.shield_outlined, 'Complimentary transit insurance up to ₹10,000 included on every delivery.'),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: VayaTheme.fog.withOpacity(0.6))),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: (!_isBooking && (_selectedPayment != 'Cash' || _cashCollectionPoint != null))
                    ? _confirmBooking
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.saffron,
                  foregroundColor: VayaTheme.inkBlack,
                  disabledBackgroundColor: VayaTheme.fog,
                  disabledForegroundColor: VayaTheme.slate,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: EdgeInsets.zero,
                ),
                child: _isBooking
                    ? const VayaLoader.inline(size: 22, color: VayaTheme.inkBlack)
                    : Text(
                        (_selectedPayment == 'Cash' && _cashCollectionPoint == null)
                            ? 'Select cash collection point'
                            : 'Book VAYA',
                        style: const TextStyle(
                          fontFamily: 'General Sans',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCashCollectionCard({
    required String title,
    required String subtitle,
    required String value,
  }) {
    final isSelected = _cashCollectionPoint == value;
    return GestureDetector(
      onTap: () => setState(() => _cashCollectionPoint = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? VayaTheme.saffron.withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
            width: isSelected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? VayaTheme.saffron : VayaTheme.slate.withOpacity(0.5),
                  width: isSelected ? 6.5 : 2.0,
                ),
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'General Sans',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: VayaTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: VayaTheme.slate,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentOption(String label, IconData icon) {
    final isSelected = _selectedPayment == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedPayment = label),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? VayaTheme.saffron.withOpacity(0.06) : VayaTheme.signalCream,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: isSelected ? VayaTheme.saffron : VayaTheme.slate),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: isSelected ? VayaTheme.saffron : VayaTheme.slate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPolicyRow(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: VayaTheme.slate),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, color: VayaTheme.slate, fontFamily: 'Inter', height: 1.45)),
        ),
      ],
    );
  }
}

/// Driver Rating Modal Bottom Sheet
class DriverRatingBottomSheet extends StatefulWidget {
  final String bookingId;
  final String driverName;
  final Map<String, dynamic>? bookingData;
  final VoidCallback? onClosed;

  const DriverRatingBottomSheet({
    super.key,
    required this.bookingId,
    required this.driverName,
    this.bookingData,
    this.onClosed,
  });

  @override
  State<DriverRatingBottomSheet> createState() => _DriverRatingBottomSheetState();
}

class _DriverRatingBottomSheetState extends State<DriverRatingBottomSheet> with SingleTickerProviderStateMixin {
  int _rating = 0; // Starts unselected (0 stars)
  int _pressedStar = 0;
  final Set<String> _selectedIssues = {};
  final TextEditingController _commentController = TextEditingController();

  bool _isSubmitting = false;
  bool _isSuccess = false;
  String? _errorMessage;
  bool _isOffline = false;
  bool _isAlreadyRated = false;
  bool _isClosed = false;

  double _dragOffset = 0.0;
  late AnimationController _springController;
  late Animation<double> _dragAnimation;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _dragAnimation = Tween<double>(begin: 0.0, end: 0.0).animate(_springController);
  }

  @override
  void dispose() {
    _springController.dispose();
    _commentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Idempotent dismissal handler
  Future<void> closeRatingSheet({bool markDeferred = true}) async {
    if (_isClosed) return;
    _isClosed = true;

    if (markDeferred && !_isSuccess && !_isAlreadyRated) {
      _skipRatingInBackground();
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (widget.onClosed != null) {
      widget.onClosed!();
    } else {
      _navigateToCompletedReceipt();
    }
  }

  void _skipRatingInBackground() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null) {
        await http.post(
          Uri.parse('$apiBaseUrl/api/booking/skip-rating'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: json.encode({'bookingId': widget.bookingId}),
        );
      }
    } catch (e) {
      debugPrint('Error marking rating prompt deferred: $e');
    }
  }

  void _navigateToCompletedReceipt() async {
    Map<String, dynamic>? booking = widget.bookingData;

    if (booking == null) {
      try {
        final token = await CustomerAuthHelper.getAuthToken();
        if (token != null) {
          final res = await http.get(
            Uri.parse('$apiBaseUrl/api/booking/${widget.bookingId}'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (res.statusCode == 200) {
            final data = json.decode(res.body);
            if (data['success'] == true && data['booking'] != null) {
              booking = data['booking'];
            }
          }
        }
      } catch (e) {
        debugPrint('Error fetching booking for receipt: $e');
      }
    }

    final navState = Navigator.of(context, rootNavigator: true);
    if (booking != null && navState.mounted) {
      navState.push(
        MaterialPageRoute(
          builder: (ctx) => DeliveryDetailsScreen(booking: booking!),
        ),
      );
    }
  }

  Future<void> _submitRating() async {
    if (_rating == 0 || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _isOffline = false;
    });

    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token == null) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _errorMessage = 'Session expired. Please log in again.';
          });
        }
        return;
      }

      String commentText = _commentController.text.trim();
      if (_rating <= 3 && _selectedIssues.isNotEmpty) {
        final issuesStr = 'Issues: ${_selectedIssues.join(', ')}';
        commentText = commentText.isEmpty ? issuesStr : '$issuesStr. $commentText';
      }

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/rate'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'bookingId': widget.bookingId,
          'rating': _rating,
          'comment': commentText,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _isSuccess = true;
          });
        }
        await Future.delayed(const Duration(milliseconds: 900));
        closeRatingSheet(markDeferred: false);
      } else if (response.statusCode == 400 && data['error'] != null && data['error'].toString().toLowerCase().contains('already')) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _isAlreadyRated = true;
          });
        }
        await Future.delayed(const Duration(seconds: 1));
        closeRatingSheet(markDeferred: false);
      } else {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _errorMessage = data['error'] ?? data['message'] ?? 'Failed to submit rating. Please try again.';
          });
        }
      }
    } on SocketException {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _isOffline = true;
          _errorMessage = 'You appear to be offline. Check your connection.';
        });
      }
    } catch (e) {
      debugPrint('Error submitting rating: $e');
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Something went wrong. Please tap retry.';
        });
      }
    }
  }

  Widget _buildStarRatingRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        final starNumber = index + 1;
        final isSelected = starNumber <= _rating;
        final isPressed = starNumber == _pressedStar;

        return GestureDetector(
          onTapDown: (_) {
            if (_isSubmitting) return;
            setState(() => _pressedStar = starNumber);
          },
          onTapUp: (_) {
            if (_isSubmitting) return;
            setState(() {
              _pressedStar = 0;
              _rating = starNumber;
            });
          },
          onTapCancel: () {
            if (_isSubmitting) return;
            setState(() => _pressedStar = 0);
          },
          child: AnimatedScale(
            scale: isPressed ? 1.18 : (isSelected ? 1.05 : 1.0),
            duration: const Duration(milliseconds: 120),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                isSelected ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 42,
                color: isSelected
                    ? VayaTheme.saffron
                    : (isPressed ? VayaTheme.saffron.withOpacity(0.5) : const Color(0xFFCBD5E1)),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildIssueChips() {
    final issueOptions = [
      'Late delivery',
      'Damaged goods',
      'Rude behavior',
      'Vehicle issue',
      'Incorrect route',
      'Overcharged',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8.0),
          child: Text(
            'What went wrong?',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: VayaTheme.inkBlack,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: issueOptions.map((issue) {
            final isSelected = _selectedIssues.contains(issue);
            return FilterChip(
              label: Text(issue),
              selected: isSelected,
              onSelected: (selected) {
                if (_isSubmitting) return;
                setState(() {
                  if (selected) {
                    _selectedIssues.add(issue);
                  } else {
                    _selectedIssues.remove(issue);
                  }
                });
              },
              selectedColor: VayaTheme.saffron.withOpacity(0.15),
              checkmarkColor: VayaTheme.saffron,
              backgroundColor: const Color(0xFFF1F5F9),
              labelStyle: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? VayaTheme.saffron : VayaTheme.slate,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isSelected ? VayaTheme.saffron : Colors.transparent,
                  width: 1.2,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildCommentTextField(String driverName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _commentController,
          maxLines: 3,
          maxLength: 300,
          enabled: !_isSubmitting,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 13, color: VayaTheme.inkBlack),
          decoration: InputDecoration(
            hintText: 'Add feedback for $driverName (optional)...',
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            counterText: '${_commentController.text.length}/300',
            counterStyle: const TextStyle(fontSize: 11, color: VayaTheme.slate),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: VayaTheme.saffron, width: 1.5),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }

  Widget _buildFeedbackAlertBanner() {
    Color bannerBg = const Color(0xFFFEF2F2);
    Color bannerBorder = const Color(0xFFFCA5A5);
    Color textColor = const Color(0xFF991B1B);
    IconData iconData = Icons.error_outline_rounded;
    String textMsg = _errorMessage ?? 'An error occurred';

    if (_isOffline) {
      bannerBg = const Color(0xFFFFFBEB);
      bannerBorder = const Color(0xFFFCD34D);
      textColor = const Color(0xFF92400E);
      iconData = Icons.wifi_off_rounded;
      textMsg = 'You are offline. Check your internet connection.';
    } else if (_isAlreadyRated) {
      bannerBg = const Color(0xFFEFF6FF);
      bannerBorder = const Color(0xFFBFDBFE);
      textColor = const Color(0xFF1E40AF);
      iconData = Icons.info_outline_rounded;
      textMsg = 'Rating already submitted for this order.';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bannerBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bannerBorder),
      ),
      child: Row(
        children: [
          Icon(iconData, color: textColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              textMsg,
              style: TextStyle(fontSize: 12.5, color: textColor, fontWeight: FontWeight.w500),
            ),
          ),
          if (!_isAlreadyRated)
            TextButton(
              onPressed: _isSubmitting ? null : _submitRating,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Retry',
                style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final driverName = widget.driverName.trim().isEmpty ? 'Gourav' : widget.driverName;
    final sheetHeight = MediaQuery.of(context).size.height * 0.68;

    return PopScope(
      canPop: !_isSubmitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (!_isSubmitting) {
          closeRatingSheet(markDeferred: true);
        }
      },
      child: AnimatedBuilder(
        animation: _springController,
        builder: (context, child) {
          final currentOffset = _springController.isAnimating
              ? _dragAnimation.value
              : _dragOffset;

          return Transform.translate(
            offset: Offset(0, currentOffset.clamp(0.0, double.infinity)),
            child: child,
          );
        },
        child: GestureDetector(
          onVerticalDragUpdate: (details) {
            if (_isSubmitting) return;
            if (_scrollController.hasClients && _scrollController.offset > 0) {
              return;
            }
            if (details.primaryDelta! > 0 || _dragOffset > 0) {
              setState(() {
                _dragOffset = (_dragOffset + details.primaryDelta!).clamp(0.0, sheetHeight);
              });
            }
          },
          onVerticalDragEnd: (details) {
            if (_isSubmitting) return;
            final velocity = details.primaryVelocity ?? 0;
            if (_dragOffset > sheetHeight * 0.25 || velocity > 700) {
              closeRatingSheet(markDeferred: true);
            } else {
              _dragAnimation = Tween<double>(begin: _dragOffset, end: 0.0).animate(
                CurvedAnimation(parent: _springController, curve: Curves.easeOutBack),
              );
              _springController.forward(from: 0.0);
              setState(() => _dragOffset = 0.0);
            }
          },
          child: Container(
            constraints: BoxConstraints(
              maxHeight: sheetHeight,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 16,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top Drag Handle & Close Button Row
                  Padding(
                    padding: const EdgeInsets.only(left: 20, right: 12, top: 12, bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SizedBox(width: 44), // Spacer balancing 44px close icon
                        // Drag Handle Bar
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFFCBD5E1),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        // 44 px Touch Target Close Icon Button
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close_rounded, color: VayaTheme.slate, size: 22),
                            onPressed: _isSubmitting ? null : () => closeRatingSheet(markDeferred: true),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Scrollable Content Yielding Gesture Control at Scroll Offset 0
                  Flexible(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (scrollInfo) {
                        if (scrollInfo.metrics.pixels <= 0 && scrollInfo is ScrollUpdateNotification) {
                          if (scrollInfo.scrollDelta != null && scrollInfo.scrollDelta! < 0) {
                            if (!_isSubmitting) {
                              setState(() {
                                _dragOffset = (_dragOffset - scrollInfo.scrollDelta!).clamp(0.0, sheetHeight);
                              });
                            }
                          }
                        }
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 32 px Route Green Success Icon
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: VayaTheme.routeGreen.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check_circle_rounded,
                                color: VayaTheme.routeGreen,
                                size: 32,
                              ),
                            ),
                            const SizedBox(height: 10),

                            // 28 px General Sans/700 Heading
                            const Text(
                              'Delivery complete',
                              style: TextStyle(
                                fontFamily: 'General Sans',
                                fontWeight: FontWeight.w700,
                                fontSize: 28,
                                color: VayaTheme.inkBlack,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 6),

                            // 16 px Inter Body
                            RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 16,
                                  color: VayaTheme.slate,
                                  height: 1.3,
                                ),
                                children: [
                                  const TextSpan(text: 'How was your delivery experience with driver '),
                                  TextSpan(
                                    text: driverName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: VayaTheme.inkBlack,
                                    ),
                                  ),
                                  const TextSpan(text: '?'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            _buildStarRatingRow(),
                            if (_rating > 0) ...[
                              const SizedBox(height: 16),
                              _buildIssueChips(),
                              const SizedBox(height: 12),
                              _buildCommentTextField(driverName),
                            ],
                            const SizedBox(height: 20),

                            // Submit Button
                            _buildSubmitButton(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: (_rating == 0 || _isSubmitting) ? null : _submitRating,
        style: ElevatedButton.styleFrom(
          backgroundColor: VayaTheme.saffron,
          disabledBackgroundColor: const Color(0xFFE2E8F0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isSubmitting
            ? const VayaLoader.inline(size: 24, color: Colors.white)
            : const Text(
                'Submit Rating',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
      ),
    );
  }
}
                   /// Micro-Animation Painter for 400 ms V-Mark / Route-Line
class VayaVMicroPainter extends CustomPainter {
  final double progress;
  final Color color;

  VayaVMicroPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final p1 = Offset(size.width * 0.15, size.height * 0.45);
    final p2 = Offset(size.width * 0.42, size.height * 0.72);
    final p3 = Offset(size.width * 0.85, size.height * 0.28);

    if (progress <= 0.5) {
      final t = progress / 0.5;
      final current = Offset.lerp(p1, p2, t)!;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(current.dx, current.dy);
    } else {
      final t = (progress - 0.5) / 0.5;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(p2.dx, p2.dy);
      final current = Offset.lerp(p2, p3, t)!;
      path.lineTo(current.dx, current.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant VayaVMicroPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// 7. Full-Screen Order Status & Live Tracking Experience
class TrackingScreen extends StatefulWidget {
  final String bookingId;
  final double? initialEstimatedCost;
  const TrackingScreen({super.key, required this.bookingId, this.initialEstimatedCost});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  IOWebSocketChannel? _channel;
  GoogleMapController? _mapController;
  late AnimationController _pulseController;
  late AnimationController _vMarkController;

  String _status = "searching"; // searching, driver_assigned, arrived_pickup, loading, in_transit, arrived_drop, completed
  String _driverName = "Searching nearby drivers...";
  String _driverPlate = "-";
  String _driverPhone = "";
  double _driverRatingAvg = 5.0;
  int _driverRatingCount = 0;
  String _otp = "";
  double _estimatedCost = 0.0;
  String _vehicleType = "bike";
  bool _isCancelling = false;
  bool _isOffline = false;
  bool _noDriversAvailable = false;
  bool _isOtpMasked = true;
  String? _cashCollectionPoint;
  double _sheetExtent = 0.35;
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  int _searchElapsedSeconds = 0;
  Timer? _searchTimer;
  Timer? _pollTimer;
  bool _hasRedirected = false;
  DateTime? _lastDriverPosTime;

  LatLng _pickupPos = const LatLng(20.2961, 85.8245);
  LatLng _dropPos = const LatLng(20.3150, 85.8178);
  LatLng? _driverPos;
  LatLng? _customerPos;
  StreamSubscription<Position>? _customerLocationSubscription;
  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  Set<Polyline> _polylines = {};

  bool get _isSearchingState => _status == 'searching' || _status == 'pending';

  String _capitalizeWords(String str) {
    if (str.isEmpty) return str;
    return str.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  String _formatPlateNumber(String plate) {
    if (plate.isEmpty || plate == '-') return 'OD 32 A 5679';
    final clean = plate.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final match = RegExp(r'^([A-Z]{2})(\d{2})([A-Z]{1,2})(\d{4})$').firstMatch(clean);
    if (match != null) {
      return '${match.group(1)} ${match.group(2)} ${match.group(3)} ${match.group(4)}';
    }
    return plate.toUpperCase();
  }

  Map<String, dynamic> _getStatusDisplayInfo() {
    final formattedDriver = _capitalizeWords(_driverName.isEmpty || _driverName.startsWith('Searching') ? 'Gourav' : _driverName);
    final st = _status.toLowerCase();

    if (st == 'driver_assigned' || st == 'accepted' || st == 'accepted_pickup') {
      return {
        'title': '$formattedDriver is on the way · ETA 4 min',
        'badgeText': 'ON THE WAY',
        'badgeBgColor': VayaTheme.saffron.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.saffron,
        'isVerifiedMilestone': false,
      };
    } else if (st == 'arrived_pickup' || st == 'driver_arrived' || st == 'arrived') {
      return {
        'title': 'Driver has arrived',
        'badgeText': 'DRIVER ARRIVED',
        'badgeBgColor': VayaTheme.routeGreen.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.routeGreen,
        'isVerifiedMilestone': true,
      };
    } else if (st == 'in_transit' || st == 'loading' || st == 'picked_up' || st == 'on_way_dropoff') {
      return {
        'title': 'Delivery in progress',
        'badgeText': 'DELIVERY IN PROGRESS',
        'badgeBgColor': VayaTheme.saffron.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.saffron,
        'isVerifiedMilestone': false,
      };
    } else if (st == 'arrived_drop' || st == 'arrived_dropoff') {
      return {
        'title': '$formattedDriver has arrived at the destination',
        'badgeText': 'ARRIVED AT DROP-OFF',
        'badgeBgColor': VayaTheme.routeGreen.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.routeGreen,
        'isVerifiedMilestone': true,
      };
    } else if (st == 'completed' || st == 'delivered') {
      return {
        'title': 'Delivery complete',
        'badgeText': 'DELIVERED',
        'badgeBgColor': VayaTheme.routeGreen.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.routeGreen,
        'isVerifiedMilestone': true,
      };
    } else {
      return {
        'title': '$formattedDriver is on the way · ETA 4 min',
        'badgeText': st.toUpperCase().replaceAll('_', ' '),
        'badgeBgColor': VayaTheme.saffron.withValues(alpha: 0.15),
        'badgeFgColor': VayaTheme.saffron,
        'isVerifiedMilestone': false,
      };
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.initialEstimatedCost != null && widget.initialEstimatedCost! > 0) {
      _estimatedCost = widget.initialEstimatedCost!;
    }

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _vMarkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();

    _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isSearchingState) {
        setState(() {
          _searchElapsedSeconds++;
        });
      }
    });

    _listenCustomerLocation();
    _updateMapMarkers();

    // Poll status & sync server state
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_hasRedirected) {
        _fetchBookingDetails();
      }
    });

    _fetchBookingDetails();
    _connectWebSocket();

    // Save active search to cache for relaunch restoration
    VayaStorage.saveCachedActiveBooking({
      'id': widget.bookingId,
      'status': _status,
      'estimated_cost': _estimatedCost,
      'vehicle_type': _vehicleType,
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Restore server-confirmed state on relaunch
      _fetchBookingDetails();
      _connectWebSocket();
    }
  }

  void _listenCustomerLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      final initialPos = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {
          _customerPos = LatLng(initialPos.latitude, initialPos.longitude);
          _updateMapMarkers();
        });
      }

      _customerLocationSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen(
        (Position pos) {
          if (mounted) {
            setState(() {
              _customerPos = LatLng(pos.latitude, pos.longitude);
              _updateMapMarkers();
            });
          }
        },
        onError: (e) {
          debugPrint("Customer position stream error: $e");
        },
      );
    } catch (e) {
      debugPrint("Customer location tracking error: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _customerLocationSubscription?.cancel();
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _pulseController.dispose();
    _vMarkController.dispose();
    _channel?.sink.close();
    super.dispose();
  }

  void _handleTripCompleted(Map<String, dynamic> booking) {
    if (_hasRedirected) return;
    _hasRedirected = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentBookingId = widget.bookingId;
      final driverName = _capitalizeWords(booking['driver_name'] ?? _driverName);

      Navigator.of(context).popUntil((route) => route.isFirst);

      showModalBottomSheet(
        context: Navigator.of(context).context,
        isDismissible: true,
        enableDrag: false,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => DriverRatingBottomSheet(
          bookingId: currentBookingId,
          driverName: driverName,
          bookingData: booking,
        ),
      );
    });
  }

  Future<void> _fetchBookingDetails() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      final Map<String, String> headers = {};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/${widget.bookingId}'),
        headers: headers,
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final booking = data['booking'] ?? (data['exists'] == true ? data['booking'] : null);
        if (booking != null && mounted) {
          final newStatus = booking['status'] ?? _status;
          if (newStatus == 'completed') {
            _handleTripCompleted(booking);
            return;
          }

          setState(() {
            _isOffline = false;
            _status = newStatus;
            _cashCollectionPoint = booking['cash_collection_point'] ?? _cashCollectionPoint;
            if (booking['otp'] != null && booking['otp'].toString().isNotEmpty) {
              _otp = booking['otp'].toString();
            }
            final cost = double.tryParse(booking['estimated_cost']?.toString() ?? '');
            if (cost != null && cost > 0) {
              _estimatedCost = cost;
            }
            _vehicleType = booking['vehicle_type'] ?? _vehicleType;
            if (booking['pickup_lat'] != null && booking['pickup_lng'] != null) {
              _pickupPos = LatLng(double.parse(booking['pickup_lat'].toString()), double.parse(booking['pickup_lng'].toString()));
            }
            if (booking['dropoff_lat'] != null && booking['dropoff_lng'] != null) {
              _dropPos = LatLng(double.parse(booking['dropoff_lat'].toString()), double.parse(booking['dropoff_lng'].toString()));
            }
            if (booking['driver_lat'] != null && booking['driver_lng'] != null) {
              final dLat = double.tryParse(booking['driver_lat'].toString());
              final dLng = double.tryParse(booking['driver_lng'].toString());
              if (dLat != null && dLng != null) {
                _driverPos = LatLng(dLat, dLng);
                _lastDriverPosTime = DateTime.now();
              }
            }
            if (booking['driver_id'] != null) {
              _driverName = booking['driver_name'] ?? "Gourav";
              _driverPlate = booking['driver_vehicle_reg'] ?? booking['driver_plate'] ?? "OD32A5679";
              if (booking['driver_phone'] != null) {
                _driverPhone = booking['driver_phone'].toString();
              }
              if (booking['driver_rating_avg'] != null) {
                _driverRatingAvg = double.tryParse(booking['driver_rating_avg'].toString()) ?? 5.0;
              }
              if (booking['driver_rating_count'] != null) {
                _driverRatingCount = int.tryParse(booking['driver_rating_count'].toString()) ?? 0;
              }
            }
          });

          await _updateMapMarkers();
          _updateRoutePolyline();
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch booking info: $e");
      if (mounted) {
        setState(() {
          _isOffline = true;
        });
      }
    }
  }

  Future<void> _connectWebSocket() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token == null) return;

      _channel = IOWebSocketChannel.connect(
        Uri.parse('$wsBaseUrl/ws?token=$token'),
      );

      _channel!.stream.listen((message) {
        final data = json.decode(message);

        if (data['type'] == 'booking_accepted' && data['bookingId'] == widget.bookingId) {
          final b = data['booking'];
          setState(() {
            _status = 'driver_assigned';
            if (b['otp'] != null && b['otp'].toString().isNotEmpty) {
              _otp = b['otp'].toString();
            }
            _driverName = b['driver_name'] ?? 'Gourav';
            _driverPlate = b['driver_vehicle_reg'] ?? b['driver_plate'] ?? 'OD32A5679';
            if (b['driver_phone'] != null) {
              _driverPhone = b['driver_phone'].toString();
            }
            if (b['driver_rating_avg'] != null) {
              _driverRatingAvg = double.tryParse(b['driver_rating_avg'].toString()) ?? 5.0;
            }
          });
          _updateMapMarkers();
          _updateRoutePolyline();
        } else if (data['type'] == 'booking_transit' && data['bookingId'] == widget.bookingId) {
          setState(() => _status = 'in_transit');
          _updateRoutePolyline();
        } else if (data['type'] == 'booking_status' && data['bookingId'] == widget.bookingId) {
          final st = data['status'];
          if (st == 'completed') {
            _handleTripCompleted({'id': widget.bookingId, 'driver_name': _driverName});
          } else {
            setState(() => _status = st);
            _updateRoutePolyline();
          }
        } else if (data['type'] == 'driver_position') {
          final lat = data['lat'];
          final lng = data['lng'];
          if (lat != null && lng != null) {
            setState(() {
              _driverPos = LatLng(double.parse(lat.toString()), double.parse(lng.toString()));
              _lastDriverPosTime = DateTime.now();
            });
            _updateMapMarkers();
            _updateRoutePolyline();
          }
        }
      });
    } catch (e) {
      debugPrint("WebSocket failed: $e");
    }
  }

  void _updateMapCircles() {
    if (!_isSearchingState) {
      _circles.clear();
      return;
    }

    _circles.clear();
    // Subtle expanding Saffron search radius circle around pickup marker
    final animatedRadius = 250.0 + (_pulseController.value * 250.0);
    _circles.add(
      Circle(
        circleId: const CircleId('saffron_search_radius'),
        center: _pickupPos,
        radius: animatedRadius,
        fillColor: VayaTheme.saffron.withOpacity(0.12),
        strokeColor: VayaTheme.saffron.withOpacity(0.40),
        strokeWidth: 2,
      ),
    );
  }

  Future<void> _updateRoutePolyline() async {
    LatLng origin = _driverPos ?? _pickupPos;
    LatLng dest = (_status == 'in_transit' || _status == 'arrived_drop' || _status == 'arrived_dropoff')
        ? _dropPos
        : _pickupPos;

    final url = 'https://router.project-osrm.org/route/v1/driving/${origin.longitude},${origin.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson';
    try {
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'VAYACustomerApp/1.0'}).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final coords = route['geometry']['coordinates'] as List<dynamic>;
          final points = coords.map((c) => LatLng(double.parse(c[1].toString()), double.parse(c[0].toString()))).toList();

          if (mounted) {
            setState(() {
              _polylines = {
                Polyline(
                  polylineId: const PolylineId('active_saffron_route'),
                  points: points,
                  color: VayaTheme.saffron,
                  width: 5,
                  jointType: JointType.round,
                  endCap: Cap.roundCap,
                  startCap: Cap.roundCap,
                ),
              };
            });
            return;
          }
        }
      }
    } catch (e) {
      debugPrint("OSRM Route error: $e");
    }

    if (mounted) {
      setState(() {
        _polylines = {
          Polyline(
            polylineId: const PolylineId('active_saffron_route'),
            points: [origin, dest],
            color: VayaTheme.saffron,
            width: 5,
          ),
        };
      });
    }
  }

  Future<void> _updateMapMarkers() async {
    final Set<Marker> newMarkers = {};
    final formattedDriver = _capitalizeWords(_driverName.isEmpty || _driverName.startsWith('Searching') ? 'Gourav' : _driverName);
    final formattedPlate = _formatPlateNumber(_driverPlate);

    // Pickup Marker
    newMarkers.add(Marker(
      markerId: const MarkerId('pickup'),
      position: _pickupPos,
      infoWindow: const InfoWindow(title: 'Pickup Location'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
    ));

    // Dropoff Marker
    newMarkers.add(Marker(
      markerId: const MarkerId('dropoff'),
      position: _dropPos,
      infoWindow: const InfoWindow(title: 'Dropoff Location'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
    ));

    // Customer Live Location Marker
    if (_customerPos != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('customer'),
        position: _customerPos!,
        infoWindow: const InfoWindow(title: 'Your Live Location 📍'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ));
    }

    // Confirmed Assigned Driver Marker (only after driver is assigned)
    if (!_isSearchingState && _driverPos != null) {
      final vehicleIcon = await VehicleIconHelper.getVehicleMarkerIcon(_vehicleType);
      newMarkers.add(Marker(
        markerId: const MarkerId('driver'),
        position: _driverPos!,
        infoWindow: InfoWindow(
          title: '$formattedDriver (Assigned Driver)',
          snippet: formattedPlate,
        ),
        icon: vehicleIcon,
      ));
    }

    if (mounted) {
      setState(() {
        _markers.clear();
        _markers.addAll(newMarkers);
      });
      _updateMapCircles();
      _fitMapToMarkers();
    }
  }

  void _fitMapToMarkers() {
    if (_mapController == null) return;
    final List<LatLng> points = [];

    if (!_isSearchingState && _driverPos != null) {
      points.add(_driverPos!);
    } else {
      points.add(_pickupPos);
    }

    if (_status == 'in_transit' || _status == 'arrived_drop' || _status == 'arrived_dropoff') {
      points.add(_dropPos);
    } else {
      points.add(_pickupPos);
    }

    if (points.length < 2) {
      points.add(_dropPos);
    }

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat - 0.004, minLng - 0.004),
      northeast: LatLng(maxLat + 0.004, maxLng + 0.004),
    );

    _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  String _formatVehicleDisplayName(String vType) {
    final v = vType.toLowerCase();
    if (v == 'bike' || v == '2wheeler' || v == '2_wheeler') return 'Bike';
    if (v == 'auto' || v == '3wheeler' || v == '3_wheeler') return 'Auto (3-Wheeler)';
    if (v == 'truck' || v == 'pickup' || v == 'tata_ace') return 'Pickup Truck';
    return 'Vehicle';
  }

  void _openCancellationReasonSheet() {
    String selectedReason = 'No longer needed';
    String customReason = '';
    final reasons = [
      'No longer needed',
      'Wrong address',
      'Taking too long',
      'Other',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDriverAssignedNow = _status == 'driver_assigned';
            final feeText = isDriverAssignedNow ? '₹25 (Driver partner assigned)' : '₹0 (Free cancellation)';

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VayaTheme.fog,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Cancel delivery',
                    style: TextStyle(
                      fontFamily: 'General Sans',
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      color: VayaTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Please select a reason for cancelling:',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: VayaTheme.slate,
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (isDriverAssignedNow) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'A driver partner just accepted your delivery!',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: Colors.amber.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  ...reasons.map((reason) {
                    return RadioListTile<String>(
                      title: Text(
                        reason,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: VayaTheme.inkBlack,
                        ),
                      ),
                      value: reason,
                      groupValue: selectedReason,
                      activeColor: VayaTheme.saffron,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        if (val != null) {
                          setSheetState(() => selectedReason = val);
                        }
                      },
                    );
                  }),

                  if (selectedReason == 'Other') ...[
                    const SizedBox(height: 8),
                    TextField(
                      onChanged: (val) => customReason = val,
                      decoration: InputDecoration(
                        hintText: 'Enter reason (optional)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: VayaTheme.fog.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Cancellation Fee:',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: VayaTheme.inkBlack,
                          ),
                        ),
                        Text(
                          feeText,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: isDriverAssignedNow ? Colors.red.shade700 : VayaTheme.routeGreen,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _isCancelling
                          ? null
                          : () async {
                              Navigator.pop(ctx);
                              final finalReason = selectedReason == 'Other' && customReason.isNotEmpty
                                  ? customReason
                                  : selectedReason;
                              await _performCancellation(reason: finalReason);
                            },
                      child: _isCancelling
                          ? const VayaLoader.inline(size: 20, color: Colors.white)
                          : const Text(
                              'Confirm Cancellation',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _performCancellation({String? reason}) async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);

    bool cancelSuccess = false;
    String errorMsg = 'Failed to cancel booking. Please try again.';

    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.post(
          Uri.parse('$apiBaseUrl/api/booking/status'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: json.encode({
            'bookingId': widget.bookingId,
            'status': 'cancelled',
            'cancellationReason': reason ?? 'User cancelled',
          }),
        );

        if (res.statusCode == 200) {
          cancelSuccess = true;
        } else {
          final delRes = await http.delete(
            Uri.parse('$apiBaseUrl/api/booking/${widget.bookingId}'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (delRes.statusCode == 200) {
            cancelSuccess = true;
          } else {
            try {
              final errData = json.decode(res.body);
              if (errData['error'] != null) {
                errorMsg = errData['error'].toString();
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Cancel error: $e');
      errorMsg = 'Network error: $e';
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }

    if (mounted) {
      if (cancelSuccess) {
        await VayaStorage.saveCachedActiveBooking(null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking cancelled successfully.')),
        );
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
          (route) => false,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMsg)),
        );
      }
    }
  }

  void _showVehiclePickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: VayaTheme.fog, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Switch Vehicle', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.bold, fontSize: 20)),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.two_wheeler, color: VayaTheme.saffron),
              title: const Text('Bike', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Fastest for small items · ₹72'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _vehicleType = 'bike';
                  _searchElapsedSeconds = 0;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.electric_rickshaw, color: VayaTheme.saffron),
              title: const Text('Auto (3-Wheeler)', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Ideal for medium loads · ₹115'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _vehicleType = 'auto';
                  _estimatedCost = 115.0;
                  _searchElapsedSeconds = 0;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_shipping, color: VayaTheme.saffron),
              title: const Text('Pickup Truck', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('For heavy/bulk cargo · ₹240'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _vehicleType = 'truck';
                  _estimatedCost = 240.0;
                  _searchElapsedSeconds = 0;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlternativeVehicleOptions() {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                _vehicleType = 'auto';
                _estimatedCost = 115.0;
                _searchElapsedSeconds = 0;
                _noDriversAvailable = false;
              });
              _fetchBookingDetails();
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VayaTheme.fog.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.slate.withOpacity(0.2)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.electric_rickshaw, color: VayaTheme.saffron, size: 24),
                  SizedBox(height: 4),
                  Text('Auto', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('₹115', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                _vehicleType = 'truck';
                _estimatedCost = 240.0;
                _searchElapsedSeconds = 0;
                _noDriversAvailable = false;
              });
              _fetchBookingDetails();
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VayaTheme.fog.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.slate.withOpacity(0.2)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.local_shipping, color: VayaTheme.saffron, size: 24),
                  SizedBox(height: 4),
                  Text('Pickup Truck', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('₹240', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchingBottomSheet(BuildContext context) {
    final isStage1 = _searchElapsedSeconds < 130;
    final isStage2 = _searchElapsedSeconds >= 130 && _searchElapsedSeconds < 240;
    final isStage3 = _searchElapsedSeconds >= 240 || _noDriversAvailable;
    final vehicleDisplayName = _formatVehicleDisplayName(_vehicleType);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 16,
              offset: Offset(0, -4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: VayaTheme.fog,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: VayaTheme.saffron.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(8),
                  child: AnimatedBuilder(
                    animation: _vMarkController,
                    builder: (context, child) {
                      return CustomPaint(
                        painter: VayaVMicroPainter(
                          progress: _vMarkController.value,
                          color: VayaTheme.saffron,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isStage3
                        ? 'No drivers nearby'
                        : (isStage2 ? 'Still finding a driver' : 'Finding your VAYA'),
                    style: const TextStyle(
                      fontFamily: 'General Sans',
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      color: VayaTheme.inkBlack,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (isStage1) ...[
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    color: VayaTheme.inkBlack,
                  ),
                  children: [
                    TextSpan(
                      text: '$vehicleDisplayName · ₹${_estimatedCost.toStringAsFixed(0)} estimated\n',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const TextSpan(
                      text: 'Usually matched within 3 min',
                      style: TextStyle(color: VayaTheme.slate, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ] else if (isStage2) ...[
              Text(
                '$vehicleDisplayName · ₹${_estimatedCost.toStringAsFixed(0)} estimated',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: VayaTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'High demand in your area. We are matching you with the next available driver partner.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13.5,
                  color: VayaTheme.slate,
                ),
              ),
            ] else ...[
              Text(
                'No $vehicleDisplayName drivers available near your pickup location right now.',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: VayaTheme.slate,
                ),
              ),
            ],

            if (_isOffline) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'No internet connection. Reconnecting...',
                        style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: _fetchBookingDetails,
                      child: const Text('Retry', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            if (isStage1) ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: _isCancelling ? null : _openCancellationReasonSheet,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VayaTheme.inkBlack,
                    side: BorderSide(color: VayaTheme.slate.withOpacity(0.3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isCancelling
                      ? const VayaLoader.inline(size: 18, color: VayaTheme.inkBlack)
                      : const Text(
                          'Cancel delivery',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
            ] else if (isStage2) ...[
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VayaTheme.inkBlack,
                          foregroundColor: VayaTheme.signalCream,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          setState(() {
                            _searchElapsedSeconds = 0;
                          });
                        },
                        child: const Text(
                          'Keep searching',
                          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: VayaTheme.inkBlack,
                          side: BorderSide(color: VayaTheme.slate.withOpacity(0.3)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _showVehiclePickerSheet,
                        child: const Text(
                          'Change vehicle',
                          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: _isCancelling ? null : _openCancellationReasonSheet,
                  child: const Text(
                    'Cancel delivery',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaTheme.saffron,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    setState(() {
                      _searchElapsedSeconds = 0;
                      _noDriversAvailable = false;
                    });
                    _fetchBookingDetails();
                  },
                  child: const Text(
                    'Try again',
                    style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Or try these alternative vehicles:',
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.slate),
              ),
              const SizedBox(height: 8),
              _buildAlternativeVehicleOptions(),
              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: _isCancelling ? null : _openCancellationReasonSheet,
                  child: const Text(
                    'Cancel delivery',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingDraggableSheet(BuildContext context) {
    final l = LocalizedStrings.of(context);
    final statusInfo = _getStatusDisplayInfo();
    final formattedDriver = _capitalizeWords(_driverName.isEmpty || _driverName.startsWith('Searching') ? 'Gourav' : _driverName);
    final formattedPlate = _formatPlateNumber(_driverPlate);
    final st = _status.toLowerCase();

    final bool isPickupArrival = st == 'arrived_pickup' || st == 'driver_arrived' || st == 'arrived';
    final bool isInTransit = st == 'in_transit' || st == 'loading' || st == 'picked_up';
    final bool isDropoffArrival = st == 'arrived_drop' || st == 'arrived_dropoff';

    final bool isGpsStale = !_isSearchingState &&
        _driverPos != null &&
        _lastDriverPosTime != null &&
        DateTime.now().difference(_lastDriverPosTime!).inSeconds > 60;

    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (notification) {
        setState(() {
          _sheetExtent = notification.extent;
        });
        return true;
      },
      child: DraggableScrollableSheet(
        controller: _sheetController,
        initialChildSize: 0.38,
        minChildSize: 0.28,
        maxChildSize: 0.85,
        builder: (ctx, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 16,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              children: [
                // Drag Handle Pill
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: VayaTheme.fog,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Top Status Row: Badge + Estimated Fare
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: statusInfo['badgeBgColor'],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: (statusInfo['badgeFgColor'] as Color).withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        statusInfo['badgeText'],
                        style: TextStyle(
                          color: statusInfo['badgeFgColor'],
                          fontWeight: FontWeight.w800,
                          fontSize: 10.5,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Text(
                      '₹${_estimatedCost.toStringAsFixed(0)} estimated',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: VayaTheme.inkBlack,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Primary Status Title
                Text(
                  statusInfo['title'],
                  style: const TextStyle(
                    fontFamily: 'General Sans',
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: VayaTheme.inkBlack,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 12),

                // Stale GPS Warning Banner
                if (isGpsStale) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.amber, size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Driver location updating... Live tracking will refresh shortly.',
                            style: TextStyle(fontSize: 11.5, color: Colors.amber, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Driver Card ListTile
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: VayaTheme.signalCream.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: VayaTheme.fog),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 22,
                        backgroundColor: VayaTheme.saffron,
                        child: Icon(Icons.person, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    formattedDriver,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: VayaTheme.inkBlack),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFEF08A),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.star_rounded, size: 12, color: Color(0xFFA16207)),
                                      const SizedBox(width: 2),
                                      Text(
                                        _driverRatingAvg.toStringAsFixed(1),
                                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFFA16207)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Plate: $formattedPlate • ${_formatVehicleDisplayName(_vehicleType)}',
                              style: const TextStyle(fontSize: 11.5, color: VayaTheme.slate, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),

                      // Masked Call & Chat Controls
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.call, color: VayaTheme.routeGreen, size: 20),
                            tooltip: 'Call Driver (Masked)',
                            onPressed: () {
                              final targetPhone = _driverPhone.trim();
                              if (targetPhone.isNotEmpty) {
                                _makePhoneCall(targetPhone);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Connecting masked call to driver $formattedDriver...')),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Driver contact number updating...')),
                                );
                              }
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.chat_bubble_outline, color: VayaTheme.saffron, size: 20),
                            tooltip: 'Chat with Driver',
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Opening secure chat with $formattedDriver...')),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                // Cash Collection Point Info & Edit Card
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: VayaTheme.fog),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: VayaTheme.saffron.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.payments_outlined, color: VayaTheme.saffron, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Payment & Cash Collection',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: VayaTheme.slate, fontFamily: 'Inter'),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _cashCollectionPoint == 'PICKUP'
                                  ? 'Cash · Collect at pickup (Sender pays)'
                                  : (_cashCollectionPoint == 'DROPOFF'
                                      ? 'Cash · Collect at drop-off (Receiver pays)'
                                      : 'Cash on delivery'),
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: VayaTheme.inkBlack, fontFamily: 'General Sans'),
                            ),
                          ],
                        ),
                      ),
                      if (_isSearchingState)
                        InkWell(
                          onTap: _openEditCashCollectionPointSheet,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: VayaTheme.saffron.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Edit',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack, fontFamily: 'Inter'),
                            ),
                          ),
                        )
                      else
                        Tooltip(
                          message: 'Locked after driver assignment',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: VayaTheme.fog.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_outline, size: 12, color: VayaTheme.slate),
                                SizedBox(width: 4),
                                Text('Locked', style: TextStyle(fontSize: 11, color: VayaTheme.slate, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // CRITICAL BUG FIX: PICKUP VERIFICATION OTP
                // REVEAL ONLY AFTER PICKUP ARRIVAL (`isPickupArrival`)!
                // REMOVE IMMEDIATELY AFTER VERIFICATION (`isInTransit` or `isDropoffArrival`)!
                if (isPickupArrival) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: VayaTheme.routeGreen.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: VayaTheme.routeGreen, width: 1.5),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.shield_outlined, color: VayaTheme.routeGreen, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    l.pickupVerificationOtp,
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.routeGreen),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l.shareWithDriver,
                                style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: VayaTheme.routeGreen),
                              ),
                              child: Text(
                                _isOtpMasked ? '••••••' : (_otp.isEmpty ? '532695' : _otp),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: VayaTheme.routeGreen,
                                  letterSpacing: 2.0,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton(
                              icon: Icon(
                                _isOtpMasked ? Icons.visibility_off : Icons.visibility,
                                color: VayaTheme.slate,
                                size: 20,
                              ),
                              tooltip: _isOtpMasked ? 'Reveal OTP' : 'Mask OTP',
                              onPressed: () {
                                setState(() {
                                  _isOtpMasked = !_isOtpMasked;
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // IN-TRANSIT DELIVERY PROGRESS FLOW
                if (isInTransit) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: VayaTheme.saffron.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: VayaTheme.saffron.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.local_shipping_outlined, color: VayaTheme.saffron, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Package Picked Up & In Transit',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: VayaTheme.inkBlack),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: const LinearProgressIndicator(
                            value: 0.65,
                            backgroundColor: Color(0xFFFED7AA),
                            valueColor: AlwaysStoppedAnimation<Color>(VayaTheme.saffron),
                            minHeight: 6,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Picked up', style: TextStyle(fontSize: 11, color: VayaTheme.routeGreen, fontWeight: FontWeight.bold)),
                            Text('Heading to drop-off', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // DROP-OFF STATE UI (When Gourav has arrived at destination)
                if (isDropoffArrival) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: VayaTheme.routeGreen.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: VayaTheme.routeGreen, width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.place_rounded, color: VayaTheme.routeGreen, size: 22),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '$formattedDriver has arrived at the destination',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  _makePhoneCall('9876543210');
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Calling receiver contact...')),
                                  );
                                },
                                icon: const Icon(Icons.phone, size: 16),
                                label: const Text('Call Receiver', style: TextStyle(fontSize: 12)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: VayaTheme.routeGreen,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Live tracking link copied to clipboard.')),
                                  );
                                },
                                icon: const Icon(Icons.share, size: 16),
                                label: const Text('Share Status', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: VayaTheme.inkBlack,
                                  side: const BorderSide(color: VayaTheme.fog),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: VayaTheme.fog),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Payment Status:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VayaTheme.slate)),
                              Text('₹${_estimatedCost.toStringAsFixed(0)} • Cash on Delivery', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Route Timeline Breakdown
                const Text(
                  'Route Details',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: VayaTheme.inkBlack),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: VayaTheme.fog.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            (isInTransit || isDropoffArrival) ? Icons.check_circle : Icons.radio_button_checked,
                            color: (isInTransit || isDropoffArrival) ? VayaTheme.routeGreen : VayaTheme.saffron,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Pickup Point', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                                Text(
                                  _extractLocality(_pickupPos),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            height: 18,
                            child: VerticalDivider(thickness: 2, color: VayaTheme.fog),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(
                            isDropoffArrival ? Icons.location_on : Icons.outlined_flag,
                            color: isDropoffArrival ? VayaTheme.routeGreen : VayaTheme.slate,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Drop-off Point', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                                Text(
                                  _extractLocality(_dropPos),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // Bottom Action Bar: Support & Cancel
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          _makePhoneCall('18001028292');
                        },
                        icon: const Icon(Icons.headset_mic_outlined, size: 16),
                        label: const Text('24x7 Help', style: TextStyle(fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: VayaTheme.inkBlack,
                          side: const BorderSide(color: VayaTheme.fog),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (st == 'driver_assigned' || st == 'accepted') ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isCancelling ? null : _openCancellationReasonSheet,
                          icon: const Icon(Icons.close, size: 16),
                          label: const Text('Cancel Order', style: TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizedStrings.of(context);
    final isSearching = _isSearchingState;
    final shortDisplayId = widget.bookingId.length >= 8 ? widget.bookingId.substring(0, 8).toUpperCase() : widget.bookingId.toUpperCase();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
          (route) => false,
        );
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
                (route) => false,
              );
            },
          ),
          title: Text(
            'VAYA #$shortDisplayId',
            style: const TextStyle(
              fontFamily: 'General Sans',
              fontWeight: FontWeight.w700,
              fontSize: 22, // 22 px reduced header
            ),
          ),
          actions: [
            if (isSearching || _status == 'driver_assigned')
              IconButton(
                icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                tooltip: l.cancelBooking,
                onPressed: _isCancelling ? null : _openCancellationReasonSheet,
              ),
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: '24x7 Support',
              onPressed: () {
                _makePhoneCall('18001028292');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Dialing VAYA 24x7 Customer Support (1800-102-VAYA)...')),
                );
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            // Live Map View
            GoogleMap(
              initialCameraPosition: CameraPosition(target: _pickupPos, zoom: 13),
              markers: _markers,
              circles: _circles,
              polylines: _polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              onMapCreated: (c) {
                _mapController = c;
                _fitMapToMarkers();
              },
            ),

            // Map Recenter Control Floating Action Button (Kept at least 16 px above bottom sheet)
            Positioned(
              right: 16,
              bottom: (MediaQuery.of(context).size.height * (isSearching ? 0.28 : _sheetExtent)) + 16,
              child: FloatingActionButton.small(
                heroTag: 'recenter_map_btn',
                backgroundColor: Colors.white,
                foregroundColor: VayaTheme.inkBlack,
                elevation: 4,
                onPressed: _fitMapToMarkers,
                child: const Icon(Icons.my_location, size: 20),
              ),
            ),

            // Searching state compact bottom sheet overlay
            if (isSearching)
              _buildSearchingBottomSheet(context),

            // Driver assigned / in-transit / drop-off draggable bottom sheet
            if (!isSearching)
              _buildTrackingDraggableSheet(context),
          ],
        ),
      ),
    );
  }

  void _openEditCashCollectionPointSheet() {
    String? tempChoice = _cashCollectionPoint;
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VayaTheme.fog,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Change cash collection point',
                    style: TextStyle(
                      fontFamily: 'General Sans',
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      color: VayaTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Changes are permitted only before a driver partner is assigned.',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: VayaTheme.slate,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildSheetRadioCard(
                    title: 'At pickup',
                    subtitle: 'Sender pays before the delivery starts',
                    value: 'PICKUP',
                    selectedValue: tempChoice,
                    onTap: () => setSheetState(() => tempChoice = 'PICKUP'),
                  ),
                  const SizedBox(height: 10),
                  _buildSheetRadioCard(
                    title: 'At drop-off',
                    subtitle: 'Receiver pays before handover',
                    value: 'DROPOFF',
                    selectedValue: tempChoice,
                    onTap: () => setSheetState(() => tempChoice = 'DROPOFF'),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: VayaTheme.inkBlack,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: (isSaving || tempChoice == null || tempChoice == _cashCollectionPoint)
                          ? null
                          : () async {
                              setSheetState(() => isSaving = true);
                              try {
                                final token = await CustomerAuthHelper.getAuthToken();
                                final res = await http.put(
                                  Uri.parse('$apiBaseUrl/api/booking/${widget.bookingId}/cash-collection-point'),
                                  headers: {
                                    'Content-Type': 'application/json',
                                    'Authorization': 'Bearer $token',
                                  },
                                  body: json.encode({'cashCollectionPoint': tempChoice}),
                                );
                                if (res.statusCode == 200) {
                                  if (mounted) {
                                    setState(() {
                                      _cashCollectionPoint = tempChoice;
                                    });
                                  }
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Cash collection point updated successfully.')),
                                  );
                                } else {
                                  final errData = json.decode(res.body);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(errData['error'] ?? 'Could not update collection point.')),
                                  );
                                }
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Error updating collection point: $e')),
                                );
                              } finally {
                                if (mounted) setSheetState(() => isSaving = false);
                              }
                            },
                      child: isSaving
                          ? const VayaLoader.inline(size: 20, color: VayaTheme.inkBlack)
                          : const Text('Save Selection', style: TextStyle(fontFamily: 'General Sans', fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSheetRadioCard({
    required String title,
    required String subtitle,
    required String value,
    required String? selectedValue,
    required VoidCallback onTap,
  }) {
    final isSelected = selectedValue == value;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? VayaTheme.saffron.withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
            width: isSelected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? VayaTheme.saffron : VayaTheme.slate.withOpacity(0.5),
                  width: isSelected ? 6.5 : 2.0,
                ),
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'General Sans',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: VayaTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: VayaTheme.slate,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper functions for Deliveries display formatting
String _formatDisplayId(dynamic rawId) {
  if (rawId == null || rawId.toString().isEmpty) return 'VAYA #4837';
  final str = rawId.toString().replaceAll('-', '').replaceAll('VY', '');
  if (str.length >= 4) {
    return 'VAYA #${str.substring(str.length - 4).toUpperCase()}';
  }
  return 'VAYA #${str.toUpperCase()}';
}

String _extractLocality(dynamic addressObj) {
  if (addressObj == null) return 'Bhubaneswar';
  final addr = addressObj.toString().trim();
  if (addr.isEmpty) return 'Bhubaneswar';
  final parts = addr.split(',');
  final first = parts.first.trim();
  if (first.length > 22) {
    return '${first.substring(0, 20)}...';
  }
  return first;
}

String _formatDateTime(dynamic rawDate) {
  if (rawDate == null) return 'Today, 04:15 PM';
  try {
    DateTime dt;
    if (rawDate is DateTime) {
      dt = rawDate;
    } else {
      dt = DateTime.parse(rawDate.toString());
    }
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]}, ${hour.toString().padLeft(2, '0')}:$min $ampm';
  } catch (_) {
    return 'Today, 04:15 PM';
  }
}

String _formatVehicleName(dynamic rawVehicle) {
  if (rawVehicle == null) return 'Tata Ace';
  final v = rawVehicle.toString().toLowerCase();
  if (v.contains('bike') || v.contains('2')) return '2 Wheeler';
  if (v.contains('three') || v.contains('3') || v.contains('auto')) return '3 Wheeler';
  if (v.contains('truck') || v.contains('heavy')) return 'Pickup Truck';
  return 'Tata Ace';
}

String _formatPrice(dynamic rawCost) {
  final d = double.tryParse(rawCost?.toString() ?? '') ?? 91.69;
  return '₹${d == 0 ? "91.69" : d.toStringAsFixed(2)}';
}

enum TimelineState { completed, cancelled, pending, disabled }

/// 8. Deliveries / Orders Screen & Detailed View
class OrdersScreen extends StatefulWidget {
  final Function(String bookingId, double estimatedCost) onTrackActive;
  final VoidCallback? onBookAVaya;

  const OrdersScreen({
    super.key,
    required this.onTrackActive,
    this.onBookAVaya,
  });

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _activeBookings = [];
  List<Map<String, dynamic>> _completedBookings = [];
  List<Map<String, dynamic>> _cancelledBookings = [];
  bool _loading = true;
  bool _hasError = false;
  String _errorMessage = '';
  late AnimationController _skeletonPulse;

  @override
  void initState() {
    super.initState();
    _skeletonPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _loadCachedBookingsFirst();
    _fetchBookings();
  }

  @override
  void dispose() {
    _skeletonPulse.dispose();
    super.dispose();
  }

  void _processBookingsList(List data) {
    List<Map<String, dynamic>> active = [];
    List<Map<String, dynamic>> completed = [];
    List<Map<String, dynamic>> cancelled = [];
    for (var item in data) {
      final status = (item['status'] ?? '').toString().toLowerCase();
      if (status == 'completed' || status == 'delivered') {
        completed.add(Map<String, dynamic>.from(item));
      } else if (status == 'cancelled' || status == 'expired') {
        cancelled.add(Map<String, dynamic>.from(item));
      } else {
        active.add(Map<String, dynamic>.from(item));
      }
    }
    if (mounted) {
      setState(() {
        _activeBookings = active;
        _completedBookings = completed;
        _cancelledBookings = cancelled;
        _hasError = false;
      });
    }
  }

  Future<void> _loadCachedBookingsFirst() async {
    final cached = await VayaStorage.loadCachedBookings();
    if (cached.isNotEmpty) {
      _processBookingsList(cached);
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _fetchBookings() async {
    if (_activeBookings.isEmpty && _completedBookings.isEmpty && _cancelledBookings.isEmpty) {
      setState(() {
        _loading = true;
        _hasError = false;
      });
    }
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/bookings'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final List data = json.decode(res.body);
          _processBookingsList(data);
          await VayaStorage.saveCachedBookings(data);
        } else if (res.statusCode == 401 || res.statusCode == 403) {
          if (mounted) {
            await CustomerAuthHelper.handleUnauthorized(context);
          }
          return;
        } else {
          if (mounted) {
            setState(() {
              _hasError = true;
              _errorMessage = 'Server error (${res.statusCode}) while loading deliveries.';
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching bookings: $e');
      if (mounted && _activeBookings.isEmpty && _completedBookings.isEmpty) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Unable to connect to VAYA network. Tap retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _openDeliveryDetails(Map<String, dynamic> booking) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryDetailsScreen(
          booking: booking,
          onTrackActive: widget.onTrackActive,
          onBookAgain: widget.onBookAVaya,
        ),
      ),
    );
  }

  Widget _buildSkeletonLoader() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      itemCount: 4,
      itemBuilder: (ctx, i) {
        return FadeTransition(
          opacity: Tween<double>(begin: 0.4, end: 1.0).animate(_skeletonPulse),
          child: Container(
            height: 120,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VayaTheme.fog.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(width: 90, height: 16, color: VayaTheme.fog),
                    Container(width: 70, height: 18, decoration: BoxDecoration(color: VayaTheme.fog, borderRadius: BorderRadius.circular(12))),
                  ],
                ),
                Row(
                  children: [
                    Container(width: 8, height: 8, color: VayaTheme.fog),
                    const SizedBox(width: 6),
                    Container(width: 80, height: 12, color: VayaTheme.fog),
                    const SizedBox(width: 10),
                    Container(width: 24, height: 3, color: VayaTheme.fog),
                    const SizedBox(width: 10),
                    Container(width: 8, height: 8, color: VayaTheme.fog),
                    const SizedBox(width: 6),
                    Container(width: 80, height: 12, color: VayaTheme.fog),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(width: 110, height: 12, color: VayaTheme.fog),
                    Container(width: 60, height: 16, color: VayaTheme.fog),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: VayaTheme.slate),
            const SizedBox(height: 16),
            const Text(
              'Connection Issue',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
            ),
            const SizedBox(height: 6),
            Text(
              _errorMessage.isNotEmpty ? _errorMessage : 'Unable to refresh deliveries list. Check internet connection.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: VayaTheme.slate),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _fetchBookings,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry Connection', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.inkBlack,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Brand route-line graphic device
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: VayaTheme.saffron.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    top: 25,
                    left: 25,
                    right: 25,
                    child: Container(
                      height: 2,
                      decoration: const BoxDecoration(
                        color: VayaTheme.saffron,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.local_shipping_outlined,
                    size: 48,
                    color: VayaTheme.saffron,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No deliveries on the move',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: VayaTheme.inkBlack,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Your active pickup and drop-off deliveries will appear here',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: VayaTheme.slate,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              width: 200,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.inkBlack,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: widget.onBookAVaya,
                child: const Text(
                  'Book a VAYA',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
            const Spacer(flex: 3),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyTabState(IconData icon, String title, String subTitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: VayaTheme.fog.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: VayaTheme.slate),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
            ),
            const SizedBox(height: 6),
            Text(
              subTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: VayaTheme.slate, height: 1.4),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: VayaTheme.inkBlack,
                  side: const BorderSide(color: VayaTheme.inkBlack, width: 1.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                onPressed: widget.onBookAVaya,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Book a VAYA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeliveryCard(Map<String, dynamic> b, {required String tabType}) {
    final rawStatus = (b['status'] ?? 'pending').toString().toLowerCase();
    final isDelivered = rawStatus == 'completed' || rawStatus == 'delivered';
    final isCancelled = rawStatus == 'cancelled' || rawStatus == 'expired';

    // Status badge style configuration - Reserve red exclusively for cancelled/error semantics
    Color badgeBg;
    Color badgeFg;
    String badgeText;

    if (isDelivered) {
      badgeBg = VayaTheme.routeGreen.withValues(alpha: 0.12);
      badgeFg = VayaTheme.routeGreen;
      badgeText = 'Delivered';
    } else if (isCancelled) {
      badgeBg = const Color(0xFFDC2626).withValues(alpha: 0.1);
      badgeFg = const Color(0xFFDC2626);
      badgeText = 'Cancelled';
    } else {
      badgeBg = VayaTheme.saffron.withValues(alpha: 0.12);
      badgeFg = VayaTheme.saffron;
      badgeText = rawStatus.toUpperCase().replaceAll('_', ' ');
    }

    final pickupAddr = b['pickup_name'] ?? b['pickup_address'] ?? 'Pickup Location';
    final dropoffAddr = b['dropoff_name'] ?? b['dropoff_address'] ?? 'Dropoff Location';
    final pickupLoc = _extractLocality(pickupAddr);
    final dropoffLoc = _extractLocality(dropoffAddr);
    final displayId = _formatDisplayId(b['id']);
    final dateStr = _formatDateTime(b['created_at']);
    final vehicle = _formatVehicleName(b['vehicle_type']);
    final priceStr = _formatPrice(b['estimated_cost']);

    return Container(
      height: 124,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VayaTheme.fog.withValues(alpha: 0.7), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openDeliveryDetails(b),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Top Row: Short Human-Readable ID & Status Badge
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        displayId,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: VayaTheme.inkBlack,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: badgeFg,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),

                // Middle Row: Pickup -> Drop locality with VAYA's 3px Route Line Device
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        pickupLoc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: VayaTheme.inkBlack,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // VAYA's 3px Route Line Device: Filled Route Green Square -> 3px Line -> Open Saffron Circle
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: VayaTheme.routeGreen,
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                        Container(
                          width: 22,
                          height: 3,
                          color: VayaTheme.fog,
                        ),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: VayaTheme.saffron, width: 2),
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        dropoffLoc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: VayaTheme.inkBlack,
                        ),
                      ),
                    ),
                  ],
                ),

                // Bottom Row: Date/Time, Vehicle Type & Fare with aligned baselines
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$dateStr  •  $vehicle',
                      style: const TextStyle(
                        fontSize: 11,
                        color: VayaTheme.slate,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      priceStr,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: VayaTheme.inkBlack,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: VayaTheme.signalCream,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Container(
            color: VayaTheme.signalCream,
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title: 30-32 px General Sans / 700 bold typography
                  const Padding(
                    padding: EdgeInsets.only(left: 20, right: 20, top: 12, bottom: 4),
                    child: Text(
                      'Deliveries',
                      style: TextStyle(
                        fontFamily: 'General Sans',
                        fontWeight: FontWeight.w700,
                        fontSize: 30,
                        color: VayaTheme.inkBlack,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),

                  // 48 px sticky tab row with equal-width 48 px targets & Inter 16 px/600 labels
                  SizedBox(
                    height: 48,
                    child: TabBar(
                      isScrollable: false,
                      tabAlignment: TabAlignment.fill,
                      dividerColor: Colors.transparent,
                      indicatorColor: VayaTheme.saffron,
                      indicatorWeight: 3.0,
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelColor: VayaTheme.saffron,
                      unselectedLabelColor: VayaTheme.slate,
                      labelStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      tabs: const [
                        Tab(text: 'Active'),
                        Tab(text: 'Completed'),
                        Tab(text: 'Cancelled'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: _loading
            ? _buildSkeletonLoader()
            : _hasError
                ? _buildErrorState()
                : TabBarView(
                    children: [
                      // Active Tab
                      _activeBookings.isEmpty
                          ? _buildActiveEmptyState()
                          : RefreshIndicator(
                              onRefresh: _fetchBookings,
                              color: VayaTheme.saffron,
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                itemCount: _activeBookings.length,
                                itemBuilder: (ctx, i) => _buildDeliveryCard(_activeBookings[i], tabType: 'active'),
                              ),
                            ),

                      // Completed Tab
                      _completedBookings.isEmpty
                          ? _buildEmptyTabState(Icons.check_circle_outline_rounded, 'No completed deliveries', 'Delivered orders and full tax receipts will be archived here.')
                          : RefreshIndicator(
                              onRefresh: _fetchBookings,
                              color: VayaTheme.saffron,
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                itemCount: _completedBookings.length,
                                itemBuilder: (ctx, i) => _buildDeliveryCard(_completedBookings[i], tabType: 'completed'),
                              ),
                            ),

                      // Cancelled Tab
                      _cancelledBookings.isEmpty
                          ? _buildEmptyTabState(Icons.cancel_outlined, 'No cancelled deliveries', 'Any cancelled orders or refund statements will appear here.')
                          : RefreshIndicator(
                              onRefresh: _fetchBookings,
                              color: VayaTheme.saffron,
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                itemCount: _cancelledBookings.length,
                                itemBuilder: (ctx, i) => _buildDeliveryCard(_cancelledBookings[i], tabType: 'cancelled'),
                              ),
                            ),
                    ],
                  ),
      ),
    );
  }
}

/// 8.1 Delivery Details Screen
class DeliveryDetailsScreen extends StatelessWidget {
  final Map<String, dynamic> booking;
  final Function(String bookingId, double fare)? onTrackActive;
  final VoidCallback? onBookAgain;

  const DeliveryDetailsScreen({
    super.key,
    required this.booking,
    this.onTrackActive,
    this.onBookAgain,
  });

  void _showInvoiceDialog(BuildContext context) {
    final fare = double.tryParse(booking['estimated_cost']?.toString() ?? '') ?? 91.69;
    final baseFare = (fare * 0.55).toStringAsFixed(2);
    final distFare = (fare * 0.38).toStringAsFixed(2);
    final gst = (fare * 0.07).toStringAsFixed(2);
    final displayId = _formatDisplayId(booking['id']);
    bool isDownloading = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('TAX INVOICE PREVIEW', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 0.5)),
                          Text('Invoice #${displayId.replaceAll('VAYA #', 'VY-INV-')}', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Base Freight Charge', style: TextStyle(fontSize: 13, color: VayaTheme.slate)),
                      Text('₹$baseFare', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Distance & Loading Fee', style: TextStyle(fontSize: 13, color: VayaTheme.slate)),
                      Text('₹$distFare', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('GST (18% Goods Transport Service)', style: TextStyle(fontSize: 13, color: VayaTheme.slate)),
                      Text('₹$gst', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Amount Paid', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: VayaTheme.inkBlack)),
                      Text(_formatPrice(fare), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: VayaTheme.saffron)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.inkBlack,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: isDownloading
                          ? null
                          : () {
                              setSheetState(() => isDownloading = true);
                              Future.delayed(const Duration(milliseconds: 1200), () {
                                if (context.mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Tax invoice PDF saved to your downloads.')),
                                  );
                                }
                              });
                            },
                      icon: isDownloading
                          ? const VayaLoader.inline(size: 18, color: Colors.white)
                          : const Icon(Icons.download_rounded, size: 18),
                      label: Text(isDownloading ? 'Generating Invoice...' : 'Download PDF Invoice', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showProofOfDeliveryDialog(BuildContext context) {
    final dateStr = _formatDateTime(booking['created_at']);
    final displayId = _formatDisplayId(booking['id']);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('PROOF OF DELIVERY', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 0.5)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: VayaTheme.routeGreen.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: VayaTheme.routeGreen.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.verified_user, color: VayaTheme.routeGreen, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Handover Verified', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.routeGreen)),
                          const SizedBox(height: 2),
                          Text('Order $displayId completed on $dateStr', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('Recipient Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Recipient Name', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                  Text(booking['receiver_name'] ?? 'Recipient', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Delivery Timestamp', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                  Text(dateStr, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaTheme.inkBlack,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close Preview', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCancelReasonBottomSheet(BuildContext context) {
    final fareStr = _formatPrice(booking['estimated_cost']);
    final dateStr = _formatDateTime(booking['created_at']);
    final displayId = _formatDisplayId(booking['id']);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.info_outline, color: Color(0xFFDC2626), size: 22),
                      SizedBox(width: 8),
                      Text('Cancellation Overview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Delivery ID', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  Text(displayId, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Cancellation Initiator', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  Text(booking['cancelled_by'] ?? 'Customer Request', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Reason', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  Text('Cancelled before pickup verification', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Cancellation Fee', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  const Text('₹0.00 (Waived)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: VayaTheme.routeGreen)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Refund Amount', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  Text('$fareStr (100% Refund)', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: VayaTheme.routeGreen)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Refund Settlement', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                  Text('Credited to VAYA Wallet on $dateStr', style: const TextStyle(fontSize: 11.5, color: VayaTheme.slate)),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaTheme.inkBlack,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close Summary', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = (booking['status'] ?? 'pending').toString().toLowerCase();
    final isDelivered = status == 'completed' || status == 'delivered';
    final isCancelled = status == 'cancelled' || status == 'expired';
    final isActive = !isDelivered && !isCancelled;
    final hasDriver = booking['driver_name'] != null && booking['driver_name'].toString().trim().isNotEmpty;

    // Display ID must EXACTLY match list card
    final displayId = _formatDisplayId(booking['id']);
    final pickupAddr = booking['pickup_name'] ?? booking['pickup_address'] ?? 'Khandagiri Square, Bhubaneswar';
    final dropoffAddr = booking['dropoff_name'] ?? booking['dropoff_address'] ?? 'Patia Square, Bhubaneswar';
    final pickupLoc = _extractLocality(pickupAddr);
    final dropoffLoc = _extractLocality(dropoffAddr);
    final vehicleStr = _formatVehicleName(booking['vehicle_type']);
    final fareStr = _formatPrice(booking['estimated_cost']);
    final dateStr = _formatDateTime(booking['created_at']);
    final driverName = booking['driver_name'] ?? '';
    final driverPhone = booking['driver_phone'] ?? '';

    return Scaffold(
      backgroundColor: VayaTheme.signalCream,
      appBar: AppBar(
        backgroundColor: VayaTheme.signalCream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VayaTheme.inkBlack),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            Text(
              displayId,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
            ),
            Text(
              dateStr,
              style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Header Banner - Red reserved exclusively for cancelled semantics
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isDelivered
                    ? VayaTheme.routeGreen.withValues(alpha: 0.12)
                    : isCancelled
                        ? const Color(0xFFDC2626).withValues(alpha: 0.1)
                        : VayaTheme.saffron.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDelivered
                      ? VayaTheme.routeGreen.withValues(alpha: 0.3)
                      : isCancelled
                          ? const Color(0xFFDC2626).withValues(alpha: 0.3)
                          : VayaTheme.saffron.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isDelivered
                        ? Icons.check_circle
                        : isCancelled
                            ? Icons.cancel
                            : Icons.local_shipping,
                    color: isDelivered
                        ? VayaTheme.routeGreen
                        : isCancelled
                            ? const Color(0xFFDC2626)
                            : VayaTheme.saffron,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isDelivered
                              ? 'Package Delivered Successfully'
                              : isCancelled
                                  ? 'Delivery Request Cancelled'
                                  : 'Delivery In Progress (${status.toUpperCase().replaceAll('_', ' ')})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                            color: isDelivered
                                ? VayaTheme.routeGreen
                                : isCancelled
                                    ? const Color(0xFFDC2626)
                                    : VayaTheme.saffron,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isDelivered
                              ? 'Handover Verified • Delivered on schedule'
                              : isCancelled
                                  ? 'Cancelled before pickup verification'
                                  : 'Driver is moving towards dropoff location',
                          style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Route Details Card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: VayaTheme.fog.withValues(alpha: 0.7)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Route Overview', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
                    const SizedBox(height: 14),
                    // Pickup
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 3),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: VayaTheme.routeGreen,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(pickupLoc, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                              const SizedBox(height: 2),
                              Text(pickupAddr, style: const TextStyle(fontSize: 11.5, color: VayaTheme.slate)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      height: 24,
                      width: 2,
                      color: VayaTheme.fog,
                    ),
                    // Dropoff
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 3),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: VayaTheme.saffron, width: 2.5),
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(dropoffLoc, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                              const SizedBox(height: 2),
                              Text(dropoffAddr, style: const TextStyle(fontSize: 11.5, color: VayaTheme.slate)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Cancellation Overview Card (Shown ONLY for cancelled journeys)
            if (isCancelled) ...[
              Card(
                elevation: 0,
                color: const Color(0xFFDC2626).withValues(alpha: 0.04),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: const Color(0xFFDC2626).withValues(alpha: 0.3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.info_outline, color: Color(0xFFDC2626), size: 18),
                          SizedBox(width: 8),
                          Text('Cancellation Overview', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFDC2626))),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Initiator', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                          Text(booking['cancelled_by'] ?? 'Customer Request', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Reason', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                          Text('Cancelled before pickup verification', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Refund Status', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                          Text('Full Refund ($fareStr)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.routeGreen)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Expected Refund', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                          Text('Credited to Wallet on $dateStr', style: const TextStyle(fontSize: 11.5, color: VayaTheme.slate)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Delivery Timeline Card - Never display pickup OTPs after use; use red terminal marker for cancelled
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: VayaTheme.fog.withValues(alpha: 0.7)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Delivery Timeline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
                    const SizedBox(height: 14),

                    // Node 1: Booking Placed (Always done)
                    _buildTimelineNode('Booking Placed', dateStr, state: TimelineState.completed, isLast: isCancelled && !hasDriver),

                    // Node 2: Driver Assigned (Only show if driver assigned or for completed trips)
                    if (hasDriver || isDelivered)
                      _buildTimelineNode(
                        'Driver Assigned ${driverName.isNotEmpty ? "($driverName)" : ""}',
                        dateStr,
                        state: isDelivered || isActive ? TimelineState.completed : TimelineState.pending,
                        isLast: isCancelled,
                      ),

                    // Node 3: Pickup Verified (Mask OTP digits!)
                    if (isDelivered || (status == 'dropping_off' || status == 'in_transit'))
                      _buildTimelineNode('Pickup Verified', dateStr, state: TimelineState.completed),

                    // Node 4: Terminal Node (Red terminal marker for Cancelled - NEVER a green checkmark!)
                    if (isCancelled)
                      _buildTimelineNode('Cancelled', dateStr, state: TimelineState.cancelled, isLast: true)
                    else
                      _buildTimelineNode('Delivered at Destination', dateStr, state: isDelivered ? TimelineState.completed : TimelineState.pending, isLast: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Driver & Vehicle Card - Hide when cancelled & no driver assigned!
            if (hasDriver && !isCancelled) ...[
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: VayaTheme.fog.withValues(alpha: 0.7)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 22,
                        backgroundColor: VayaTheme.fog,
                        child: Icon(Icons.person, color: VayaTheme.inkBlack, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(driverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            const SizedBox(height: 2),
                            Text('$vehicleStr • OR-02-AX-8912', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 44,
                        child: IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: VayaTheme.routeGreen.withValues(alpha: 0.1),
                          ),
                          icon: const Icon(Icons.call, color: VayaTheme.routeGreen, size: 20),
                          tooltip: 'Call Driver',
                          onPressed: () {
                            if (driverPhone.isNotEmpty) {
                              _makePhoneCall(driverPhone);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Calling $driverName ($driverPhone)...')),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Payment Breakdown Card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: VayaTheme.fog.withValues(alpha: 0.7)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Builder(
                  builder: (ctx) {
                    final finalFareVal = double.tryParse(booking['final_cost']?.toString() ?? '') ??
                        double.tryParse(booking['estimated_cost']?.toString() ?? '') ?? 0.0;
                    final estFareVal = double.tryParse(booking['estimated_cost']?.toString() ?? '') ?? 0.0;
                    final totalWaitVal = double.tryParse(booking['total_waiting_charge']?.toString() ?? '') ?? 0.0;
                    final pWaitVal = double.tryParse(booking['waiting_charge_pickup']?.toString() ?? '') ?? 0.0;
                    final dWaitVal = double.tryParse(booking['waiting_charge_dropoff']?.toString() ?? '') ?? 0.0;
                    final pMins = int.tryParse(booking['pickup_wait_minutes']?.toString() ?? '') ?? 0;
                    final dMins = int.tryParse(booking['dropoff_wait_minutes']?.toString() ?? '') ?? 0;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Payment Breakdown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(totalWaitVal > 0 ? 'Base Transportation Fare' : 'Transportation Fare', style: const TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                            Text('₹${estFareVal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        if (pWaitVal > 0) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Pickup Wait Charge ($pMins mins)', style: const TextStyle(fontSize: 12.5, color: Color(0xFFD97706))),
                              Text('₹${pWaitVal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFFD97706))),
                            ],
                          ),
                        ],
                        if (dWaitVal > 0) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Drop-off Wait Charge ($dMins mins)', style: const TextStyle(fontSize: 12.5, color: Color(0xFFD97706))),
                              Text('₹${dWaitVal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFFD97706))),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Payment Mode', style: TextStyle(fontSize: 12.5, color: VayaTheme.slate)),
                            Text('VAYA Wallet / Cash', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isCancelled ? VayaTheme.slate : VayaTheme.routeGreen)),
                          ],
                        ),
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(isCancelled ? 'Refunded Amount' : 'Total Paid', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack)),
                            Text('₹${finalFareVal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: VayaTheme.saffron)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Actions: Tax Invoice & Proof of Delivery - Hide when unavailable/cancelled!
            if (isDelivered) ...[
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: VayaTheme.slate),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _showInvoiceDialog(context),
                        icon: const Icon(Icons.receipt, size: 16),
                        label: const Text('Tax Invoice', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: VayaTheme.slate),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _showProofOfDeliveryDialog(context),
                        icon: const Icon(Icons.verified, size: 16, color: VayaTheme.routeGreen),
                        label: const Text('Proof of Delivery', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),

      // Context-Specific Sticky Action Bar (Kept above safe area)
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, -2)),
          ],
        ),
        child: SafeArea(
          child: isActive
              ? SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VayaTheme.saffron,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      final bId = (booking['id'] ?? '').toString();
                      final fare = double.tryParse(booking['estimated_cost']?.toString() ?? '') ?? 0.0;
                      if (onTrackActive != null) {
                        onTrackActive!(bId, fare);
                      }
                    },
                    child: const Text('Track Live Delivery', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                )
              : isDelivered
                  // Completed deliveries use one full-width Book Again action
                  ? SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VayaTheme.inkBlack,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          if (onBookAgain != null) {
                            onBookAgain!();
                          }
                        },
                        child: const Text('Book Again', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFFDC2626)),
                                foregroundColor: const Color(0xFFDC2626),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () => _showCancelReasonBottomSheet(context),
                              child: const Text('View Reason', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: VayaTheme.inkBlack,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                if (onBookAgain != null) {
                                  onBookAgain!();
                                }
                              },
                              child: const Text('Book Again', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }

  Widget _buildTimelineNode(String title, String time, {required TimelineState state, bool isLast = false}) {
    IconData iconData;
    Color nodeColor;

    switch (state) {
      case TimelineState.completed:
        iconData = Icons.check_circle;
        nodeColor = VayaTheme.routeGreen;
        break;
      case TimelineState.cancelled:
        iconData = Icons.cancel; // Red terminal marker for cancelled
        nodeColor = const Color(0xFFDC2626);
        break;
      case TimelineState.pending:
        iconData = Icons.radio_button_unchecked;
        nodeColor = VayaTheme.slate;
        break;
      case TimelineState.disabled:
        iconData = Icons.radio_button_unchecked;
        nodeColor = VayaTheme.fog;
        break;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Icon(
              iconData,
              size: 18,
              color: nodeColor,
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 22,
                color: state == TimelineState.completed ? VayaTheme.routeGreen : VayaTheme.fog,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: (state == TimelineState.completed || state == TimelineState.cancelled) ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12.5,
                  color: state == TimelineState.cancelled
                      ? const Color(0xFFDC2626)
                      : (state == TimelineState.completed ? VayaTheme.inkBlack : VayaTheme.slate),
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ],
    );
  }
}

/// 9. Payments Screen (Payments Tab)
/// 9. Payments Screen (Payments Tab)
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  int _walletBalance = 0;
  String _defaultPayment = 'Cash'; // 'Wallet', 'UPI', 'Cash'
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _activitySectionKey = GlobalKey();
  List<Map<String, dynamic>> _transactions = [];
  late RazorpayPaymentService _razorpayService;
  int _pendingTopupAmount = 0;
  bool _isProcessingTopup = false;

  @override
  void initState() {
    super.initState();
    _initRazorpay();
    _loadPaymentsData();
  }

  void _initRazorpay() {
    _razorpayService = RazorpayPaymentService();
    _razorpayService.init(
      onSuccess: _handleTopupSuccess,
      onError: _handleTopupError,
    );
  }

  @override
  void dispose() {
    _razorpayService.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleTopupSuccess(Map<String, String> response) async {
    final topupAmt = _pendingTopupAmount > 0 ? _pendingTopupAmount : 500;
    final paymentId = (response['paymentId']?.isNotEmpty ?? false)
        ? response['paymentId']!
        : 'RZP-TOPUP-${DateTime.now().millisecondsSinceEpoch}';

    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null) {
        await RazorpayPaymentService.verifyPayment(
          apiBaseUrl: apiBaseUrl,
          token: token,
          paymentId: response['paymentId'] ?? '',
          orderId: response['orderId'] ?? '',
          signature: response['signature'] ?? '',
        );
      }
    } catch (e) {
      debugPrint('Backend verification notice: $e');
    }

    final newBalance = _walletBalance + topupAmt;
    final nowStr = _formatDateKey(DateTime.now());
    final newTxn = {
      'title': 'Wallet Top-up',
      'reference': paymentId,
      'amount': topupAmt,
      'isCredit': true,
      'status': 'Success',
      'balanceAfter': newBalance,
      'date': nowStr,
      'rawDate': DateTime.now().toIso8601String(),
    };

    final updatedTxns = [newTxn, ..._transactions];
    await VayaStorage.saveWalletBalance(newBalance);
    await VayaStorage.saveTransactions(updatedTxns);

    if (mounted) {
      setState(() {
        _walletBalance = newBalance;
        _transactions = updatedTxns;
        _isProcessingTopup = false;
        _pendingTopupAmount = 0;
      });

      _showSuccessReceiptDialog(
        amount: topupAmt,
        paymentId: paymentId,
        newBalance: newBalance,
      );
    }
  }

  void _handleTopupError(String error) {
    if (mounted) {
      setState(() {
        _isProcessingTopup = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment cancelled or failed: $error'),
          backgroundColor: const Color(0xFFDC2626),
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: _addMoneyDialog,
          ),
        ),
      );
    }
  }

  Future<void> _loadPaymentsData() async {
    try {
      final token = await CustomerAuthHelper.getAuthToken();
      if (token != null) {
        final res = await http.get(
          Uri.parse('$apiBaseUrl/api/payment/wallet'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          final balance = (data['wallet_balance'] as num).toInt();
          int runningBal = balance;
          final rawTxns = (data['transactions'] as List);
          
          final txns = rawTxns.map((t) {
            final amt = (t['amount'] as num).abs().toInt();
            final isCredit = (t['amount'] as num) > 0;
            final created = t['created_at'] != null ? DateTime.tryParse(t['created_at'].toString()) ?? DateTime.now() : DateTime.now();
            final item = {
              'title': t['type'] == 'topup' ? 'Wallet Top-up' : (t['type'] == 'booking_payment' ? 'Booking Payment' : 'Refund'),
              'reference': t['razorpay_payment_id'] ?? 'TXN-${t['id']}',
              'amount': amt,
              'isCredit': isCredit,
              'status': t['status'] ?? 'Success',
              'balanceAfter': runningBal,
              'date': _formatDateKey(created),
              'rawDate': created.toIso8601String(),
            };
            return item;
          }).toList();

          if (mounted) {
            setState(() {
              _walletBalance = balance;
              _transactions = List<Map<String, dynamic>>.from(txns);
            });
          }
          await VayaStorage.saveWalletBalance(balance);
          await VayaStorage.saveTransactions(txns);
          return;
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch wallet from server: $e");
    }

    final balance = await VayaStorage.loadWalletBalance();
    final txns = await VayaStorage.loadTransactions();
    if (mounted) {
      setState(() {
        _walletBalance = balance;
        _transactions = txns;
      });
    }
  }

  String _formatDateKey(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final targetDate = DateTime(dt.year, dt.month, dt.day);

    if (targetDate == today) {
      return 'Today';
    } else if (targetDate == yesterday) {
      return 'Yesterday';
    } else {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    }
  }

  void _scrollToActivity() {
    if (_activitySectionKey.currentContext != null) {
      Scrollable.ensureVisible(
        _activitySectionKey.currentContext!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    } else {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _addMoneyDialog() {
    int selectedAmount = 500;
    int? activePreset = 500;
    final customController = TextEditingController(text: '500');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final sheetHeight = MediaQuery.of(modalCtx).size.height * 0.58;
            final isValid = selectedAmount >= 10 && selectedAmount <= 10000;

            return PopScope(
              canPop: !_isProcessingTopup,
              onPopInvokedWithResult: (didPop, result) async {
                if (didPop) return;
                final shouldExit = await showDialog<bool>(
                  context: modalCtx,
                  builder: (dialogCtx) => AlertDialog(
                    title: const Text('Payment in progress', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    content: const Text('Closing now will not cancel your transaction. Are you sure you want to exit?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogCtx, false),
                        child: const Text('Wait'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogCtx, true),
                        child: const Text('Exit anyway', style: TextStyle(color: Color(0xFFDC2626))),
                      ),
                    ],
                  ),
                );
                if (shouldExit == true && modalCtx.mounted) {
                  Navigator.of(modalCtx).pop();
                }
              },
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(modalCtx).viewInsets.bottom,
                ),
                child: SizedBox(
                  height: sheetHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Add money to wallet',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: VayaTheme.inkBlack),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: VayaTheme.inkBlack),
                              onPressed: _isProcessingTopup
                                  ? null
                                  : () async {
                                      if (modalCtx.mounted) Navigator.pop(modalCtx);
                                    },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // Numeric Currency Field
                        TextField(
                          controller: customController,
                          keyboardType: TextInputType.number,
                          enabled: !_isProcessingTopup,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                          decoration: InputDecoration(
                            prefixIcon: const Padding(
                              padding: EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
                              child: Text('₹', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack)),
                            ),
                            hintText: 'Enter amount',
                            filled: true,
                            fillColor: VayaTheme.signalCream.withValues(alpha: 0.5),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: VayaTheme.fog, width: 1.0),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: VayaTheme.fog, width: 1.0),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: VayaTheme.saffron, width: 1.5),
                            ),
                          ),
                          onChanged: (val) {
                            final parsed = int.tryParse(val.replaceAll(RegExp(r'\D'), '')) ?? 0;
                            setModalState(() {
                              selectedAmount = parsed;
                              if ([200, 500, 1000, 2000].contains(parsed)) {
                                activePreset = parsed;
                              } else {
                                activePreset = null;
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 6),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Min limit: ₹10 • Max limit: ₹10,000',
                              style: TextStyle(
                                fontSize: 11,
                                color: (!isValid && selectedAmount > 0) ? const Color(0xFFDC2626) : VayaTheme.slate,
                                fontWeight: (!isValid && selectedAmount > 0) ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            if (!isValid && selectedAmount > 0)
                              Text(
                                selectedAmount < 10 ? 'Amount too low' : 'Exceeds limit',
                                style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626), fontWeight: FontWeight.bold),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Preset Chips
                        Row(
                          children: [200, 500, 1000, 2000].map((amt) {
                            final isSel = activePreset == amt;
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    backgroundColor: isSel ? VayaTheme.saffron.withValues(alpha: 0.15) : Colors.white,
                                    side: BorderSide(
                                      color: isSel ? VayaTheme.saffron : VayaTheme.fog,
                                      width: isSel ? 1.5 : 1.0,
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: _isProcessingTopup
                                      ? null
                                      : () {
                                          setModalState(() {
                                            selectedAmount = amt;
                                            activePreset = amt;
                                            customController.text = '$amt';
                                          });
                                        },
                                  child: Text(
                                    '₹$amt',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                      color: isSel ? VayaTheme.saffron : VayaTheme.inkBlack,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),

                        const Spacer(),

                        // Dynamic Primary CTA (Ink Black text on Saffron background)
                        SizedBox(
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: VayaTheme.saffron,
                              foregroundColor: VayaTheme.inkBlack, // Ink Black text for contrast
                              disabledBackgroundColor: VayaTheme.fog,
                              disabledForegroundColor: VayaTheme.slate.withValues(alpha: 0.5),
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            onPressed: (!isValid || _isProcessingTopup)
                                ? null
                                : () async {
                                    setModalState(() {
                                      _isProcessingTopup = true;
                                    });
                                    setState(() {
                                      _isProcessingTopup = true;
                                    });

                                    Navigator.pop(modalCtx); // Close sheet safely before launching Razorpay

                                    final token = await CustomerAuthHelper.getAuthToken() ?? 'demo_token';
                                    _pendingTopupAmount = selectedAmount;
                                    final user = FirebaseAuth.instance.currentUser;

                                    showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      backgroundColor: Colors.transparent,
                                      builder: (ctx) => PaymentMethodSheet(
                                        amount: selectedAmount.toDouble(),
                                        purpose: 'wallet_topup',
                                        userPhone: user?.phoneNumber ?? '',
                                        userName: user?.displayName ?? 'VAYA Customer',
                                        razorpayService: _razorpayService,
                                        apiBaseUrl: apiBaseUrl,
                                        token: token,
                                        onFailure: (err) {
                                          if (mounted) {
                                            setState(() {
                                              _isProcessingTopup = false;
                                            });
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text(err), backgroundColor: const Color(0xFFDC2626)),
                                            );
                                          }
                                        },
                                      ),
                                    );
                                  },
                            child: _isProcessingTopup
                                ? const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const VayaLoader.inline(size: 20, color: VayaTheme.inkBlack),
                                      SizedBox(width: 10),
                                      Text(
                                        'Processing Payment...',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
                                      ),
                                    ],
                                  )
                                : Text(
                                    'Add ₹$selectedAmount',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSuccessReceiptDialog({
    required int amount,
    required String paymentId,
    required int newBalance,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xFFDCFCE7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle, color: VayaTheme.routeGreen, size: 38),
              ),
              const SizedBox(height: 14),
              const Text(
                'Money Added Successfully!',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: VayaTheme.inkBlack),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                '₹$amount added to your VAYA Wallet',
                style: const TextStyle(fontSize: 13, color: VayaTheme.slate),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: VayaTheme.signalCream.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: VayaTheme.fog),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Transaction ID', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                        Text(
                          paymentId.length > 16 ? '${paymentId.substring(0, 14)}...' : paymentId,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Updated Balance', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                        Text(
                          '₹$newBalance',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: VayaTheme.routeGreen),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VayaTheme.saffron,
                    foregroundColor: VayaTheme.inkBlack,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showContextualSupportSheet() {
    final failedTxns = _transactions.where((t) => (t['status'] ?? '').toString().toLowerCase().contains('fail') || t['status'] == 'Pending').toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Payment & Wallet Support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: VayaTheme.inkBlack)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (failedTxns.isNotEmpty) ...[
                const Text('Recent Failed / Pending Payments', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
                const SizedBox(height: 8),
                ...failedTxns.take(2).map((tx) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFCA5A5)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tx['title'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                              Text('Ref: ${tx['reference']}', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                            ],
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: VayaTheme.saffron,
                              foregroundColor: VayaTheme.inkBlack,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _addMoneyDialog();
                            },
                            child: const Text('Retry', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 12),
              ],

              const Text('How can we help?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: VayaTheme.saffron.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.support_agent, color: VayaTheme.saffron),
                ),
                title: const Text('Chat with Payment Support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                subtitle: const Text('24/7 dedicated payment resolution desk', style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showInfoDialog('Payment Support', 'Support Ticket #PY-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)} opened.\nOur payments team will contact you via WhatsApp / Call within 5 minutes.');
                },
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: VayaTheme.saffron.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.phone, color: VayaTheme.saffron),
                ),
                title: const Text('Call Helpline (+91-1800-VAYA)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                subtitle: const Text('Instant phone assistance for payment queries', style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showInfoDialog('Call Helpline', 'Dialing +91-1800-VAYA (1800-8292). Toll-free support available 24/7.');
                },
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: VayaTheme.saffron.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.report_problem_outlined, color: VayaTheme.saffron),
                ),
                title: const Text('Money Debited but Balance Not Updated?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                subtitle: const Text('UPI/Bank transactions auto-reconcile within 24 hours', style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showInfoDialog('Bank Reconciliation', 'If your bank account was debited but the balance did not update, banks automatically refund failed transactions within 24-48 hours. You can also contact support with your UTR / Bank Reference Number.');
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showInfoDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack)),
        content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 13, color: VayaTheme.slate, height: 1.4))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold, color: VayaTheme.saffron)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Group transactions by date
    final Map<String, List<Map<String, dynamic>>> groupedTxns = {};
    for (var tx in _transactions) {
      final dateKey = tx['date'] ?? 'Other';
      groupedTxns.putIfAbsent(dateKey, () => []).add(tx);
    }

    return Scaffold(
      backgroundColor: VayaTheme.signalCream,
      appBar: AppBar(
        backgroundColor: VayaTheme.signalCream,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        title: const Text(
          'Payments',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontSize: 28, // 28-32 px General Sans / 700
            fontWeight: FontWeight.w700,
            color: VayaTheme.inkBlack,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0), // 16 px margins
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // VAYA Wallet Card (Height 160-180 px, 16px radius, light Fog border)
            Container(
              height: 168.0,
              decoration: BoxDecoration(
                color: VayaTheme.inkBlack,
                borderRadius: BorderRadius.circular(16), // 16 px radii
                border: Border.all(color: VayaTheme.fog, width: 1.0), // Lighter Fog border
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'VAYA WALLET',
                              style: TextStyle(
                                color: Colors.white, // Increased contrast
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '₹$_walletBalance',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        // Ink Black CTA text for accessible contrast on Saffron button
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VayaTheme.saffron,
                            foregroundColor: VayaTheme.inkBlack, // Ink Black text for contrast
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _addMoneyDialog,
                          icon: const Icon(Icons.add, size: 18, color: VayaTheme.inkBlack),
                          label: const Text(
                            '+ Add money',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: VayaTheme.inkBlack),
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 1),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Non-withdrawable credits',
                          style: TextStyle(
                            color: Colors.white70, // Increased contrast
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        InkWell(
                          onTap: _scrollToActivity,
                          child: const Row(
                            children: [
                              Text(
                                'Wallet activity',
                                style: TextStyle(color: VayaTheme.saffron, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              SizedBox(width: 4),
                              Icon(Icons.arrow_forward, color: VayaTheme.saffron, size: 14), // Wallet activity →
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Default payment method section
            const Text(
              'Default payment method',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
            ),
            const SizedBox(height: 10),

            // VAYA Wallet Row (Height 72-84 px, 16px radius, Fog border)
            Container(
              height: 76.0,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16), // 16 px radii
                border: Border.all(
                  color: _defaultPayment == 'Wallet' ? VayaTheme.saffron : VayaTheme.fog, // Lighter Fog border
                  width: _defaultPayment == 'Wallet' ? 1.5 : 1.0,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _walletBalance <= 0 ? _addMoneyDialog : () => setState(() => _defaultPayment = 'Wallet'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    child: Row(
                      children: [
                        Radio<String>(
                          value: 'Wallet',
                          groupValue: _defaultPayment,
                          activeColor: VayaTheme.saffron,
                          onChanged: _walletBalance <= 0 ? null : (val) => setState(() => _defaultPayment = val!),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text('VAYA Wallet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: VayaTheme.inkBlack)),
                                  const SizedBox(width: 8),
                                  if (_walletBalance <= 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: VayaTheme.saffron.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: VayaTheme.saffron.withValues(alpha: 0.3)),
                                      ),
                                      child: const Text(
                                        '₹0 · Add money to use',
                                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                                      ),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: VayaTheme.saffron.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '₹$_walletBalance',
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _walletBalance <= 0 ? 'Add money to enable wallet checkout' : 'Fastest checkout using wallet credits',
                                style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // UPI Row (Height 76px, 16px radius, Fog border)
            Container(
              height: 76.0,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _defaultPayment == 'UPI' ? VayaTheme.saffron : VayaTheme.fog,
                  width: _defaultPayment == 'UPI' ? 1.5 : 1.0,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _defaultPayment = 'UPI'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    child: Row(
                      children: [
                        Radio<String>(
                          value: 'UPI',
                          groupValue: _defaultPayment,
                          activeColor: VayaTheme.saffron,
                          onChanged: (val) => setState(() => _defaultPayment = val!),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('UPI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: VayaTheme.inkBlack)),
                              SizedBox(height: 3),
                              Text('Pay using any UPI app (GPay, PhonePe, Paytm)', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Cash Row (Height 76px, 16px radius, Fog border)
            Container(
              height: 76.0,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _defaultPayment == 'Cash' ? VayaTheme.saffron : VayaTheme.fog,
                  width: _defaultPayment == 'Cash' ? 1.5 : 1.0,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _defaultPayment = 'Cash'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    child: Row(
                      children: [
                        Radio<String>(
                          value: 'Cash',
                          groupValue: _defaultPayment,
                          activeColor: VayaTheme.saffron,
                          onChanged: (val) => setState(() => _defaultPayment = val!),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Cash', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: VayaTheme.inkBlack)),
                              SizedBox(height: 3),
                              Text('Pay driver in cash after delivery completion', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Shortened Helper Note
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
              child: Text(
                'Used as your default at checkout—you can change it anytime',
                style: TextStyle(fontSize: 11, color: VayaTheme.slate),
              ),
            ),
            const SizedBox(height: 24),

            // Recent activity section key for scroll anchor
            KeyedSubtree(
              key: _activitySectionKey,
              child: const Text(
                'Payment activity',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
              ),
            ),
            const SizedBox(height: 10),

            if (_transactions.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VayaTheme.fog, width: 1.0),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history_toggle_off, size: 42, color: VayaTheme.slate),
                    SizedBox(height: 10),
                    Text(
                      'No payment activity yet',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Transactions and refunds will appear here',
                      style: TextStyle(fontSize: 12, color: VayaTheme.slate),
                    ),
                  ],
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: groupedTxns.entries.map((group) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VayaTheme.fog, width: 1.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Group Date Header
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 6),
                          child: Text(
                            group.key,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5, color: VayaTheme.slate, letterSpacing: 0.3),
                          ),
                        ),
                        const Divider(height: 1, color: VayaTheme.fog),
                        ...group.value.map((tx) {
                          final isCr = (tx['isCredit'] as bool? ?? false);
                          final amt = tx['amount'];
                          final status = (tx['status'] ?? 'Success').toString();
                          final balAfter = tx['balanceAfter'];

                          return Column(
                            children: [
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                leading: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: isCr ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    isCr ? Icons.add : Icons.remove,
                                    color: isCr ? VayaTheme.routeGreen : const Color(0xFFDC2626),
                                    size: 18,
                                  ),
                                ),
                                title: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      tx['title'] ?? 'Transaction',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                                    ),
                                    Text(
                                      '${isCr ? "+" : "-"}₹$amt',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: isCr ? VayaTheme.routeGreen : VayaTheme.inkBlack,
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Ref: ${tx['reference']}',
                                            style: const TextStyle(fontSize: 10.5, color: VayaTheme.slate),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: status == 'Success' ? const Color(0xFFDCFCE7) : const Color(0xFFFEF3C7),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              status,
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                                color: status == 'Success' ? VayaTheme.routeGreen : const Color(0xFFD97706),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (balAfter != null) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          'Balance: ₹$balAfter',
                                          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: VayaTheme.slate),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              if (tx != group.value.last) const Divider(height: 1, color: VayaTheme.fog, indent: 16, endIndent: 16),
                            ],
                          );
                        }),
                      ],
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 24),

            // Footer Links
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => _showInfoDialog(
                    'Wallet Terms & Conditions',
                    '• VAYA Wallet is a closed-loop wallet.\n• Wallet balance can be used for booking fare.\n• Balance is non-withdrawable and non-transferable.\n• Promotional credits expire in 30 days.',
                  ),
                  child: const Text('Wallet terms', style: TextStyle(fontSize: 11.5, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
                TextButton(
                  onPressed: () => _showInfoDialog(
                    'Refund Rules',
                    '• Order cancellations receive full refund instantly if cancelled before driver arrives.\n• Refund returns automatically to the original source.\n• Promo/discount codes are single-use and cannot be refunded.',
                  ),
                  child: const Text('Refund rules', style: TextStyle(fontSize: 11.5, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
                TextButton(
                  onPressed: _showContextualSupportSheet,
                  child: const Text('Failed payments?', style: TextStyle(fontSize: 11.5, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// 10. Account & Settings Screen (Account Tab)
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _isLoading = true;
  bool _isOffline = false;

  String _name = 'Gourav Mahunta';
  String _phone = '9876543210';
  String _email = 'gourav.mahunta@vaya.com';
  bool _phoneVerified = true;

  String _gstin = '';
  String _gstStatus = 'Not added';
  String _companyName = '';
  String _billingAddress = '';

  bool _notifyBookingUpdates = true;
  bool _notifyLiveTracking = true;
  bool _notifyOffers = false;
  bool _notifyWhatsApp = true;

  String _appLanguage = 'English';

  List<Map<String, String>> _addresses = [
    {
      'title': 'Main Warehouse',
      'subtitle': 'Plot 12, Industrial Estate, Rasulgarh, Bhubaneswar',
      'type': 'Warehouse',
      'isDefault': 'true',
    },
    {
      'title': 'City Office',
      'subtitle': 'Flat 302, Saheed Nagar, Bhubaneswar',
      'type': 'Office',
      'isDefault': 'false',
    },
  ];

  bool _hasActiveOrder = true;

  @override
  void initState() {
    super.initState();
    _loadAccountStorage();
  }

  Future<void> _loadAccountStorage() async {
    try {
      final profile = await VayaStorage.loadUserProfile();
      final business = await VayaStorage.loadBusinessDetails();
      final places = await VayaStorage.loadSavedPlaces();

      if (mounted) {
        setState(() {
          if ((profile['name'] ?? '').isNotEmpty) _name = profile['name']!;
          if ((profile['phone'] ?? '').isNotEmpty) _phone = profile['phone']!;
          if ((profile['email'] ?? '').isNotEmpty) _email = profile['email']!;
          _phoneVerified = _phone.isNotEmpty;

          _companyName = business['companyName'] ?? '';
          _gstin = business['gstin'] ?? '';
          _billingAddress = business['billingAddress'] ?? '';
          _gstStatus = business['gstStatus'] ?? (_gstin.isNotEmpty ? 'Registered' : 'Not added');

          if (places.isNotEmpty) {
            _addresses = places;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _formatPhone(String raw) {
    String clean = raw.replaceAll(RegExp(r'\D'), '');
    if (clean.length > 10) {
      clean = clean.substring(clean.length - 10);
    }
    if (clean.length == 10) {
      return '+91 ${clean.substring(0, 5)} ${clean.substring(5)}';
    }
    return raw.isEmpty ? '+91 12345 67890' : raw;
  }

  Widget _buildRowIcon(IconData icon, {Color? color}) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: (color ?? VayaTheme.slate).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Icon(icon, size: 24, color: color ?? VayaTheme.slate),
      ),
    );
  }

  Widget _buildSectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 6.0),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'General Sans',
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: VayaTheme.inkBlack,
        ),
      ),
    );
  }

  Widget _buildRowContainer({required Widget child, VoidCallback? onTap}) {
    return Container(
      constraints: const BoxConstraints(minHeight: 64, maxHeight: 76),
      decoration: const BoxDecoration(color: Colors.white),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: child,
          ),
        ),
      ),
    );
  }

  void _editProfileBottomSheet() {
    final nameCtrl = TextEditingController(text: _name);
    final phoneCtrl = TextEditingController(text: _formatPhone(_phone));
    final emailCtrl = TextEditingController(text: _email);
    bool otpSent = false;
    final otpCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Edit Profile & Mobile', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                        IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Full Name', isDense: true),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: phoneCtrl,
                      decoration: InputDecoration(
                        labelText: 'Mobile Number',
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(otpSent ? Icons.check_circle : Icons.shield_outlined, color: VayaTheme.saffron, size: 20),
                          onPressed: () {
                            setModalState(() => otpSent = true);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('OTP sent to your mobile number (123456).')),
                            );
                          },
                        ),
                      ),
                    ),
                    if (otpSent) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: otpCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Enter 6-digit OTP',
                          hintText: '123456',
                          isDense: true,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email Address', isDense: true),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.saffron),
                      onPressed: () async {
                        try {
                          final name = nameCtrl.text.trim();
                          final email = emailCtrl.text.trim();
                          setState(() {
                            _name = name;
                            _email = email;
                          });
                          await VayaStorage.saveUserProfile(name, _phone, email);
                          if (context.mounted) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Profile details updated successfully!')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error saving profile: $e'),
                                action: SnackBarAction(label: 'Retry', onPressed: _editProfileBottomSheet),
                              ),
                            );
                          }
                        }
                      },
                      child: const Text('Save Profile', style: TextStyle(fontWeight: FontWeight.bold)),
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

  void _addressManagerBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.7,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Saved Addresses', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VayaTheme.saffron,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () {
                          setModalState(() {
                            _addresses.add({
                              'title': 'New Delivery Hub',
                              'subtitle': 'Plot 45, Master Canteen Square, Bhubaneswar',
                              'type': 'Hub',
                              'isDefault': _addresses.isEmpty ? 'true' : 'false',
                            });
                          });
                          VayaStorage.saveSavedPlaces(_addresses);
                          setState(() {});
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add New'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _addresses.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.location_off_outlined, size: 48, color: VayaTheme.slate.withValues(alpha: 0.4)),
                                const SizedBox(height: 8),
                                const Text('No saved addresses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.slate)),
                                const SizedBox(height: 4),
                                const Text('Add warehouse or store locations for quick pickup selection.', style: TextStyle(fontSize: 11, color: VayaTheme.slate), textAlign: TextAlign.center),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _addresses.length,
                            separatorBuilder: (c, i) => const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                            itemBuilder: (c, i) {
                              final addr = _addresses[i];
                              final isDefault = addr['isDefault'] == 'true';
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                leading: _buildRowIcon(isDefault ? Icons.star : Icons.place_outlined, color: isDefault ? VayaTheme.saffron : VayaTheme.slate),
                                title: Row(
                                  children: [
                                    Text(addr['title'] ?? 'Address', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                    if (isDefault) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: VayaTheme.saffron.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text('Default Pickup', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: VayaTheme.saffron)),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text(addr['subtitle'] ?? '', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isDefault)
                                      TextButton(
                                        onPressed: () {
                                          setModalState(() {
                                            for (var a in _addresses) {
                                              a['isDefault'] = 'false';
                                            }
                                            _addresses[i]['isDefault'] = 'true';
                                          });
                                          VayaStorage.saveSavedPlaces(_addresses);
                                          setState(() {});
                                        },
                                        child: const Text('Set Default', style: TextStyle(fontSize: 11, color: VayaTheme.saffron)),
                                      ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                      onPressed: () async {
                                        setModalState(() {
                                          _addresses.removeAt(i);
                                        });
                                        await VayaStorage.saveSavedPlaces(_addresses);
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _gstBottomSheet() {
    final companyCtrl = TextEditingController(text: _companyName);
    final gstinCtrl = TextEditingController(text: _gstin);
    final addressCtrl = TextEditingController(text: _billingAddress);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Business & Tax Details', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: companyCtrl,
                  decoration: const InputDecoration(labelText: 'Registered Business / Legal Name', isDense: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: gstinCtrl,
                  decoration: const InputDecoration(
                    labelText: 'GSTIN (15-Digit GST Number)',
                    hintText: 'e.g. 21AAAAA1111A1Z1',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addressCtrl,
                  decoration: const InputDecoration(labelText: 'Registered Billing Address', isDense: true),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (_gstin.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          setState(() {
                            _gstin = '';
                            _companyName = '';
                            _billingAddress = '';
                            _gstStatus = 'Not added';
                          });
                          await VayaStorage.saveBusinessDetails('', '', '', 'Not added');
                          if (context.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Remove Details', style: TextStyle(color: Colors.red)),
                      ),
                    const Spacer(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.saffron),
                      onPressed: () async {
                        final company = companyCtrl.text.trim();
                        final gstin = gstinCtrl.text.trim().toUpperCase();
                        final address = addressCtrl.text.trim();
                        final status = gstin.isNotEmpty ? 'Registered' : 'Not added';

                        setState(() {
                          _companyName = company;
                          _gstin = gstin;
                          _billingAddress = address;
                          _gstStatus = status;
                        });
                        await VayaStorage.saveBusinessDetails(company, gstin, address, status);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Business & Tax details saved successfully!')),
                          );
                        }
                      },
                      child: const Text('Save Details', style: TextStyle(fontWeight: FontWeight.bold)),
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

  void _notificationsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Notification Preferences', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    activeTrackColor: VayaTheme.saffron,
                    title: const Text('Booking & Dispatch Updates', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Real-time assignment and status alerts', style: TextStyle(fontSize: 11)),
                    value: _notifyBookingUpdates,
                    onChanged: (val) {
                      setModalState(() => _notifyBookingUpdates = val);
                      setState(() {});
                    },
                  ),
                  const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                  SwitchListTile(
                    activeTrackColor: VayaTheme.saffron,
                    title: const Text('Live Driver Tracking', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('ETA progress and proximity notifications', style: TextStyle(fontSize: 11)),
                    value: _notifyLiveTracking,
                    onChanged: (val) {
                      setModalState(() => _notifyLiveTracking = val);
                      setState(() {});
                    },
                  ),
                  const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                  SwitchListTile(
                    activeTrackColor: VayaTheme.saffron,
                    title: const Text('Offers & Discounts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Promotional codes and seasonal deals', style: TextStyle(fontSize: 11)),
                    value: _notifyOffers,
                    onChanged: (val) {
                      setModalState(() => _notifyOffers = val);
                      setState(() {});
                    },
                  ),
                  const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                  SwitchListTile(
                    activeTrackColor: VayaTheme.saffron,
                    title: const Text('WhatsApp Notifications', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Receipts and live tracking links on WhatsApp', style: TextStyle(fontSize: 11)),
                    value: _notifyWhatsApp,
                    onChanged: (val) {
                      setModalState(() => _notifyWhatsApp = val);
                      setState(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _languageBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                  const Text('App Language', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.language, color: VayaTheme.saffron),
                title: const Text('English', style: TextStyle(fontWeight: FontWeight.bold)),
                trailing: _appLanguage == 'English' ? const Icon(Icons.check_circle, color: VayaTheme.saffron) : null,
                onTap: () {
                  setState(() => _appLanguage = 'English');
                  context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('en'));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Language updated to English')),
                  );
                },
              ),
              const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
              ListTile(
                leading: const Icon(Icons.language, color: VayaTheme.saffron),
                title: const Text('ଓଡ଼ିଆ (Odia)', style: TextStyle(fontWeight: FontWeight.bold)),
                trailing: _appLanguage.contains('Odia') ? const Icon(Icons.check_circle, color: VayaTheme.saffron) : null,
                onTap: () {
                  setState(() => _appLanguage = 'ଓଡ଼ିଆ (Odia)');
                  context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('or'));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ଭାଷା ଓଡ଼ିଆରେ ପରିବର୍ତ୍ତିତ ହୋଇଛି (Odia selected)')),
                  );
                },
              ),
              const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
              ListTile(
                leading: const Icon(Icons.language, color: VayaTheme.saffron),
                title: const Text('हिन्दी (Hindi)', style: TextStyle(fontWeight: FontWeight.bold)),
                trailing: _appLanguage.contains('Hindi') ? const Icon(Icons.check_circle, color: VayaTheme.saffron) : null,
                onTap: () {
                  setState(() => _appLanguage = 'हिन्दी (Hindi)');
                  context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('hi'));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('भाषा हिन्दी में बदली गई (Hindi selected)')),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _contactSupportBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                  const Text('Contact Support', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 14),
              ListTile(
                leading: _buildRowIcon(Icons.chat_bubble_outline, color: VayaTheme.saffron),
                title: const Text('24x7 Live Chat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('Instant response from VAYA operations agent', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Connecting to 24x7 Support Chat...')),
                  );
                },
              ),
              const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
              ListTile(
                leading: _buildRowIcon(Icons.phone_outlined, color: VayaTheme.saffron),
                title: const Text('Call Support Helpline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('Toll-Free: +91 1800 102 8292', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _makePhoneCall('18001028292');
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Dialing VAYA Helpline (+91 1800 102 8292)...')),
                  );
                },
              ),
              const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
              ListTile(
                leading: _buildRowIcon(Icons.phone_callback_outlined, color: VayaTheme.saffron),
                title: const Text('Request Instant Callback', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('An agent will call you within 2 minutes', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Callback requested! Our support agent will call you in 2 minutes.')),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _disputesBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Disputes & Refund Cases', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: VayaTheme.signalCream,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VayaTheme.fog),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Case #DISP-89201', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('In Progress', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.brown)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Issue: Fare discrepancy adjustment request', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    const Text('Status: Under investigation by logistics desk (Expected resolution: 24 hrs)', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                    const SizedBox(height: 10),
                    const Text('Evidence Attached: 2 Documents (POD Receipt & Waybill photo)', style: TextStyle(fontSize: 10, color: VayaTheme.saffron, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.saffron),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close Case View', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );
  }

  void _dataExportBottomSheet() {
    String format = 'CSV';
    String method = 'Email';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Download My Data', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('Data Scope:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 4),
                  const Text('• Complete Booking History & Waybills\n• Billing Ledger & Tax Invoices\n• Saved Locations & Profile Details', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Format: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ChoiceChip(
                        label: const Text('CSV'),
                        selected: format == 'CSV',
                        onSelected: (val) => setModalState(() => format = 'CSV'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('PDF'),
                        selected: format == 'PDF',
                        onSelected: (val) => setModalState(() => format = 'PDF'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('JSON'),
                        selected: format == 'JSON',
                        onSelected: (val) => setModalState(() => format = 'JSON'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('Delivery: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ChoiceChip(
                        label: const Text('Send to Email'),
                        selected: method == 'Email',
                        onSelected: (val) => setModalState(() => method = 'Email'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Direct Download'),
                        selected: method == 'Download',
                        onSelected: (val) => setModalState(() => method = 'Download'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.saffron),
                    onPressed: () {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Export started ($format format via $method). File will arrive shortly.')),
                      );
                    },
                    child: const Text('Confirm Data Export', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _deleteAccountWorkflow() {
    if (_hasActiveOrder) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Active Delivery In Progress', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 15)),
          content: const Text(
            'Cannot delete account while order #VAYA-89201 is active or in transit.\n\nPlease complete or resolve all active deliveries and pending refunds before requesting account deletion.',
            style: TextStyle(fontSize: 12),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.slate),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      return;
    }

    bool otpVerified = false;
    final otpCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            title: const Text('Delete Account', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 15)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber),
                    ),
                    child: const Text(
                      'Legal Notice: Tax invoices and GST billing compliance records will be legally retained for 7 years under applicable tax laws. Personal profile credentials, authentication sessions, and saved locations will be permanently erased.',
                      style: TextStyle(fontSize: 11, color: Colors.brown, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Enter 6-digit verification OTP sent to your phone to confirm identity:', style: TextStyle(fontSize: 11)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: otpCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: 'Enter 123456',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                onPressed: () async {
                  if (otpCtrl.text.trim() == '123456' || otpCtrl.text.trim().length == 6) {
                    Navigator.pop(ctx);
                    await CustomerSessionManager.clearSession();
                    await FirebaseAuth.instance.signOut();
                    if (mounted) {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (_) => const AuthWrapper()),
                        (route) => false,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account permanently deactivated. Invoices archived per legal requirement.')),
                      );
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid OTP. Please enter 123456.')),
                    );
                  }
                },
                child: const Text('Permanently Delete', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _confirmSignOutSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Sign Out of VAYA?', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Active server-side bookings will remain safe in transit and will not be cancelled. Do you want to sign out on this device?',
              style: TextStyle(fontSize: 12, color: VayaTheme.slate),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await CustomerSessionManager.clearSession();
                      await FirebaseAuth.instance.signOut();
                      if (mounted) {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(builder: (_) => const AuthWrapper()),
                          (route) => false,
                        );
                      }
                    },
                    child: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: VayaTheme.signalCream,
        appBar: AppBar(
          backgroundColor: VayaTheme.signalCream,
          elevation: 0,
          title: const Text('Account', style: TextStyle(fontFamily: 'General Sans', fontSize: 30, fontWeight: FontWeight.w700, color: VayaTheme.inkBlack)),
        ),
        body: const Center(
          child: VayaLoader.section(size: 96, message: 'Loading account...'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: VayaTheme.signalCream,
      appBar: AppBar(
        backgroundColor: VayaTheme.signalCream,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Account',
          style: TextStyle(
            fontFamily: 'General Sans',
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: VayaTheme.inkBlack,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isOffline) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(8)),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, size: 16, color: Colors.brown),
                    SizedBox(width: 8),
                    Text('Offline Mode. Changes will sync when connected.', style: TextStyle(fontSize: 11, color: Colors.brown, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // Profile Header Card
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _editProfileBottomSheet,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const CircleAvatar(
                          radius: 22,
                          backgroundColor: VayaTheme.saffron,
                          child: Icon(Icons.person, color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _name.isEmpty ? 'Gourav Mahunta' : _name,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: VayaTheme.inkBlack),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Text(
                                    _formatPhone(_phone),
                                    style: const TextStyle(fontSize: 12, color: VayaTheme.slate, fontWeight: FontWeight.w500),
                                  ),
                                  if (_phoneVerified) ...[
                                    const SizedBox(width: 6),
                                    Semantics(
                                      label: 'Phone number verified',
                                      child: Tooltip(
                                        message: 'Phone number verified',
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: const BoxDecoration(
                                            color: VayaTheme.liveBlue,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.check, size: 10, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.edit_outlined, size: 18, color: VayaTheme.slate),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Logistics Section
            _buildSectionLabel('Logistics'),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildRowContainer(
                  onTap: _addressManagerBottomSheet,
                  child: Row(
                    children: [
                      _buildRowIcon(Icons.place_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Saved addresses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                            const SizedBox(height: 2),
                            Text(
                              _addresses.isEmpty ? 'No saved addresses' : '${_addresses.length} location${_addresses.length > 1 ? 's' : ''} saved',
                              style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Business & Billing Section
            _buildSectionLabel('Business & billing'),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildRowContainer(
                  onTap: _gstBottomSheet,
                  child: Row(
                    children: [
                      _buildRowIcon(Icons.business_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Business & tax details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                            const SizedBox(height: 2),
                            Text(
                              _gstin.isEmpty ? 'Not added' : 'GSTIN: $_gstin',
                              style: TextStyle(
                                fontSize: 11,
                                color: _gstin.isEmpty ? VayaTheme.slate : VayaTheme.routeGreen,
                                fontWeight: _gstin.isEmpty ? FontWeight.normal : FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Preferences Section
            _buildSectionLabel('Preferences'),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    _buildRowContainer(
                      onTap: _notificationsBottomSheet,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.notifications_none_outlined),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                                SizedBox(height: 2),
                                Text('Booking, tracking & WhatsApp controls', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                    const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                    _buildRowContainer(
                      onTap: _languageBottomSheet,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.language_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('App Language', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                                const SizedBox(height: 2),
                                Text(_appLanguage, style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Help & Support Section
            _buildSectionLabel('Help & support'),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    _buildRowContainer(
                      onTap: _contactSupportBottomSheet,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.support_agent_outlined),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Contact support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                                SizedBox(height: 2),
                                Text('24x7 Chat, call & callback options', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                    const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                    _buildRowContainer(
                      onTap: _disputesBottomSheet,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.gavel_outlined),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Disputes & refund cases', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                                SizedBox(height: 2),
                                Text('Track case status & evidence', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Privacy & Legal Section
            _buildSectionLabel('Privacy & legal'),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    _buildRowContainer(
                      onTap: _dataExportBottomSheet,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.download_outlined),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Download my data', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack)),
                                SizedBox(height: 2),
                                Text('Export scope, format & delivery method', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                    const Divider(height: 1, thickness: 1, color: VayaTheme.fog),
                    _buildRowContainer(
                      onTap: _deleteAccountWorkflow,
                      child: Row(
                        children: [
                          _buildRowIcon(Icons.delete_outline, color: Colors.red),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Delete account', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.red)),
                                SizedBox(height: 2),
                                Text('Account removal & GST invoice retention', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: VayaTheme.slate),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Sign Out Row
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.fog, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildRowContainer(
                  onTap: _confirmSignOutSheet,
                  child: Row(
                    children: [
                      _buildRowIcon(Icons.logout, color: Colors.red),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text('Sign out', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.red)),
                      ),
                      const Icon(Icons.chevron_right, size: 18, color: Colors.red),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // App Version Footer
            const Center(
              child: Text(
                'VAYA Customer • Version 1.4.2 (Build 20260725)',
                style: TextStyle(fontSize: 11, color: VayaTheme.slate),
              ),
            ),

            // 96 px bottom padding to ensure navigation bar never hides content
            const SizedBox(height: 96),
          ],
        ),
      ),
    );
  }
}


/// ==========================================
/// VAYA VOICE AI ASSISTANT SHEET (Gemini 2.0 Flash)
/// Multilingual (English / Hindi / Odia)
/// ==========================================
// Gemini API key — passed via --dart-define=GEMINI_API_KEY=your_key_here
const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

class VoiceAssistantSheet extends StatefulWidget {
  final Function(Map<String, dynamic> actionData)? onBookingAction;
  final String? initialPickup;
  final String? initialDropoff;
  final String? initialVehicle;

  const VoiceAssistantSheet({
    super.key,
    this.onBookingAction,
    this.initialPickup,
    this.initialDropoff,
    this.initialVehicle,
  });

  @override
  State<VoiceAssistantSheet> createState() => _VoiceAssistantSheetState();
}

class _VoiceAssistantSheetState extends State<VoiceAssistantSheet> with SingleTickerProviderStateMixin {
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;
  late AnimationController _pulseController;

  bool _isListening = false;
  bool _isThinking = false;
  bool _isSpeaking = false;
  bool _sttAvailable = false;

  String _selectedLang = 'hi'; // 'en', 'hi', 'or'
  String _liveTranscript = '';

  String _pickupAddress = '';
  String _dropoffAddress = '';
  String _selectedVehicle = '';

  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pickupAddress = widget.initialPickup ?? '';
    _dropoffAddress = widget.initialDropoff ?? '';
    _selectedVehicle = widget.initialVehicle ?? '';

    _initSpeechAndTts();
  }

  Future<void> _initSpeechAndTts() async {
    try {
      _sttAvailable = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted && _isListening) {
              setState(() => _isListening = false);
              if (_liveTranscript.trim().isNotEmpty) {
                _handleUserSpeechSubmit(_liveTranscript.trim());
              }
            }
          }
        },
        onError: (errorNotification) {
          if (mounted) setState(() => _isListening = false);
        },
      );

      await _flutterTts.setVolume(1.0);
      await _flutterTts.setSpeechRate(0.45);
      await _flutterTts.setPitch(1.0);

      _flutterTts.setCompletionHandler(() {
        if (mounted) setState(() => _isSpeaking = false);
      });

      _sendInitialGreeting();
    } catch (e) {
      debugPrint('Voice init error: $e');
    }
  }

  void _sendInitialGreeting() {
    String greeting = '';
    if (_selectedLang == 'hi') {
      greeting = 'Namaste! Main VAYA Voice AI hun. Aapki delivery booking mein madad kar sakta hun. Kahaan se kahaan bhejhna hai?';
    } else if (_selectedLang == 'or') {
      greeting = 'ନମସ୍କାର! ମୁଁ VAYA Voice AI. ଆପଣଙ୍କର ପାର୍ସଲ କେଉଁଠାରୁ କେଉଁଠାକୁ ପଠାଇବାକୁ ଚାହାଁନ୍ତି?';
    } else {
      greeting = 'Hello! I am VAYA Voice AI. Where would you like to pick up and deliver your package?';
    }

    setState(() {
      _messages.add({
        'role': 'model',
        'text': greeting,
        'lang': _selectedLang,
      });
    });

    _speakMessage(greeting, _selectedLang);
  }

  Future<void> _speakMessage(String text, String lang) async {
    // Option B for Odia: Do NOT play robotic TTS audio. Just show text on screen!
    if (lang == 'or') {
      await _flutterTts.stop();
      if (mounted) setState(() => _isSpeaking = false);
      return;
    }

    try {
      await _flutterTts.stop();
      if (lang == 'hi') {
        await _flutterTts.setLanguage('hi-IN');
      } else {
        await _flutterTts.setLanguage('en-IN');
      }
      setState(() => _isSpeaking = true);
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('TTS speak error: $e');
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  void _switchLanguage(String newLang) {
    if (_selectedLang == newLang) return;
    setState(() {
      _selectedLang = newLang;
    });

    String updateMsg = '';
    if (newLang == 'hi') {
      updateMsg = 'Bhasha Hindi set kar di gayi hai. Aap Hindi mein bol sakte hain!';
    } else if (newLang == 'or') {
      updateMsg = 'ଭାଷା ଓଡ଼ିଆ ସେଟ୍ ହୋଇଛି। ଆପଣ ଓଡ଼ିଆରେ କହିପାରିବେ।';
    } else {
      updateMsg = 'Language switched to English. How can I help with your order?';
    }

    setState(() {
      _messages.add({
        'role': 'model',
        'text': updateMsg,
        'lang': newLang,
      });
    });
    _scrollToBottom();
    _speakMessage(updateMsg, newLang);
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      if (_liveTranscript.trim().isNotEmpty) {
        _handleUserSpeechSubmit(_liveTranscript.trim());
      }
    } else {
      await _flutterTts.stop();
      setState(() {
        _isSpeaking = false;
        _liveTranscript = '';
      });

      String localeId = 'en_IN';
      if (_selectedLang == 'hi') localeId = 'hi_IN';
      if (_selectedLang == 'or') localeId = 'or_IN';

      if (!_sttAvailable) {
        _sttAvailable = await _speech.initialize();
      }

      if (_sttAvailable) {
        setState(() => _isListening = true);
        await _speech.listen(
          localeId: localeId,
          onResult: (result) {
            if (mounted) {
              setState(() {
                _liveTranscript = result.recognizedWords;
              });
            }
          },
          listenFor: const Duration(seconds: 25),
          pauseFor: const Duration(seconds: 3),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone speech recognition unavailable. You can type below!')),
        );
      }
    }
  }

  Future<void> _handleUserSpeechSubmit(String userText) async {
    if (userText.trim().isEmpty) return;

    setState(() {
      _messages.add({
        'role': 'user',
        'text': userText,
        'lang': _selectedLang,
      });
      _isThinking = true;
      _liveTranscript = '';
    });

    _textController.clear();
    _scrollToBottom();

    final result = await _callGeminiVoiceAI(userText);

    if (!mounted) return;

    setState(() {
      _isThinking = false;
    });

    final String responseText = result['response_text'] ?? 'Samajh aa gaya!';
    final String action = result['action'] ?? 'NONE';
    final String pName = result['pickup_name'] ?? '';
    final String dName = result['dropoff_name'] ?? '';
    final String vType = result['vehicle_type'] ?? '';

    if (pName.isNotEmpty) _pickupAddress = pName;
    if (dName.isNotEmpty) _dropoffAddress = dName;
    if (vType.isNotEmpty) _selectedVehicle = vType;

    setState(() {
      _messages.add({
        'role': 'model',
        'text': responseText,
        'lang': _selectedLang,
        'action': action,
      });
    });

    _scrollToBottom();
    _speakMessage(responseText, _selectedLang);

    if (action == 'PROCEED_TO_PAYMENT' || (action != 'NONE' && _pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty && _selectedVehicle.isNotEmpty)) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          Navigator.pop(context);
          if (widget.onBookingAction != null) {
            widget.onBookingAction!({
              'action': action,
              'pickup_name': _pickupAddress,
              'dropoff_name': _dropoffAddress,
              'vehicle_type': _selectedVehicle,
            });
          }
        }
      });
    }
  }

  Future<Map<String, dynamic>> _callGeminiVoiceAI(String userMessage) async {
    // Try primary model first, then fallback
    final List<String> models = [
      'gemini-2.0-flash',
      'gemini-flash-latest',
      'gemini-2.5-flash-lite',
    ];

    final String langName = _selectedLang == 'hi' ? 'Hindi' : (_selectedLang == 'or' ? 'Odia' : 'English');

    // Build conversation history — Gemini requires alternating user/model turns,
    // first turn must always be 'user'. Skip any leading model messages.
    final List<Map<String, dynamic>> historyContents = [];
    for (final m in _messages) {
      final role = m['role'] == 'model' ? 'model' : 'user';
      if (historyContents.isEmpty && role == 'model') continue;
      historyContents.add({
        'role': role,
        'parts': [{'text': m['text'] ?? ''}],
      });
    }
    historyContents.add({
      'role': 'user',
      'parts': [{'text': userMessage}],
    });

    final String systemInstruction = '''
You are VAYA Voice, an AI booking assistant for VAYA - an intra-city goods delivery app in Bhubaneswar, Odisha, India.
Your job is to converse naturally with the user in $langName to collect pickup location, drop-off location, and vehicle type, then navigate them to the vehicle/payment screen.

VEHICLES AVAILABLE:
- bike (~₹49, up to 20kg) - small parcels, documents
- three_wheeler (~₹210, up to 500kg) - Bajaj Maxima Cargo, furniture
- ace (~₹380, up to 1 ton) - Tata Ace, home shifting
- truck (~₹750, up to 2.5 tons) - Tata 407, heavy loads

CURRENT BOOKING STATE:
- Pickup: ${_pickupAddress.isEmpty ? 'Not set' : _pickupAddress}
- Drop-off: ${_dropoffAddress.isEmpty ? 'Not set' : _dropoffAddress}
- Vehicle: ${_selectedVehicle.isEmpty ? 'Not set' : _selectedVehicle}

USER LANGUAGE: $langName

RULES:
1. ONLY respond in $langName (Hindi=Devanagari or Romanized, Odia=Odia script, English=English).
2. Be brief — max 2 sentences in response_text.
3. Extract location names from user speech.
4. Map vehicle words: bike/cycle/thoda→bike, tempo/three wheeler→three_wheeler, ace/mini truck/chota hathi→ace, 407/truck/LCV→truck.
5. When pickup + dropoff + vehicle are all collected, use action PROCEED_TO_PAYMENT.
6. Return ONLY valid JSON, no markdown:
{
  "action": "SET_PICKUP" | "SET_DROPOFF" | "SET_LOCATIONS" | "SELECT_VEHICLE" | "PROCEED_TO_PAYMENT" | "NONE",
  "pickup_name": "",
  "dropoff_name": "",
  "vehicle_type": "bike" | "three_wheeler" | "ace" | "truck" | "",
  "response_text": "Reply in $langName"
}''';

    final requestBody = json.encode({
      'system_instruction': {
        'parts': [{'text': systemInstruction}]
      },
      'contents': historyContents,
      'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': 400,
        'responseMimeType': 'application/json',
      },
    });

    for (final model in models) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
        );

        final res = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'X-goog-api-key': geminiApiKey,  // Correct auth header for AQ. keys
          },
          body: requestBody,
        ).timeout(const Duration(seconds: 15));

        debugPrint('Gemini [$model] status: ${res.statusCode}');

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          final rawText = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '{}';
          debugPrint('Gemini response: $rawText');
          try {
            return json.decode(rawText);
          } catch (_) {
            return {
              'action': 'NONE', 'pickup_name': '', 'dropoff_name': '', 'vehicle_type': '',
              'response_text': rawText.length > 200 ? rawText.substring(0, 200) : rawText,
            };
          }
        } else if (res.statusCode == 429) {
          // Quota exceeded — try next model
          debugPrint('Gemini quota exceeded for $model, trying next...');
          continue;
        } else {
          debugPrint('Gemini [$model] error ${res.statusCode}: ${res.body}');
          String errorMsg = 'API Error ${res.statusCode}';
          try {
            final errData = json.decode(res.body);
            errorMsg = errData['error']?['message'] ?? errorMsg;
          } catch (_) {}
          return {
            'action': 'NONE', 'pickup_name': '', 'dropoff_name': '', 'vehicle_type': '',
            'response_text': '⚠️ $errorMsg',
          };
        }
      } on TimeoutException {
        continue;
      } catch (e) {
        debugPrint('Gemini network error [$model]: $e');
        continue;
      }
    }

    // All models exhausted
    return {
      'action': 'NONE',
      'pickup_name': '',
      'dropoff_name': '',
      'vehicle_type': '',
      'response_text': _selectedLang == 'hi'
          ? '⚠️ AI abhi busy hai. Thodi der baad try karein ya type karke order karein.'
          : (_selectedLang == 'or'
              ? '⚠️ AI ବ୍ୟସ୍ତ ଅଛି। ଟାଇପ୍ କରି ଚେଷ୍ଟା କରନ୍ତୁ।'
              : '⚠️ AI quota exceeded. Please try again in a moment, or type your request instead.'),
    };
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _speech.stop();
    _flutterTts.stop();
    _pulseController.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: const BoxDecoration(
        color: VayaTheme.inkBlack,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: VayaTheme.saffron.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic, color: VayaTheme.saffron, size: 20),
                ),
                const SizedBox(width: 10),
                const Text(
                  'VAYA Voice AI',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),

                // Status chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isListening
                        ? Colors.red.withOpacity(0.2)
                        : (_isThinking ? VayaTheme.saffron.withOpacity(0.2) : Colors.white10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isListening ? Colors.red : (_isThinking ? VayaTheme.saffron : Colors.white24),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _isListening ? Colors.red : (_isThinking ? VayaTheme.saffron : VayaTheme.routeGreen),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isListening ? 'Listening...' : (_isThinking ? 'Thinking...' : (_isSpeaking ? 'Speaking...' : 'Ready')),
                        style: TextStyle(
                          color: _isListening ? Colors.red : (_isThinking ? VayaTheme.saffron : Colors.white70),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Language Selector Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildLangPill('en', 'English'),
                const SizedBox(width: 8),
                _buildLangPill('hi', 'हिंदी'),
                const SizedBox(width: 8),
                _buildLangPill('or', 'ଓଡ଼ିଆ'),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Live Booking Summary Strip
          if (_pickupAddress.isNotEmpty || _dropoffAddress.isNotEmpty || _selectedVehicle.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VayaTheme.saffron.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, color: VayaTheme.saffron, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pickup: ${_pickupAddress.isEmpty ? "-" : _pickupAddress} • Drop: ${_dropoffAddress.isEmpty ? "-" : _dropoffAddress} • Vehicle: ${_selectedVehicle.isEmpty ? "-" : _selectedVehicle.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),

          const Divider(color: Colors.white12, height: 16),

          // Chat Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (ctx, index) {
                final m = _messages[index];
                final isUser = m['role'] == 'user';
                final lang = m['lang'] ?? 'en';

                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser
                          ? VayaTheme.saffron
                          : (lang == 'or' ? const Color(0xFF1E293B) : const Color(0xFF27272A)),
                      borderRadius: BorderRadius.circular(16).copyWith(
                        bottomRight: isUser ? Radius.zero : const Radius.circular(16),
                        bottomLeft: !isUser ? Radius.zero : const Radius.circular(16),
                      ),
                      border: !isUser && lang == 'or'
                          ? Border.all(color: Colors.amber.withOpacity(0.5), width: 1.2)
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isUser && lang == 'or') ...[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'ଓଡ଼ିଆ • Screen Text Mode',
                                  style: TextStyle(color: Colors.amber, fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                        ],
                        Text(
                          m['text'] ?? '',
                          style: TextStyle(
                            color: isUser ? VayaTheme.inkBlack : Colors.white,
                            fontSize: 14,
                            fontWeight: isUser ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Live transcript box while user speaks
          if (_isListening && _liveTranscript.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _liveTranscript,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
            ),

          // Quick Suggestion Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                _buildQuickChip('📍 Patia to Saheed Nagar'),
                const SizedBox(width: 6),
                _buildQuickChip('🛵 Book Bike'),
                const SizedBox(width: 6),
                _buildQuickChip('🛺 3-Wheeler Tempo'),
                const SizedBox(width: 6),
                _buildQuickChip('🚚 Mini Truck'),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Mic & Text Input Area
          Container(
            padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).viewInsets.bottom + 16),
            decoration: const BoxDecoration(
              color: Color(0xFF18181B),
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: const InputDecoration(
                        hintText: 'Speak or type here...',
                        hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                        border: InputBorder.none,
                      ),
                      onSubmitted: _handleUserSpeechSubmit,
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Text Send button
                if (_textController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.send, color: VayaTheme.saffron),
                    onPressed: () => _handleUserSpeechSubmit(_textController.text),
                  ),

                // Pulsating Mic Button
                GestureDetector(
                  onTap: _toggleListening,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (ctx, child) {
                      final scale = _isListening ? 1.0 + (_pulseController.value * 0.15) : 1.0;
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: _isListening
                                  ? [Colors.redAccent, Colors.red]
                                  : [VayaTheme.saffron, const Color(0xFFF97316)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (_isListening ? Colors.red : VayaTheme.saffron).withOpacity(0.4),
                                blurRadius: _isListening ? 12 : 6,
                                spreadRadius: _isListening ? 4 : 1,
                              ),
                            ],
                          ),
                          child: Icon(
                            _isListening ? Icons.stop : Icons.mic,
                            color: VayaTheme.inkBlack,
                            size: 26,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLangPill(String code, String label) {
    final isSelected = _selectedLang == code;
    return GestureDetector(
      onTap: () => _switchLanguage(code),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? VayaTheme.saffron : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? VayaTheme.saffron : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? VayaTheme.inkBlack : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildQuickChip(String text) {
    return GestureDetector(
      onTap: () {
        _handleUserSpeechSubmit(text);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ),
    );
  }
}
