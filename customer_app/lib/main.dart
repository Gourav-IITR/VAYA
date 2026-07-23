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
// Configuration URL - Change to your Cloud Run URL in production
const String apiBaseUrl = "https://vaya-backend-275777907648.us-central1.run.app";
const String wsBaseUrl = "wss://vaya-backend-275777907648.us-central1.run.app";

// VAYA Brand Design Tokens
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
    colorScheme: ColorScheme.fromSeed(
      seedColor: saffron,
      primary: saffron,
      secondary: slate,
      background: signalCream,
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
      title: 'VAYA',
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
              MaterialPageRoute(builder: (_) => const HomeScreen()),
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
  String get bike => locale.languageCode == 'or' ? 'ବାଇକ୍' : locale.languageCode == 'hi' ? 'बाइक' : 'Bike';
  String get miniTruck => locale.languageCode == 'or' ? 'ମିନି ଟ୍ରକ୍ (ଟାଟା ଏସି)' : locale.languageCode == 'hi' ? 'मिनी ट्रक (टाटा एस)' : 'Mini Truck (Tata Ace)';
  String get largeTruck => locale.languageCode == 'or' ? 'ବଡ଼ ଟ୍ରକ୍ (ଟାଟା ୪୦୭)' : locale.languageCode == 'hi' ? 'बड़ा ट्रक (टाटा 407)' : 'Large Truck (Tata 407)';
  String get bookNow => locale.languageCode == 'or' ? 'ବୁକିଂ କରନ୍ତୁ' : locale.languageCode == 'hi' ? 'बुकिंग करें' : 'Book a VAYA';
  String get tracking => locale.languageCode == 'or' ? 'ବୁକିଂ ଟ୍ରାକ୍' : locale.languageCode == 'hi' ? 'ଟ୍ରାକିଂ' : 'Track VAYA';
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
              // Stylized V symbol instead of translation icon
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
              MaterialPageRoute(builder: (_) => const HomeScreen()),
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
            MaterialPageRoute(builder: (_) => const HomeScreen()),
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

/// 4. Booking Map Selection Screen
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LatLng _pickup = const LatLng(20.2961, 85.8245); // Master Canteen
  LatLng _dropoff = const LatLng(20.3150, 85.8178); // Patia
  final Set<Marker> _markers = {};
  GoogleMapController? _mapController;

  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  String _searchFieldType = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _updateMarkers();
    _initDefaultAddresses();
    _locateUserPosition();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _initDefaultAddresses() async {
    final pAddr = await getAddressFromCoords(_pickup.latitude, _pickup.longitude);
    final dAddr = await getAddressFromCoords(_dropoff.latitude, _dropoff.longitude);
    if (mounted) {
      setState(() {
        _pickupController.text = pAddr;
        _dropoffController.text = dAddr;
      });
    }
  }

  Future<void> _locateUserPosition() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        final coords = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _pickup = coords;
          _updateMarkers();
        });
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(coords, 14));
        
        final addr = await getAddressFromCoords(pos.latitude, pos.longitude);
        setState(() {
          _pickupController.text = addr;
        });
      }
    } catch (e) {
      debugPrint("Could not retrieve current location: $e");
    }
  }

  Future<String> getAddressFromCoords(double lat, double lng) async {
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
        return data['display_name'] ?? '(${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})';
      }
    } catch (e) {
      debugPrint("Reverse geocoding error: $e");
    }
    return '(${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})';
  }

  Future<List<Map<String, dynamic>>> searchLocations(String query) async {
    if (query.trim().length < 2) return [];
    final viewbox = '85.70,20.40,85.95,20.20';
    final url = 'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&viewbox=$viewbox&bounded=1&limit=6';
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept-Language': 'en',
          'User-Agent': 'VAYACustomerApp/1.0 (com.vaya.customer_app)',
        },
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((d) => {
          'display_name': d['display_name'] as String,
          'lat': double.parse(d['lat'] as String),
          'lon': double.parse(d['lon'] as String),
        }).toList();
      }
    } catch (e) {
      debugPrint("Autocomplete search error: $e");
    }
    return [];
  }

  void _onSearchChanged(String query, String type) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      if (query.trim().length < 2) {
        setState(() {
          _searchResults.clear();
        });
        return;
      }
      final results = await searchLocations(query);
      setState(() {
        _searchFieldType = type;
        _searchResults = results;
      });
    });
  }

  void _updateMarkers() {
    setState(() {
      _markers.clear();
      _markers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: _pickup,
        infoWindow: const InfoWindow(title: 'Pickup Point'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ));
      _markers.add(Marker(
        markerId: const MarkerId('dropoff'),
        position: _dropoff,
        infoWindow: const InfoWindow(title: 'Dropoff Point'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VΛYΛ'),
      ),
      drawer: Drawer(
        backgroundColor: VayaTheme.signalCream,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              decoration: const BoxDecoration(
                color: VayaTheme.saffron,
              ),
              accountName: Text(
                FirebaseAuth.instance.currentUser?.displayName ?? 'VAYA Customer',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              accountEmail: Text(
                FirebaseAuth.instance.currentUser?.phoneNumber ?? '',
                style: const TextStyle(fontSize: 14),
              ),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, color: VayaTheme.saffron, size: 36),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home, color: VayaTheme.inkBlack),
              title: const Text('Home'),
              onTap: () => Navigator.pop(context),
            ),
            const Divider(color: VayaTheme.fog),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
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
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        foregroundColor: VayaTheme.saffron,
        onPressed: _locateUserPosition,
        child: const Icon(Icons.gps_fixed),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: GoogleMap(
                  initialCameraPosition: const CameraPosition(
                    target: LatLng(20.2961, 85.8245),
                    zoom: 12,
                  ),
                  markers: _markers,
                  myLocationButtonEnabled: false,
                  onMapCreated: (c) => _mapController = c,
                  onTap: (latLng) async {
                    if (_markers.length < 2) {
                      _dropoff = latLng;
                      final addr = await getAddressFromCoords(latLng.latitude, latLng.longitude);
                      setState(() => _dropoffController.text = addr);
                    } else {
                      _pickup = latLng;
                      final addr = await getAddressFromCoords(latLng.latitude, latLng.longitude);
                      setState(() => _pickupController.text = addr);
                    }
                    _updateMarkers();
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: VayaTheme.signalCream,
                  border: Border(top: BorderSide(color: VayaTheme.fog, width: 1)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VehicleSelectionScreen(pickup: _pickup, dropoff: _dropoff),
                          ),
                        );
                      },
                      child: const Text('Next: Choose Vehicle'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Search Locations Float Card
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.white,
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextField(
                      controller: _pickupController,
                      style: const TextStyle(fontSize: 14, color: VayaTheme.inkBlack),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.location_on, color: VayaTheme.saffron),
                        hintText: 'Search Pickup Location (From)',
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.gps_fixed, color: VayaTheme.saffron),
                          onPressed: _locateUserPosition,
                        ),
                      ),
                      onChanged: (val) => _onSearchChanged(val, 'pickup'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _dropoffController,
                      style: const TextStyle(fontSize: 14, color: VayaTheme.inkBlack),
                      decoration: const InputDecoration(
                        prefixIcon: const Icon(Icons.flag, color: Colors.red),
                        hintText: 'Search Dropoff Location (To)',
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      onChanged: (val) => _onSearchChanged(val, 'dropoff'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Search Results Dropdown List
          if (_searchResults.isNotEmpty)
            Positioned(
              top: 150,
              left: 16,
              right: 16,
              child: Card(
                color: Colors.white,
                elevation: 6,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 250),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    itemBuilder: (ctx, index) {
                      final res = _searchResults[index];
                      return ListTile(
                        leading: const Icon(Icons.location_city, color: VayaTheme.slate),
                        title: Text(
                          res['display_name'] ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: VayaTheme.inkBlack),
                        ),
                        onTap: () {
                          setState(() {
                            final coords = LatLng(res['lat'], res['lon']);
                            if (_searchFieldType == 'pickup') {
                              _pickup = coords;
                              _pickupController.text = res['display_name'];
                            } else {
                              _dropoff = coords;
                              _dropoffController.text = res['display_name'];
                            }
                            _updateMarkers();
                            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(coords, 14));
                            _searchResults.clear();
                          });
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 4b. Vehicle Selection Screen
class VehicleSelectionScreen extends StatefulWidget {
  final LatLng pickup;
  final LatLng dropoff;
  const VehicleSelectionScreen({super.key, required this.pickup, required this.dropoff});

  @override
  State<VehicleSelectionScreen> createState() => _VehicleSelectionScreenState();
}

class _VehicleSelectionScreenState extends State<VehicleSelectionScreen> {
  String _selectedVehicle = 'bike';
  bool _isLoading = false;
  List<dynamic> _serverPricing = [];
  bool _loadingPricing = true;

  @override
  void initState() {
    super.initState();
    _fetchPricingConfig();
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
      debugPrint("Failed to load live pricing: $e");
      setState(() => _loadingPricing = false);
    }
  }

  double _calculatePrice(String vehicleId) {
    final double dist = Geolocator.distanceBetween(
      widget.pickup.latitude,
      widget.pickup.longitude,
      widget.dropoff.latitude,
      widget.dropoff.longitude,
    ) / 1000.0; // Distance in km

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

          return basePrice + (dist > baseDistance ? (dist - baseDistance) * perKmPrice : 0.0);
        }
      } catch (e) {
        debugPrint("Error parsing match: $e");
      }
    }

    switch (vehicleId) {
      case 'bike':
        // Base ₹40 (first 2 km) + ₹10/km
        return 40.0 + (dist > 2 ? (dist - 2) * 10.0 : 0.0);
      case 'three_wheeler':
        // Base ₹120 (first 3 km) + ₹18/km
        return 120.0 + (dist > 3 ? (dist - 3) * 18.0 : 0.0);
      case 'ace':
        // Base ₹250 (first 5 km) + ₹25/km
        return 250.0 + (dist > 5 ? (dist - 5) * 25.0 : 0.0);
      case 'truck':
        // Base ₹500 (first 5 km) + ₹35/km
        return 500.0 + (dist > 5 ? (dist - 5) * 35.0 : 0.0);
      default:
        return 50.0;
    }
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
          'pickupName': 'Selected Pickup Coordinates',
          'pickupLat': widget.pickup.latitude,
          'pickupLng': widget.pickup.longitude,
          'dropoffName': 'Selected Dropoff Coordinates',
          'dropoffLat': widget.dropoff.latitude,
          'dropoffLng': widget.dropoff.longitude,
          'vehicleType': _selectedVehicle,
          'weight': 10,
          'estimatedCost': estimatedCost
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
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dist = Geolocator.distanceBetween(
      widget.pickup.latitude,
      widget.pickup.longitude,
      widget.dropoff.latitude,
      widget.dropoff.longitude,
    ) / 1000.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Vehicle'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.location_on, color: VayaTheme.saffron),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Pickup: (${widget.pickup.latitude.toStringAsFixed(4)}, ${widget.pickup.longitude.toStringAsFixed(4)})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.flag, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Dropoff: (${widget.dropoff.latitude.toStringAsFixed(4)}, ${widget.dropoff.longitude.toStringAsFixed(4)})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.inkBlack),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Text(
                      'Distance: ${dist.toStringAsFixed(2)} km',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.liveBlue),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'SELECT VEHICLE CLASS',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2, color: VayaTheme.slate),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _loadingPricing 
                  ? const Center(child: CircularProgressIndicator(color: VayaTheme.saffron))
                  : ListView(
                      children: [
                        _buildVehicleOption(
                          id: 'bike',
                          name: 'Bike',
                          desc: 'Quick deliveries up to 20 kg',
                          price: '₹${_calculatePrice('bike').toStringAsFixed(2)}',
                          icon: Icons.motorcycle,
                        ),
                        const SizedBox(height: 12),
                        _buildVehicleOption(
                          id: 'three_wheeler',
                          name: 'Cargo 3-wheeler',
                          desc: 'Medium cargo up to 150 kg',
                          price: '₹${_calculatePrice('three_wheeler').toStringAsFixed(2)}',
                          icon: Icons.moped,
                        ),
                        const SizedBox(height: 12),
                        _buildVehicleOption(
                          id: 'ace',
                          name: 'Mini Truck (4-wheeler)',
                          desc: 'Heavy cargo up to 600 kg',
                          price: '₹${_calculatePrice('ace').toStringAsFixed(2)}',
                          icon: Icons.local_shipping,
                        ),
                        const SizedBox(height: 12),
                        _buildVehicleOption(
                          id: 'truck',
                          name: 'Light Commercial Vehicle (4-wheeler)',
                          desc: 'Very heavy cargo up to 2,000 kg',
                          price: '₹${_calculatePrice('truck').toStringAsFixed(2)}',
                          icon: Icons.fire_truck,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _handleBooking,
              child: _isLoading 
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : const Text('Book a VAYA'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleOption({
    required String id,
    required String name,
    required String desc,
    required String price,
    required IconData icon,
  }) {
    final isSelected = _selectedVehicle == id;
    return InkWell(
      onTap: () => setState(() => _selectedVehicle = id),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? VayaTheme.saffron : VayaTheme.fog,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
          color: isSelected ? Colors.white : Colors.transparent,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected ? VayaTheme.saffron.withOpacity(0.1) : VayaTheme.fog.withOpacity(0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: isSelected ? VayaTheme.saffron : VayaTheme.slate),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isSelected ? VayaTheme.inkBlack : VayaTheme.slate,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                  ),
                ],
              ),
            ),
            Text(
              price,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: isSelected ? VayaTheme.saffron : VayaTheme.inkBlack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 5. Live Tracking Screen (Updates automatically via WebSocket channels)
class TrackingScreen extends StatefulWidget {
  final String bookingId;
  const TrackingScreen({super.key, required this.bookingId});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  IOWebSocketChannel? _channel;
  GoogleMapController? _mapController;
  
  String _status = "Searching for drivers...";
  String _driverName = "Waiting to assign...";
  String _driverPlate = "-";
  String _otp = "";
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
            _otp = booking['otp'];
            if (booking['driver_id'] != null) {
              _driverName = booking['driver_name'] ?? "Assigned Delivery Partner";
              _driverPlate = booking['driver_plate'] ?? "";
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch initial booking info: $e");
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
            _status = 'accepted';
            _driverName = b['driver_name'] ?? 'Assigned Partner';
            _driverPlate = b['driver_plate'] ?? '';
          });
        } else if (data['type'] == 'booking_transit' && data['bookingId'] == widget.bookingId) {
          setState(() => _status = 'dropping_off');
        } else if (data['type'] == 'booking_status' && data['bookingId'] == widget.bookingId) {
          setState(() => _status = data['status']);
          if (data['status'] == 'completed') {
            _closeAndExit('Delivery completed successfully!');
          } else if (data['status'] == 'cancelled') {
            _closeAndExit('Delivery was cancelled.');
          }
        } else if (data['type'] == 'driver_position' && _status != 'completed') {
          final lat = data['lat'];
          final lng = data['lng'];
          setState(() {
            _driverPos = LatLng(lat, lng);
            _markers.clear();
            _markers.add(Marker(
              markerId: const MarkerId('driver'),
              position: _driverPos!,
              infoWindow: const InfoWindow(title: 'Live Driver Position'),
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            ));
          });
          _mapController?.animateCamera(CameraUpdate.newLatLng(_driverPos!));
        }
      });
    } catch (e) {
      debugPrint("WebSocket stream failed: $e");
    }
  }

  void _closeAndExit(String message) {
    _channel?.sink.close();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final str = LocalizedStrings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(str.tracking)),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(
                target: LatLng(20.2961, 85.8245),
                zoom: 13,
              ),
              markers: _markers,
              onMapCreated: (c) => _mapController = c,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: VayaTheme.signalCream,
              border: Border(top: BorderSide(color: VayaTheme.fog, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'STATUS: ${_status.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 16, 
                    fontWeight: FontWeight.w800, 
                    color: VayaTheme.liveBlue,
                    letterSpacing: 1.2
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: VayaTheme.fog,
                      child: Icon(Icons.person, color: VayaTheme.inkBlack)
                    ),
                    title: Text(_driverName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('PLATE: $_driverPlate', style: const TextStyle(fontSize: 11, letterSpacing: 0.5)),
                    trailing: IconButton(
                      icon: const Icon(Icons.call, color: VayaTheme.routeGreen),
                      onPressed: () {},
                    ),
                  ),
                ),
                const Divider(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('VERIFICATION OTP', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1, fontSize: 12, color: VayaTheme.slate)),
                    Text(_otp, style: const TextStyle(fontSize: 22, color: VayaTheme.routeGreen, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Provide this secure OTP code to the driver upon cargo pickup.', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
              ],
            ),
          )
        ],
      ),
    );
  }
}
