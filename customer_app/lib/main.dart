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
const String apiBaseUrl = "http://10.0.2.2:5001";
const String wsBaseUrl = "ws://10.0.2.2:5001";

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
        fontWeight: FontWeight.extrabold,
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
    cardTheme: CardTheme(
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
      home: LanguageSelectionScreen(onLanguageSelected: setLocale),
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
                        fontWeight: FontWeight.extrabold,
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
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const HomeScreen()),
            );
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const OnboardingScreen()),
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
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const HomeScreen()),
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
  double _weight = 10;
  String _selectedVehicle = 'bike';
  bool _isLoading = false;
  
  final Set<Marker> _markers = {};
  GoogleMapController? _mapController;

  @override
  void initState() {
    super.initState();
    _updateMarkers();
    _locateUserPosition();
  }

  Future<void> _locateUserPosition() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        setState(() {
          _pickup = LatLng(pos.latitude, pos.longitude);
          _updateMarkers();
        });
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(_pickup, 14));
      }
    } catch (e) {
      debugPrint("Could not retrieve current location: $e");
    }
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

  Future<void> _handleBooking() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final token = await user.getIdToken();
      final estimatedCost = _selectedVehicle == 'bike' ? 50.00 : (_selectedVehicle == 'ace' ? 250.00 : 800.00);
      
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/booking'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'pickupName': 'Selected Pickup Coordinates',
          'pickupLat': _pickup.latitude,
          'pickupLng': _pickup.longitude,
          'dropoffName': 'Selected Dropoff Coordinates',
          'dropoffLat': _dropoff.latitude,
          'dropoffLng': _dropoff.longitude,
          'vehicleType': _selectedVehicle,
          'weight': _weight.round(),
          'estimatedCost': estimatedCost
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TrackingScreen(bookingId: data['booking']['id']),
            ),
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
    final str = LocalizedStrings.of(context);
    bool isBikeOk = _weight <= 20;
    bool isAceOk = _weight <= 500;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VΛYΛ'),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 4,
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: const CameraPosition(
                    target: LatLng(20.2961, 85.8245),
                    zoom: 12,
                  ),
                  markers: _markers,
                  onMapCreated: (c) => _mapController = c,
                  onTap: (latLng) {
                    setState(() {
                      if (_markers.length < 2) {
                        _dropoff = latLng;
                      } else {
                        _pickup = latLng;
                      }
                      _updateMarkers();
                    });
                  },
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  child: Card(
                    color: Colors.white.withOpacity(0.95),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text('TAP MAP TO ADJUST PINS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1, color: VayaTheme.slate)),
                    ),
                  ),
                )
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: VayaTheme.signalCream,
                border: Border(top: BorderSide(color: VayaTheme.fog, width: 1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Weight Limit:', style: TextStyle(fontWeight: FontWeight.bold, color: VayaTheme.inkBlack)),
                      Text('${_weight.round()} kg', style: const TextStyle(color: VayaTheme.saffron, fontWeight: FontWeight.extrabold, fontSize: 16)),
                    ],
                  ),
                  Slider(
                    min: 1,
                    max: 2000,
                    value: _weight,
                    activeColor: VayaTheme.saffron,
                    inactiveColor: VayaTheme.fog,
                    onChanged: (val) {
                      setState(() {
                        _weight = val;
                        if (val > 500) _selectedVehicle = 'truck';
                        else if (val > 20 && _selectedVehicle == 'bike') _selectedVehicle = 'ace';
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('SELECT VEHICLE CLASS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2, color: VayaTheme.slate)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      children: [
                        // Bike Card
                        Expanded(
                          child: InkWell(
                            onTap: isBikeOk ? () => setState(() => _selectedVehicle = 'bike') : null,
                            child: Opacity(
                              opacity: isBikeOk ? 1.0 : 0.3,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: _selectedVehicle == 'bike' ? VayaTheme.saffron : VayaTheme.fog,
                                    width: _selectedVehicle == 'bike' ? 2 : 1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  color: _selectedVehicle == 'bike' ? Colors.white : Colors.transparent,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.motorcycle, size: 28, color: _selectedVehicle == 'bike' ? VayaTheme.saffron : VayaTheme.slate),
                                    const SizedBox(height: 4),
                                    Text(str.bike, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _selectedVehicle == 'bike' ? VayaTheme.inkBlack : VayaTheme.slate)),
                                    const Text('< 20 kg', style: TextStyle(fontSize: 9, color: VayaTheme.slate)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Tata Ace Card
                        Expanded(
                          child: InkWell(
                            onTap: isAceOk ? () => setState(() => _selectedVehicle = 'ace') : null,
                            child: Opacity(
                              opacity: isAceOk ? 1.0 : 0.3,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: _selectedVehicle == 'ace' ? VayaTheme.saffron : VayaTheme.fog,
                                    width: _selectedVehicle == 'ace' ? 2 : 1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  color: _selectedVehicle == 'ace' ? Colors.white : Colors.transparent,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.local_shipping, size: 28, color: _selectedVehicle == 'ace' ? VayaTheme.saffron : VayaTheme.slate),
                                    const SizedBox(height: 4),
                                    Text(str.miniTruck, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _selectedVehicle == 'ace' ? VayaTheme.inkBlack : VayaTheme.slate)),
                                    const Text('< 500 kg', style: TextStyle(fontSize: 9, color: VayaTheme.slate)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Large Truck Card
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _selectedVehicle = 'truck'),
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _selectedVehicle == 'truck' ? VayaTheme.saffron : VayaTheme.fog,
                                  width: _selectedVehicle == 'truck' ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                color: _selectedVehicle == 'truck' ? Colors.white : Colors.transparent,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.fire_truck, size: 28, color: _selectedVehicle == 'truck' ? VayaTheme.saffron : VayaTheme.slate),
                                  const SizedBox(height: 4),
                                  Text(str.largeTruck, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _selectedVehicle == 'truck' ? VayaTheme.inkBlack : VayaTheme.slate)),
                                  const Text('< 2.0 t', style: TextStyle(fontSize: 9, color: VayaTheme.slate)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _handleBooking,
                    child: _isLoading 
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(str.bookNow),
                  ),
                ],
              ),
            ),
          ),
        ],
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
                    fontWeight: FontWeight.extrabold, 
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
