import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

// Configuration URLs - Change to your Cloud Run URL in production
const String apiBaseUrl = "https://vaya-backend-275777907648.us-central1.run.app";
const String wsBaseUrl = "wss://vaya-backend-275777907648.us-central1.run.app";

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkAuthState();
  }

  Future<void> _checkAuthState() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _checking = false);
      return;
    }

    try {
      final token = await user.getIdToken();
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/customer/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
              (route) => false,
            );
          } else {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              (route) => false,
            );
          }
        }
      } else {
        setState(() => _checking = false);
      }
    } catch (e) {
      debugPrint("Auth check error: $e");
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: VayaTheme.saffron),
        ),
      );
    }
    return LanguageSelectionScreen(
      onLanguageSelected: (locale) {
        final appState = context.findAncestorStateOfType<_VayaCustomerAppState>();
        appState?.setLocale(locale);
      },
    );
  }
}

// i18n Strings dictionary
class LocalizedStrings {
  final Locale locale;
  LocalizedStrings(this.locale);

  static LocalizedStrings of(BuildContext context) {
    return LocalizedStrings(Localizations.localeOf(context));
  }

  String get selectLang => locale.languageCode == 'or' ? 'ଭାଷା ଚୟନ କରନ୍ତୁ' : locale.languageCode == 'hi' ? 'भाषा चुनें' : 'Select Language';
  String get welcome => 'VAYA';
  String get mobileLogin => locale.languageCode == 'or' ? 'ମୋବାଇଲ୍ ଲଗ୍ ଇନ୍' : locale.languageCode == 'hi' ? 'मोबाइल लॉगिन' : 'Mobile Login';
  String get enterMobile => locale.languageCode == 'or' ? '୧୦-ଅଙ୍କ ମୋବାଇଲ୍ ନମ୍ବର ଦିଅନ୍ତୁ' : locale.languageCode == 'hi' ? '10-अंकीय मोबाइल नंबर दर्ज करें' : 'Enter 10-digit Mobile Number';
  String get sendOtp => locale.languageCode == 'or' ? 'OTP ପଠାନ୍ତୁ' : locale.languageCode == 'hi' ? 'ओटीपी भेजें' : 'Send OTP';
  String get verifyOtp => locale.languageCode == 'or' ? 'OTP ଯାଞ୍ଚ କରନ୍ତୁ' : locale.languageCode == 'hi' ? 'ओटीपी सत्यापित करें' : 'Verify OTP';
  String get bookNow => locale.languageCode == 'or' ? 'ବୁକିଂ କରନ୍ତୁ' : locale.languageCode == 'hi' ? 'बुकिंग करें' : 'Book a VAYA';
  String get tracking => locale.languageCode == 'or' ? 'ବୁକିଂ ଟ୍ରାକ୍' : locale.languageCode == 'hi' ? 'ट्रैकिंग' : 'Track VAYA';
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
          if (data['exists'] == true) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
              (route) => false,
            );
          } else {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              (route) => false,
            );
          }
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMsg = 'Failed to load user profile from server.';
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
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
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
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final token = await user.getIdToken();
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
                  ? const CircularProgressIndicator(color: Colors.white)
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

  @override
  void initState() {
    super.initState();
    _checkActiveBooking();
    _activeBookingCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkActiveBooking();
    });
  }

  @override
  void dispose() {
    _activeBookingCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkActiveBooking() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/active'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          setState(() {
            if (data['exists'] == true) {
              _activeBooking = data['booking'];
            } else {
              _activeBooking = null;
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Error checking active booking: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      const HomeScreen(),
      OrdersScreen(onTrackActive: () {
        if (_activeBooking != null) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TrackingScreen(bookingId: _activeBooking!['id'])),
          ).then((_) => _checkActiveBooking());
        }
      }),
      const PaymentsScreen(),
      const AccountScreen(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: pages,
          ),

          // Persistent "Track Active Order" card above bottom navigation
          if (_activeBooking != null && _currentIndex != 1)
            Positioned(
              left: 16,
              right: 16,
              bottom: 80,
              child: GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => TrackingScreen(bookingId: _activeBooking!['id'])),
                  ).then((_) => _checkActiveBooking());
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: VayaTheme.inkBlack,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: VayaTheme.saffron.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.local_shipping, color: VayaTheme.saffron, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  'ACTIVE DELIVERY',
                                  style: TextStyle(
                                    color: VayaTheme.saffron,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    color: VayaTheme.routeGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_activeBooking!['vehicle_type']?.toString().toUpperCase()} • Status: ${_activeBooking!['status']}',
                              style: const TextStyle(
                                color: VayaTheme.signalCream,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios, color: VayaTheme.signalCream, size: 16),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
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
                if (_activeBooking != null)
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
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LatLng _pickup = const LatLng(20.2961, 85.8245); // Master Canteen, Bhubaneswar
  LatLng _dropoff = const LatLng(20.3150, 85.8178); // Patia, Bhubaneswar
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  GoogleMapController? _mapController;

  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  bool _isLocating = true;

  @override
  void initState() {
    super.initState();
    _updateMarkers();
    _locateUserPosition();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _locateUserPosition() async {
    setState(() => _isLocating = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        final coords = LatLng(pos.latitude, pos.longitude);
        _pickup = coords;
        _updateMarkers();
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(coords, 14));

        final addr = await _reverseGeocode(pos.latitude, pos.longitude);
        if (mounted) {
          setState(() {
            _pickupController.text = addr;
            _isLocating = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLocating = false);
      }
    } catch (e) {
      debugPrint("Error locating user: $e");
      if (mounted) setState(() => _isLocating = false);
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
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['display_name'] ?? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
      }
    } catch (e) {
      debugPrint("Reverse geocode error: $e");
    }
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  void _updateMarkers() {
    setState(() {
      _markers.clear();
      _markers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: _pickup,
        infoWindow: const InfoWindow(title: 'Pickup Location'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ));
      _markers.add(Marker(
        markerId: const MarkerId('dropoff'),
        position: _dropoff,
        infoWindow: const InfoWindow(title: 'Destination Location'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));

      _polylines.clear();
      if (_pickupController.text.isNotEmpty && _dropoffController.text.isNotEmpty) {
        _polylines.add(Polyline(
          polylineId: const PolylineId('route_line'),
          points: [_pickup, _dropoff],
          color: VayaTheme.liveBlue,
          width: 4,
        ));
      }
    });
    _fitRouteBounds();
  }

  void _fitRouteBounds() {
    if (_mapController == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        _pickup.latitude < _dropoff.latitude ? _pickup.latitude : _dropoff.latitude,
        _pickup.longitude < _dropoff.longitude ? _pickup.longitude : _dropoff.longitude,
      ),
      northeast: LatLng(
        _pickup.latitude > _dropoff.latitude ? _pickup.latitude : _dropoff.latitude,
        _pickup.longitude > _dropoff.longitude ? _pickup.longitude : _dropoff.longitude,
      ),
    );
    _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  void _openLocationSearchModal(String fieldType) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenLocationSearch(
          initialType: fieldType,
          currentLocation: _pickup,
        ),
      ),
    );

    if (result != null && mounted) {
      final LatLng newPos = result['coords'];
      final String address = result['address'];

      setState(() {
        if (fieldType == 'pickup') {
          _pickup = newPos;
          _pickupController.text = address;
        } else {
          _dropoff = newPos;
          _dropoffController.text = address;
        }
        _updateMarkers();
      });

      // Auto-switch focus: If pickup was just selected, prompt for destination
      if (fieldType == 'pickup' && _dropoffController.text.isEmpty) {
        _openLocationSearchModal('destination');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dist = Geolocator.distanceBetween(
      _pickup.latitude,
      _pickup.longitude,
      _dropoff.latitude,
      _dropoff.longitude,
    ) / 1000.0;
    
    final durationMin = (dist / 30.0 * 60).round() + 5;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VΛYΛ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location, color: VayaTheme.saffron),
            onPressed: _locateUserPosition,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _pickup,
                    zoom: 13,
                  ),
                  markers: _markers,
                  polylines: _polylines,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  onMapCreated: (c) {
                    _mapController = c;
                    _fitRouteBounds();
                  },
                  onTap: (latLng) async {
                    final addr = await _reverseGeocode(latLng.latitude, latLng.longitude);
                    setState(() {
                      _dropoff = latLng;
                      _dropoffController.text = addr;
                      _updateMarkers();
                    });
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  boxShadow: [
                    BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_pickupController.text.isNotEmpty && _dropoffController.text.isNotEmpty) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.route, size: 16, color: VayaTheme.liveBlue),
                              const SizedBox(width: 6),
                              const Text(
                                'Route details',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.slate),
                              ),
                            ],
                          ),
                          Text(
                            '${dist.toStringAsFixed(1)} km · approximately $durationMin min',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        disabledBackgroundColor: VayaTheme.fog,
                      ),
                      onPressed: (_pickupController.text.isEmpty || _dropoffController.text.isEmpty || dist < 0.05)
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
                                  ),
                                ),
                              );
                            },
                      child: Text(
                        (_pickupController.text.isEmpty || _dropoffController.text.isEmpty)
                            ? 'Select points to proceed'
                            : (dist < 0.05 ? 'Locations too close' : 'Choose vehicle'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Labeled Search Card Float Overlay
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    // Pickup Labeled Field
                    InkWell(
                      onTap: () => _openLocationSearchModal('pickup'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: VayaTheme.signalCream,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: VayaTheme.saffron.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'PICKUP',
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _isLocating
                                    ? 'Locating current position...'
                                    : (_pickupController.text.isEmpty ? 'Where to pick up?' : _pickupController.text),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: _pickupController.text.isEmpty ? VayaTheme.slate : VayaTheme.inkBlack,
                                ),
                              ),
                            ),
                            const Icon(Icons.edit, size: 14, color: VayaTheme.slate),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Destination Labeled Field
                    InkWell(
                      onTap: () => _openLocationSearchModal('destination'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: VayaTheme.signalCream,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'DROP-OFF',
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.red),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _dropoffController.text.isEmpty ? 'Where to deliver?' : _dropoffController.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: _dropoffController.text.isEmpty ? VayaTheme.slate : VayaTheme.inkBlack,
                                ),
                              ),
                            ),
                            const Icon(Icons.edit, size: 14, color: VayaTheme.slate),
                          ],
                        ),
                      ),
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

/// Full-Screen Location Search & Autocomplete Modal
class FullScreenLocationSearch extends StatefulWidget {
  final String initialType;
  final LatLng currentLocation;
  const FullScreenLocationSearch({super.key, required this.initialType, required this.currentLocation});

  @override
  State<FullScreenLocationSearch> createState() => _FullScreenLocationSearchState();
}

class _FullScreenLocationSearchState extends State<FullScreenLocationSearch> {
  final TextEditingController _queryController = TextEditingController();
  List<Map<String, dynamic>> _predictions = [];
  bool _searching = false;
  Timer? _debounce;

  final List<Map<String, String>> _recentSearches = [
    {'title': 'Master Canteen Railway Station', 'subtitle': 'Railway Station Rd, Master Canteen Area, Bhubaneswar'},
    {'title': 'Patia Infocity Square', 'subtitle': 'Infocity, Patia, Bhubaneswar'},
    {'title': 'Janpath Market Complex', 'subtitle': 'Ashok Nagar, Janpath, Bhubaneswar'},
  ];

  // Mutable list for Saved Locations with Warehouse, Shop, Supplier, Office custom categories
  final List<Map<String, String>> _savedPlaces = [
    {'title': 'Main Warehouse', 'subtitle': 'Plot B, Chandaka Industrial Estate, Patia', 'type': 'Warehouse'},
    {'title': 'Central Store Shop', 'subtitle': 'Plot 102, Saheed Nagar, Bhubaneswar', 'type': 'Shop'},
    {'title': 'Suppliers Hub', 'subtitle': 'Unit 4 Market Complex, Bhubaneswar', 'type': 'Supplier'},
    {'title': 'Head Office', 'subtitle': 'Infocity Road, Patia, Bhubaneswar', 'type': 'Office'},
  ];

  void _onQueryChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _predictions.clear();
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final viewbox = '85.70,20.40,85.95,20.20';
      final url = 'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&viewbox=$viewbox&bounded=1&limit=6';
      try {
        final res = await http.get(
          Uri.parse(url),
          headers: {'Accept-Language': 'en', 'User-Agent': 'VAYACustomerApp/1.0'},
        );
        if (res.statusCode == 200) {
          final List<dynamic> data = json.decode(res.body);
          if (mounted) {
            setState(() {
              _predictions = data.map((d) {
                final lat = double.parse(d['lat'] as String);
                final lon = double.parse(d['lon'] as String);
                // Bounding boxes check for Bhubaneswar: lat [20.15, 20.45], lng [85.65, 85.98]
                final outside = (lat < 20.15 || lat > 20.45 || lon < 85.65 || lon > 85.98);
                return {
                  'display_name': d['display_name'] as String,
                  'lat': lat,
                  'lon': lon,
                  'outside': outside,
                };
              }).toList();
              _searching = false;
            });
          }
        }
      } catch (e) {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _deleteSavedPlace(int index) {
    setState(() {
      _savedPlaces.removeAt(index);
    });
  }

  void _editSavedPlace(int index) {
    final titleController = TextEditingController(text: _savedPlaces[index]['title']);
    final subtitleController = TextEditingController(text: _savedPlaces[index]['subtitle']);
    String selectedType = _savedPlaces[index]['type'] ?? 'Warehouse';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit Saved Location', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Label Name'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'Warehouse', child: Text('Warehouse')),
                  DropdownMenuItem(value: 'Shop', child: Text('Shop')),
                  DropdownMenuItem(value: 'Office', child: Text('Office')),
                  DropdownMenuItem(value: 'Supplier', child: Text('Supplier')),
                  DropdownMenuItem(value: 'Custom', child: Text('Custom')),
                ],
                onChanged: (val) => selectedType = val!,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subtitleController,
                decoration: const InputDecoration(labelText: 'Address Details'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _savedPlaces[index] = {
                    'title': titleController.text,
                    'subtitle': subtitleController.text,
                    'type': selectedType,
                  };
                });
                Navigator.pop(ctx);
              },
              child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _addSavedPlace() {
    final titleController = TextEditingController();
    final subtitleController = TextEditingController();
    String selectedType = 'Warehouse';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add Saved Location', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Label Name (e.g. Warehouse A)'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'Warehouse', child: Text('Warehouse')),
                  DropdownMenuItem(value: 'Shop', child: Text('Shop')),
                  DropdownMenuItem(value: 'Office', child: Text('Office')),
                  DropdownMenuItem(value: 'Supplier', child: Text('Supplier')),
                  DropdownMenuItem(value: 'Custom', child: Text('Custom')),
                ],
                onChanged: (val) => selectedType = val!,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subtitleController,
                decoration: const InputDecoration(labelText: 'Address Details'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _savedPlaces.add({
                    'title': titleController.text,
                    'subtitle': subtitleController.text,
                    'type': selectedType,
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _openMapDirectly() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPinPickerScreen(
          initialCoords: widget.currentLocation,
          type: widget.initialType,
        ),
      ),
    );
    if (result != null && mounted) {
      Navigator.pop(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPickup = widget.initialType == 'pickup';

    return Scaffold(
      appBar: AppBar(
        title: Text(isPickup ? 'Select pickup' : 'Select drop-off'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _queryController,
              autofocus: true,
              style: const TextStyle(fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, color: VayaTheme.saffron),
                hintText: 'Search area, street or landmark',
                suffixIcon: _queryController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear search query',
                        onPressed: () {
                          _queryController.clear();
                          setState(() => _predictions.clear());
                        },
                      )
                    : null,
              ),
              onChanged: _onQueryChanged,
            ),
          ),

          // Map Picker quick tile
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: VayaTheme.saffron,
              child: Icon(Icons.map, color: Colors.white, size: 20),
            ),
            title: const Text('Choose precise location on Map', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text(
              isPickup ? 'Drag map to set exact pickup gate' : 'Drag map to set exact drop-off gate',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openMapDirectly,
          ),
          const Divider(height: 1),

          if (_searching)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: VayaTheme.saffron),
            )
          else if (_predictions.isEmpty && _queryController.text.trim().length >= 2)
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  const Icon(Icons.search_off, size: 48, color: VayaTheme.slate),
                  const SizedBox(height: 10),
                  const Text('No matching places found', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  const Text('Try typing a landmark, or choose directly from the map.', style: TextStyle(fontSize: 11, color: VayaTheme.slate), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _openMapDirectly,
                    icon: const Icon(Icons.map),
                    label: const Text('Open Map Picker'),
                  ),
                ],
              ),
            )
          else if (_predictions.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _predictions.length,
                itemBuilder: (ctx, i) {
                  final p = _predictions[i];
                  final outside = p['outside'] as bool;
                  return ListTile(
                    leading: const Icon(Icons.location_on_outlined, color: VayaTheme.saffron),
                    title: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 12, color: VayaTheme.inkBlack),
                        children: [
                          if (outside)
                            const TextSpan(
                              text: '⚠️ [Outside Service Area] ',
                              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                            ),
                          TextSpan(text: p['display_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context, {
                        'address': p['display_name'],
                        'coords': LatLng(p['lat'], p['lon']),
                      });
                    },
                  );
                },
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('SAVED LOCATIONS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                        TextButton.icon(
                          onPressed: _addSavedPlace,
                          icon: const Icon(Icons.add, size: 12),
                          label: const Text('Add new', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(60, 20)),
                        ),
                      ],
                    ),
                  ),
                  ..._savedPlaces.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final sp = entry.value;
                    IconData icon = Icons.warehouse;
                    if (sp['type'] == 'Shop') icon = Icons.storefront;
                    if (sp['type'] == 'Office') icon = Icons.work;
                    if (sp['type'] == 'Supplier') icon = Icons.local_shipping;
                    if (sp['type'] == 'Home') icon = Icons.home;

                    return ListTile(
                      leading: Icon(icon, color: VayaTheme.saffron),
                      title: Row(
                        children: [
                          Text(sp['title']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: VayaTheme.slate.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              sp['type'] ?? 'Warehouse',
                              style: const TextStyle(fontSize: 9, color: VayaTheme.slate, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(sp['subtitle']!, style: const TextStyle(fontSize: 11)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, size: 16, color: VayaTheme.slate),
                            onPressed: () => _editSavedPlace(idx),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                            onPressed: () => _deleteSavedPlace(idx),
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.pop(context, {
                          'address': sp['subtitle']!,
                          'coords': widget.currentLocation,
                        });
                      },
                    );
                  }),
                  const Divider(height: 16),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text('RECENT SEARCHES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                  ),
                  ..._recentSearches.map((rs) => ListTile(
                        leading: const Icon(Icons.history, color: VayaTheme.slate),
                        title: Text(rs['title']!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        subtitle: Text(rs['subtitle']!, style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context, {
                            'address': rs['subtitle']!,
                            'coords': widget.currentLocation,
                        });
                      },
                    )),
                ],
              ),
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

  Future<Map<String, dynamic>?> _showAddressDetailsDialog(BuildContext context, String type, String baseAddress) async {
    final formKey = GlobalKey<FormState>();
    String houseNo = '';
    String floor = '';
    String landmark = '';
    String contactPerson = '';
    String instructions = '';

    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Add ${type == 'pickup' ? 'pickup' : 'drop-off'} details',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: VayaTheme.inkBlack),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Text(
                    baseAddress,
                    style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Flat / House / Building No *',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    validator: (val) => (val == null || val.trim().isEmpty) ? 'Required' : null,
                    onSaved: (val) => houseNo = val ?? '',
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Floor / Wing (Optional)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onSaved: (val) => floor = val ?? '',
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Nearby Landmark *',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    validator: (val) => (val == null || val.trim().isEmpty) ? 'Required' : null,
                    onSaved: (val) => landmark = val ?? '',
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Contact Person (Optional)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onSaved: (val) => contactPerson = val ?? '',
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Driver Instructions (e.g. gate, loading rules)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onSaved: (val) => instructions = val ?? '',
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VayaTheme.saffron,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      if (formKey.currentState!.validate()) {
                        formKey.currentState!.save();
                        Navigator.pop(ctx, {
                          'houseNo': houseNo,
                          'floor': floor,
                          'landmark': landmark,
                          'contactPerson': contactPerson,
                          'instructions': instructions,
                        });
                      }
                    },
                    child: const Text('Save address details', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPickup = widget.type == 'pickup';
    
    // Detect low-confidence pins
    bool isLowConfidence = _address.split(',').length < 4 ||
        _address.toLowerCase().contains('municipal corporation') ||
        _address.toLowerCase().contains('zone') ||
        _address.toLowerCase().contains('district');

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
            bottom: 210,
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
                    if (isLowConfidence && !_loading) ...[
                      const SizedBox(height: 6),
                      const Text(
                        '⚠️ This pin appears to be in a general area. Move it closer to the entrance or gate.',
                        style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () async {
                        // Request precise address details modal
                        final details = await _showAddressDetailsDialog(context, widget.type, _address);
                        if (details != null && context.mounted) {
                          String finalAddress = "${details['houseNo']}";
                          if (details['floor']!.isNotEmpty) finalAddress += ", Floor ${details['floor']}";
                          finalAddress += " (Landmark: ${details['landmark']})";
                          if (details['contactPerson']!.isNotEmpty) finalAddress += ", Contact: ${details['contactPerson']}";
                          if (details['instructions']!.isNotEmpty) finalAddress += " [Instructions: ${details['instructions']}]";
                          finalAddress += ", $_address";

                          Navigator.pop(context, {
                            'address': finalAddress,
                            'coords': _center,
                          });
                        }
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

  const VehicleSelectionScreen({
    super.key,
    required this.pickup,
    required this.pickupAddress,
    required this.dropoff,
    required this.dropoffAddress,
  });

  @override
  State<VehicleSelectionScreen> createState() => _VehicleSelectionScreenState();
}

class _VehicleSelectionScreenState extends State<VehicleSelectionScreen> {
  String _selectedVehicle = 'bike';
  String _goodsCategory = 'General Cargo';
  int _helperCount = 0; // 0: No helper, 1: 1 Helper (+150), 2: 2 Helpers (+300)
  String _couponCode = '';
  double _discount = 0.0;
  String _paymentMethod = 'Cash';
  bool _isLoading = false;

  bool _isPickupExpanded = false;
  bool _isDropoffExpanded = false;
  final ScrollController _scrollController = ScrollController();

  List<dynamic> _serverPricing = [];
  bool _loadingPricing = true;

  @override
  void initState() {
    super.initState();
    _fetchPricingConfig();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchPricingConfig() async {
    try {
      final response = await http.get(Uri.parse('$apiBaseUrl/api/pricing-config'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _serverPricing = data['pricing'] ?? [];
            _loadingPricing = false;
          });
        }
      } else {
        setState(() => _loadingPricing = false);
      }
    } catch (e) {
      debugPrint("Failed to load pricing: $e");
      setState(() => _loadingPricing = false);
    }
  }

  double _calculatePrice(String vehicleId) {
    final double dist = Geolocator.distanceBetween(
      widget.pickup.latitude,
      widget.pickup.longitude,
      widget.dropoff.latitude,
      widget.dropoff.longitude,
    ) / 1000.0;

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

  Future<void> _handleBooking() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final token = await user.getIdToken();
      final estimatedCost = _calculatePrice(_selectedVehicle);
      
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/booking'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'pickupName': widget.pickupAddress,
          'pickupLat': widget.pickup.latitude,
          'pickupLng': widget.pickup.longitude,
          'dropoffName': widget.dropoffAddress,
          'dropoffLat': widget.dropoff.latitude,
          'dropoffLng': widget.dropoff.longitude,
          'vehicleType': _selectedVehicle,
          'weight': _selectedVehicle == 'bike' ? 15 : (_selectedVehicle == 'ace' ? 400 : 1500),
          'estimatedCost': estimatedCost,
          'goodsCategory': _goodsCategory,
          'helpers': _helperCount,
          'paymentMethod': _paymentMethod == 'Cash' ? 'Cash on Delivery' : 'UPI / Wallet',
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (_) => TrackingScreen(bookingId: data['booking']['id']),
            ),
            (route) => route.isFirst,
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to request booking. Please try again.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showHelpMeChooseSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Help Me Choose a Vehicle',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
              ),
              const SizedBox(height: 4),
              const Text(
                'Select what you want to deliver to get a recommendation:',
                style: TextStyle(fontSize: 12, color: VayaTheme.slate),
              ),
              const SizedBox(height: 16),
              _buildHelpOption(
                title: 'Documents, Keys, Food or Small Box',
                subtitle: 'Recommended: Bike (Up to 20 kg)',
                vehicleId: 'bike',
              ),
              _buildHelpOption(
                title: 'Appliances, Groceries, or Multiple Cartons',
                subtitle: 'Recommended: Cargo 3-Wheeler (Up to 150 kg)',
                vehicleId: 'three_wheeler',
              ),
              _buildHelpOption(
                title: 'Heavy furniture, Fridge, washing machine',
                subtitle: 'Recommended: Mini Truck (4-Wheeler) (Up to 600 kg)',
                vehicleId: 'ace',
              ),
              _buildHelpOption(
                title: 'Bulk commercial stock or House shifting',
                subtitle: 'Recommended: LCV (4-Wheeler) (Up to 2,000 kg)',
                vehicleId: 'truck',
              ),
            ],
          ),
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
        title: const Text('Choose a vehicle'),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Route Overview Card
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: VayaTheme.fog),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _isPickupExpanded = !_isPickupExpanded),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.location_on, color: VayaTheme.routeGreen, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'From: ${widget.pickupAddress}',
                                maxLines: _isPickupExpanded ? null : 1,
                                overflow: _isPickupExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: VayaTheme.inkBlack),
                              ),
                            ),
                            Icon(
                              _isPickupExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: VayaTheme.slate,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => setState(() => _isDropoffExpanded = !_isDropoffExpanded),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.flag, color: Colors.red, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'To: ${widget.dropoffAddress}',
                                maxLines: _isDropoffExpanded ? null : 1,
                                overflow: _isDropoffExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: VayaTheme.inkBlack),
                              ),
                            ),
                            Icon(
                              _isDropoffExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: VayaTheme.slate,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 16),
                      // Equal columns layout for distance and transit duration
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Estimated distance', style: TextStyle(fontSize: 10, color: VayaTheme.slate)),
                                const SizedBox(height: 2),
                                Text(
                                  dist < 0.05 ? 'Calculating route...' : '${dist.toStringAsFixed(1)} km',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack),
                                ),
                              ],
                            ),
                          ),
                          Container(width: 1, height: 26, color: VayaTheme.fog),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Estimated duration', style: TextStyle(fontSize: 10, color: VayaTheme.slate)),
                                const SizedBox(height: 2),
                                Text(
                                  dist < 0.05 ? '--' : '~${(dist / 30.0 * 60).round() + 5} min',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack),
                                ),
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
                const Center(child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(color: VayaTheme.saffron),
                ))
              else ...[
                _buildVehicleOption(
                  id: 'bike',
                  name: 'Bike',
                  capacity: 'Up to 20 kg',
                  dimensions: '35 x 35 x 40 cm',
                  eta: '3 mins away',
                  icon: Icons.motorcycle,
                  cargoExamples: 'Documents, food, small packets',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'three_wheeler',
                  name: 'Cargo 3-Wheeler',
                  capacity: 'Up to 150 kg',
                  dimensions: '1.2m x 1m x 1m',
                  eta: '5 mins away',
                  icon: Icons.moped,
                  cargoExamples: 'Medium boxes, crates, retail supplies',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'ace',
                  name: 'Mini Truck',
                  capacity: 'Up to 600 kg',
                  dimensions: '2.1m x 1.4m x 1.2m',
                  eta: '8 mins away',
                  icon: Icons.local_shipping,
                  cargoExamples: 'Appliances, furniture, business inventory',
                ),
                const SizedBox(height: 8),
                _buildVehicleOption(
                  id: 'truck',
                  name: 'LCV (4-Wheeler)',
                  capacity: 'Up to 2,000 kg',
                  dimensions: '3.0m x 1.8m x 1.8m',
                  eta: '12 mins away',
                  icon: Icons.fire_truck,
                  cargoExamples: 'Bulk commercial loads, house shifting',
                ),
              ],

              const SizedBox(height: 18),
              const Text(
                'TRIP CUSTOMIZATION',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2, color: VayaTheme.slate),
              ),
              const SizedBox(height: 8),

              // Goods Category Dropdown
              DropdownButtonFormField<String>(
                value: _goodsCategory,
                decoration: const InputDecoration(
                  labelText: 'Goods Category',
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(),
                ),
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border.all(color: Colors.amber.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.amber.shade900),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Restrictions: Fragile items require protective packaging. Prohibited items, hazardous materials, and chemicals are not permitted.',
                        style: TextStyle(fontSize: 10, color: VayaTheme.slate),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Labour / Helper Selection Stacked Rows
              const Text(
                'Helper / Loading Assistance',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
              ),
              const SizedBox(height: 2),
              const Text(
                'Helper supports loading and unloading; driver assistance is not included.',
                style: TextStyle(fontSize: 11, color: VayaTheme.slate),
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
              const SizedBox(height: 14),

              // Payment Method Choices (Stacked rows)
              const Text(
                'Payment Method',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
              ),
              const SizedBox(height: 8),
              Column(
                children: [
                  _buildPaymentOptionTile(
                    title: 'Cash',
                    subtitle: 'Pay directly to the driver at the pickup/drop point.',
                    icon: Icons.money,
                    value: 'Cash',
                  ),
                  _buildPaymentOptionTile(
                    title: 'UPI / Wallet',
                    subtitle: 'Pay digitally via scan-to-pay or integrated wallets.',
                    icon: Icons.qr_code,
                    value: 'UPI / Wallet',
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Itemized Fare Review Card
              Card(
                color: VayaTheme.signalCream,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: VayaTheme.fog),
                ),
                child: ExpansionTile(
                  initiallyExpanded: true,
                  title: const Text(
                    'Estimated total',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                  ),
                  trailing: Text(
                    '₹${estFare.toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: VayaTheme.saffron),
                  ),
                  childrenPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  expandedAlignment: Alignment.topLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                  collapsedShape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Base Transport Fare', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                        Text('₹${baseFareRaw.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_helperCount > 0) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Helper Loading Fee ($_helperCount helper)', style: const TextStyle(fontSize: 12, color: VayaTheme.slate)),
                          Text('₹${(_helperCount * 150.0).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack)),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('GST Taxes (5%)', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                        Text('₹${(baseFareRaw * 0.05).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Platform Fee', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                        Text('₹10.00', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack)),
                      ],
                    ),
                    const Divider(height: 12),
                    const Text(
                      '* Estimated charges. Final rates might vary due to route changes, parking, tolls, or extra loading wait times.',
                      style: TextStyle(fontSize: 9, color: VayaTheme.slate, fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: VayaTheme.fog.withOpacity(0.5))),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2)),
          ],
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Sticky Selection Bar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 14, color: VayaTheme.routeGreen),
                      const SizedBox(width: 4),
                      Text(
                        'Selected: ${_selectedVehicle == 'bike' ? 'Bike' : _selectedVehicle == 'three_wheeler' ? 'Cargo 3-Wheeler' : _selectedVehicle == 'ace' ? 'Mini Truck' : 'LCV'} · ₹${estFare.toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.inkBlack),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () {
                      _scrollController.animateTo(
                        0,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOut,
                      );
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(50, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Change',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VayaTheme.saffron),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Center(
                child: Text(
                  'No charge until a driver accepts',
                  style: TextStyle(fontSize: 10, color: VayaTheme.slate),
                ),
              ),
              const SizedBox(height: 6),
              ElevatedButton(
                onPressed: (dist < 0.05 || _isLoading) ? null : _handleBooking,
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaTheme.saffron,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  disabledBackgroundColor: VayaTheme.fog,
                ),
                child: _isLoading 
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        dist < 0.05
                            ? 'Invalid route selected'
                            : 'Book ${_selectedVehicle == 'bike' ? 'Bike' : _selectedVehicle == 'three_wheeler' ? 'Cargo 3-Wheeler' : _selectedVehicle == 'ace' ? 'Mini Truck' : 'LCV'} · ₹${estFare.toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
              ),
            ],
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
    required IconData icon,
    required String cargoExamples,
  }) {
    final isSelected = _selectedVehicle == id;
    final fare = _calculatePrice(id);
    final cleanEta = eta.replaceAll('mins away', 'min').replaceAll('away', '').trim();
    final etaText = 'Arrives in $cleanEta';

    return InkWell(
      onTap: () => setState(() => _selectedVehicle = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
            width: isSelected ? 2.0 : 1.0,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected ? VayaTheme.saffron.withOpacity(0.04) : Colors.white,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? VayaTheme.saffron.withOpacity(0.12) : VayaTheme.fog.withOpacity(0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 24, color: isSelected ? VayaTheme.saffron : VayaTheme.slate),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isSelected)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: VayaTheme.saffron,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check, size: 9, color: Colors.white),
                              SizedBox(width: 2),
                              Text('Selected', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$capacity · $dimensions',
                    style: const TextStyle(fontSize: 10, color: VayaTheme.slate, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Best for: $cargoExamples',
                    style: TextStyle(fontSize: 9, color: VayaTheme.slate.withOpacity(0.8), fontStyle: FontStyle.italic),
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
                  'Est. fare',
                  style: TextStyle(fontSize: 9, color: VayaTheme.slate.withOpacity(0.6)),
                ),
                Text(
                  '₹${fare.toStringAsFixed(0)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: isSelected ? VayaTheme.saffron : VayaTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  etaText,
                  style: const TextStyle(fontSize: 9, color: VayaTheme.liveBlue, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 7. Full-Screen Order Status & Live Tracking Experience
class TrackingScreen extends StatefulWidget {
  final String bookingId;
  const TrackingScreen({super.key, required this.bookingId});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  IOWebSocketChannel? _channel;
  GoogleMapController? _mapController;

  String _status = "searching"; // searching, driver_assigned, arrived_pickup, loading, in_transit, arrived_drop, completed
  String _driverName = "Searching nearby drivers...";
  String _driverPlate = "-";
  String _driverPhone = "";
  String _otp = "";
  double _estimatedCost = 0.0;
  String _vehicleType = "bike";

  LatLng _pickupPos = const LatLng(20.2961, 85.8245);
  LatLng _dropPos = const LatLng(20.3150, 85.8178);
  LatLng? _driverPos;
  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _fetchBookingDetails();
    _connectWebSocket();
  }

  Future<void> _fetchBookingDetails() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final token = await user.getIdToken();
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/active'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['exists'] == true) {
          final booking = data['booking'];
          setState(() {
            _status = booking['status'];
            _otp = booking['otp'] ?? '849201';
            _estimatedCost = double.tryParse(booking['estimated_cost'].toString()) ?? 0.0;
            _vehicleType = booking['vehicle_type'] ?? 'bike';
            if (booking['pickup_lat'] != null) {
              _pickupPos = LatLng(double.parse(booking['pickup_lat'].toString()), double.parse(booking['pickup_lng'].toString()));
            }
            if (booking['dropoff_lat'] != null) {
              _dropPos = LatLng(double.parse(booking['dropoff_lat'].toString()), double.parse(booking['dropoff_lng'].toString()));
            }
            if (booking['driver_id'] != null) {
              _driverName = booking['driver_name'] ?? "Driver Partner";
              _driverPlate = booking['driver_plate'] ?? "OD-02-X-999";
            }
            _updateMapMarkers();
          });
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch booking info: $e");
    }
  }

  Future<void> _connectWebSocket() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      _channel = IOWebSocketChannel.connect(
        Uri.parse('$wsBaseUrl/ws?token=$token'),
      );

      _channel!.stream.listen((message) {
        final data = json.decode(message);

        if (data['type'] == 'booking_accepted' && data['bookingId'] == widget.bookingId) {
          final b = data['booking'];
          setState(() {
            _status = 'driver_assigned';
            _driverName = b['driver_name'] ?? 'Driver Partner';
            _driverPlate = b['driver_plate'] ?? '';
          });
        } else if (data['type'] == 'booking_transit' && data['bookingId'] == widget.bookingId) {
          setState(() => _status = 'in_transit');
        } else if (data['type'] == 'booking_status' && data['bookingId'] == widget.bookingId) {
          setState(() => _status = data['status']);
        } else if (data['type'] == 'driver_position') {
          final lat = data['lat'];
          final lng = data['lng'];
          setState(() {
            _driverPos = LatLng(lat, lng);
            _updateMapMarkers();
          });
        }
      });
    } catch (e) {
      debugPrint("WebSocket failed: $e");
    }
  }

  void _updateMapMarkers() {
    _markers.clear();
    _markers.add(Marker(
      markerId: const MarkerId('pickup'),
      position: _pickupPos,
      infoWindow: const InfoWindow(title: 'Pickup Location'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
    ));
    _markers.add(Marker(
      markerId: const MarkerId('dropoff'),
      position: _dropPos,
      infoWindow: const InfoWindow(title: 'Dropoff Location'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
    ));
    if (_driverPos != null) {
      _markers.add(Marker(
        markerId: const MarkerId('driver'),
        position: _driverPos!,
        infoWindow: const InfoWindow(title: 'Driver Live Location'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ));
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Booking #${widget.bookingId.substring(0, 8).toUpperCase()}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Contacting VAYA 24x7 Customer Support...')),
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
            onMapCreated: (c) => _mapController = c,
          ),

          // Layered Fulfilment Status Card
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Card(
              color: Colors.white,
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Status Badge Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: VayaTheme.saffron.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _status.toUpperCase().replaceAll('_', ' '),
                            style: const TextStyle(
                              color: VayaTheme.saffron,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Text(
                          'Est. Fare: ₹${_estimatedCost.toStringAsFixed(0)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Driver Card Section
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: VayaTheme.fog,
                        child: Icon(Icons.person, color: VayaTheme.inkBlack),
                      ),
                      title: Text(_driverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      subtitle: Text('Plate: $_driverPlate • Class: ${_vehicleType.toUpperCase()}', style: const TextStyle(fontSize: 11)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.call, color: VayaTheme.routeGreen),
                            onPressed: () {},
                          ),
                          IconButton(
                            icon: const Icon(Icons.chat_bubble_outline, color: VayaTheme.liveBlue),
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),

                    const Divider(height: 16),

                    // Security Pickup OTP Box
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PICKUP VERIFICATION OTP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                            Text('Share with driver upon arrival', style: TextStyle(fontSize: 10, color: VayaTheme.slate)),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: VayaTheme.routeGreen.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: VayaTheme.routeGreen, width: 1.5),
                          ),
                          child: Text(
                            _otp.isEmpty ? '849201' : _otp,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: VayaTheme.routeGreen, letterSpacing: 2),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Contextual Action Buttons
                    ElevatedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Live tracking link copied to clipboard!')),
                        );
                      },
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Share Live Tracking Link'),
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

/// 8. Orders History Screen (Orders Tab)
class OrdersScreen extends StatelessWidget {
  final VoidCallback onTrackActive;
  const OrdersScreen({super.key, required this.onTrackActive});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Deliveries'),
          bottom: const TabBar(
            labelColor: VayaTheme.saffron,
            indicatorColor: VayaTheme.saffron,
            tabs: [
              Tab(text: 'Active'),
              Tab(text: 'Completed'),
              Tab(text: 'Cancelled'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // Active Tab
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('#VY-849201', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: VayaTheme.liveBlue.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text('IN TRANSIT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.liveBlue)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('From: Master Canteen Square, Bhubaneswar', style: TextStyle(fontSize: 12, color: VayaTheme.inkBlack)),
                          const Text('To: Infocity Road, Patia, Bhubaneswar', style: TextStyle(fontSize: 12, color: VayaTheme.inkBlack)),
                          const Divider(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Est. Fare: ₹280', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.saffron)),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
                                onPressed: onTrackActive,
                                child: const Text('Track Order', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Completed Tab
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: const [
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(backgroundColor: VayaTheme.signalCream, child: Icon(Icons.check_circle, color: VayaTheme.routeGreen)),
                      title: Text('Delivery #VY-729104', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('Patia -> Saheed Nagar • ₹180'),
                      trailing: Text('Delivered', style: TextStyle(color: VayaTheme.routeGreen, fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),

            // Cancelled Tab
            const Center(
              child: Text('No cancelled orders.', style: TextStyle(color: VayaTheme.slate)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 9. Payments Screen (Payments Tab)
class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payments & Wallet')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: VayaTheme.inkBlack,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('VAYA WALLET BALANCE', style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1.0)),
                    const SizedBox(height: 8),
                    const Text('₹500.00', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: VayaTheme.saffron),
                      onPressed: () {},
                      icon: const Icon(Icons.add),
                      label: const Text('Add Wallet Credits'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('SAVED PAYMENT METHODS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.0, color: VayaTheme.slate)),
            const SizedBox(height: 12),
            const Card(
              child: ListTile(
                leading: Icon(Icons.money, color: VayaTheme.routeGreen),
                title: Text('Cash on Delivery', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('Pay cash to driver upon cargo arrival'),
                trailing: Icon(Icons.check_circle, color: VayaTheme.saffron),
              ),
            ),
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.qr_code, color: VayaTheme.liveBlue),
                title: Text('UPI / Google Pay / PhonePe', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('Instant UPI payment on booking'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 10. Account & Settings Screen (Account Tab)
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('My Account')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: VayaTheme.saffron,
                child: Icon(Icons.person, color: Colors.white),
              ),
              title: Text(user?.displayName ?? 'VAYA Customer', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(user?.phoneNumber ?? '+91 9876543210'),
              trailing: const Icon(Icons.edit, color: VayaTheme.slate),
            ),
          ),
          const SizedBox(height: 20),
          const ListTile(
            leading: Icon(Icons.place, color: VayaTheme.saffron),
            title: Text('Saved Addresses'),
            subtitle: Text('Home, Warehouse, Office'),
            trailing: Icon(Icons.chevron_right),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.business, color: VayaTheme.liveBlue),
            title: Text('Business Profile & GST Billing'),
            subtitle: Text('Add GSTIN for tax invoices'),
            trailing: Icon(Icons.chevron_right),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.help_outline, color: VayaTheme.routeGreen),
            title: Text('Help & 24x7 Customer Support'),
            subtitle: Text('FAQs, Safety & Dispute Assistance'),
            trailing: Icon(Icons.chevron_right),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign Out', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            onTap: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
