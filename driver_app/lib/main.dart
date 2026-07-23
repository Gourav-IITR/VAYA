import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
// Configuration URL - Change to your Cloud Run URL in production
const String apiBaseUrl = "https://vaya-backend-275777907648.us-central1.run.app";
const String wsBaseUrl = "wss://vaya-backend-275777907648.us-central1.run.app";

// VAYA Driver App Theme (Ink Black / Slate / Saffron)
class VayaDriverTheme {
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
      background: inkBlack,
      surface: Color(0xFF1A1A17),
      onPrimary: Colors.white,
      onSurface: signalCream,
      onBackground: signalCream,
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase initialization skipped or already running: $e");
  }
  runApp(const VayaDriverApp());
}

class VayaDriverApp extends StatelessWidget {
  const VayaDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VAYA Driver Partner',
      debugShowCheckedModeBanner: false,
      theme: VayaDriverTheme.themeData,
      home: const DriverAuthWrapper(),
    );
  }
}

class DriverAuthWrapper extends StatefulWidget {
  const DriverAuthWrapper({super.key});

  @override
  State<DriverAuthWrapper> createState() => _DriverAuthWrapperState();
}

class _DriverAuthWrapperState extends State<DriverAuthWrapper> {
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
        Uri.parse('$apiBaseUrl/api/driver/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true) {
            final driver = data['driver'];
            if (driver['is_approved'] == true) {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => DriverHomeScreen(driverData: driver)),
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
        setState(() => _checking = false);
      }
    } catch (e) {
      debugPrint("Driver auth check error: $e");
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: VayaDriverTheme.saffron),
        ),
      );
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
      final token = await user.getIdToken();
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          if (data['exists'] == true) {
            final driver = data['driver'];
            if (driver['is_approved'] == true) {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => DriverHomeScreen(driverData: driver)),
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
        setState(() {
          _isLoading = false;
          _errorMsg = 'Failed to retrieve driver profile.';
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
      appBar: AppBar(title: const Text('VΛYΛ Driver')),
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
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_otpSent ? 'Verify OTP' : 'Send OTP Code'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2. Pending Approval Screen
class PendingApprovalScreen extends StatelessWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              onPressed: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
                );
              },
              child: const Text('Check Status / Re-login'),
            )
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
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final token = await user.getIdToken();
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
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
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
                  value: _vehicleType,
                  dropdownColor: const Color(0xFF1A1A17),
                  style: const TextStyle(color: VayaDriverTheme.signalCream),
                  decoration: const InputDecoration(labelText: 'Vehicle Class'),
                  items: const [
                    DropdownMenuItem(value: 'bike', child: Text('Two-Wheeler (Bike)')),
                    DropdownMenuItem(value: 'three_wheeler', child: Text('Cargo 3-wheeler')),
                    DropdownMenuItem(value: 'ace', child: Text('Mini Truck (4-wheeler)')),
                    DropdownMenuItem(value: 'truck', child: Text('Light Commercial Vehicle (4-wheeler)')),
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
                      ? const CircularProgressIndicator(color: Colors.white)
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

/// 4. Driver Home Screen (Online/Offline Toggle, Map, WS alerts, active job)
class DriverHomeScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverHomeScreen({super.key, required this.driverData});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  bool _isOnline = false;
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  IOWebSocketChannel? _channel;
  StreamSubscription<Position>? _positionSubscription;

  // Active Job states
  Map<String, dynamic>? _activeJob;
  Map<String, dynamic>? _incomingAlert;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      // Show Google Play compliant Prominent Disclosure Dialog before permission request
      final bool? proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: VayaDriverTheme.slate,
            title: const Text(
              'Location Background Usage',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: const Text(
              'VAYA Driver collects location data to find nearby trips and track routes to customers, even when the app is closed or not in use.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Deny', style: TextStyle(color: Colors.redAccent)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.saffron),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Accept & Continue', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      );

      if (proceed != true) return;

      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() {
      _currentPosition = LatLng(pos.latitude, pos.longitude);
    });
  }

  Future<void> _toggleOnline(bool online) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/driver/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'status': online ? 'online' : 'offline',
        }),
      );

      if (response.statusCode == 200) {
        setState(() {
          _isOnline = online;
        });

        if (online) {
          _connectWebSocket();
          _startLocationStreaming();
        } else {
          _disconnectWebSocket();
          _stopLocationStreaming();
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update status. Are you approved?')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection error: $e')),
      );
    }
  }

  void _startLocationStreaming() {
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position pos) async {
      setState(() {
        _currentPosition = LatLng(pos.latitude, pos.longitude);
      });

      // Stream coordinates
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) return;
        final token = await user.getIdToken();

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
    });
  }

  void _stopLocationStreaming() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  void _connectWebSocket() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      _channel = IOWebSocketChannel.connect(
        Uri.parse('$wsBaseUrl/ws?token=$token'),
      );

      _channel!.stream.listen((message) {
        final data = json.decode(message);
        
        if (data['type'] == 'booking_created') {
          final booking = data['booking'];
          if (booking['vehicle_type'] == widget.driverData['vehicle_type'] && _isOnline) {
            // Validate distance <= 3km
            if (_currentPosition != null && booking['pickup_lat'] != null) {
              final double dist = Geolocator.distanceBetween(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
                booking['pickup_lat'],
                booking['pickup_lng'],
              );
              if (dist <= 3000) { 
                setState(() {
                  _incomingAlert = booking;
                });
              }
            }
          }
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

  Future<void> _acceptJob(String bookingId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

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
        setState(() {
          _activeJob = data['booking'];
          _incomingAlert = null;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to accept job. It may have expired or been taken.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accepting job: $e')),
      );
    }
  }

  Future<void> _updateJobStatus(String bookingId, String status) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/booking/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
        body: json.encode({
          'bookingId': bookingId,
          'status': status
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          if (status == 'completed' || status == 'cancelled') {
            _activeJob = null;
          } else {
            _activeJob = data['booking'];
          }
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating status: $e')));
    }
  }

  Future<void> _launchCall(String phoneNo) async {
    final url = Uri.parse('tel:$phoneNo');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  @override
  void dispose() {
    _stopLocationStreaming();
    _disconnectWebSocket();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.driverData['name'] ?? 'Driver Home'),
        actions: [
          Switch(
            value: _isOnline,
            activeColor: VayaDriverTheme.routeGreen,
            onChanged: _toggleOnline,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Center(
              child: Text(
                _isOnline ? 'ONLINE' : 'OFFLINE',
                style: TextStyle(
                  fontWeight: FontWeight.bold, 
                  color: _isOnline ? VayaDriverTheme.routeGreen : VayaDriverTheme.slate
                ),
              ),
            ),
          )
        ],
      ),
      drawer: Drawer(
        backgroundColor: VayaDriverTheme.inkBlack,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              decoration: const BoxDecoration(
                color: VayaDriverTheme.saffron,
              ),
              accountName: Text(
                widget.driverData['name'] ?? 'Driver Partner',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
              ),
              accountEmail: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vehicle: ${widget.driverData['vehicle_type']?.toUpperCase() ?? ''} (${widget.driverData['vehicle_reg'] ?? ''})',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    FirebaseAuth.instance.currentUser?.phoneNumber ?? '',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ],
              ),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.drive_eta, color: VayaDriverTheme.saffron, size: 36),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home, color: VayaDriverTheme.signalCream),
              title: const Text('Home', style: TextStyle(color: VayaDriverTheme.signalCream)),
              onTap: () => Navigator.pop(context),
            ),
            const Divider(color: VayaDriverTheme.slate),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
              onTap: () async {
                await _toggleOnline(false);
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
                    (route) => false,
                  );
                }
              },
            ),
          ],
        ),
      ),
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _currentPosition!,
                    zoom: 14,
                  ),
                  myLocationEnabled: _isOnline,
                  myLocationButtonEnabled: true,
                  onMapCreated: (c) => _mapController = c,
                ),

                // Incoming Order Card Alert
                if (_incomingAlert != null)
                  Positioned(
                    bottom: 24,
                    left: 16,
                    right: 16,
                    child: Card(
                      color: const Color(0xFF1A1A17),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('New Delivery Near You', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaDriverTheme.signalCream)),
                                IconButton(
                                  icon: const Icon(Icons.close, color: VayaDriverTheme.slate),
                                  onPressed: () => setState(() => _incomingAlert = null),
                                )
                              ],
                            ),
                            const Divider(color: VayaDriverTheme.slate),
                            Text('Pickup: ${_incomingAlert!['pickup_name']}', style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream)),
                            Text('Dropoff: ${_incomingAlert!['dropoff_name']}', style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream)),
                            const SizedBox(height: 6),
                            Text('Weight: ${_incomingAlert!['weight']} kg • Est: ₹${_incomingAlert!['estimated_cost']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron)),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: () => _acceptJob(_incomingAlert!['id']),
                              child: const Text('Accept Delivery Job'),
                            )
                          ],
                        ),
                      ),
                    ),
                  ),

                // Active Job Navigation Panel
                if (_activeJob != null)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1A1A17),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        border: Border(top: BorderSide(color: VayaDriverTheme.slate, width: 1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _activeJob!['status'] == 'accepted' || _activeJob!['status'] == 'arrived_pickup'
                                    ? 'Navigating to Pickup'
                                    : 'Navigating to Dropoff',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaDriverTheme.saffron),
                              ),
                              IconButton(
                                icon: const Icon(Icons.call, color: VayaDriverTheme.routeGreen),
                                onPressed: () => _launchCall(_activeJob!['customer_phone'] ?? '9876543210'),
                              )
                            ],
                          ),
                          const Divider(color: VayaDriverTheme.slate),
                          Text(
                            _activeJob!['status'] == 'accepted' || _activeJob!['status'] == 'arrived_pickup'
                                ? 'Pickup: ${_activeJob!['pickup_name']}'
                                : 'Dropoff: ${_activeJob!['dropoff_name']}',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: VayaDriverTheme.signalCream),
                          ),
                          const SizedBox(height: 16),
                          
                          if (_activeJob!['status'] == 'accepted')
                            ElevatedButton(
                              onPressed: () => _updateJobStatus(_activeJob!['id'], 'arrived_pickup'),
                              child: const Text('Arrived at Pickup Location'),
                            )
                          else if (_activeJob!['status'] == 'arrived_pickup')
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.liveBlue),
                              onPressed: () => _showOtpDialog(_activeJob!['id']),
                              child: const Text('Verify Customer OTP & Load Cargo'),
                            )
                          else if (_activeJob!['status'] == 'dropping_off')
                            ElevatedButton(
                              onPressed: () => _updateJobStatus(_activeJob!['id'], 'arrived_dropoff'),
                              child: const Text('Arrived at Dropoff Location'),
                            )
                          else if (_activeJob!['status'] == 'arrived_dropoff')
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.routeGreen),
                              onPressed: () => _updateJobStatus(_activeJob!['id'], 'completed'),
                              child: const Text('Complete Delivery & Collect Cash'),
                            )
                        ],
                      ),
                    ),
                  )
              ],
            ),
    );
  }

  void _showOtpDialog(String bookingId) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A17),
        title: const Text('Verify Pickup OTP', style: TextStyle(color: VayaDriverTheme.signalCream)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the 6-digit OTP code provided by the sender.', style: TextStyle(color: VayaDriverTheme.signalCream)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLength: 6,
              style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 8),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(hintText: '000000'),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: VayaDriverTheme.slate)),
          ),
          TextButton(
            onPressed: () async {
              try {
                final user = FirebaseAuth.instance.currentUser;
                if (user == null) return;
                final token = await user.getIdToken();

                final res = await http.post(
                  Uri.parse('$apiBaseUrl/api/booking/verify-pickup'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer $token'
                  },
                  body: json.encode({
                    'bookingId': bookingId,
                    'otp': controller.text.trim()
                  }),
                );

                if (res.statusCode == 200) {
                  final data = json.decode(res.body);
                  Navigator.pop(ctx);
                  setState(() {
                    _activeJob = data['booking'];
                  });
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid code. Please try again.')),
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Verification error: $e')));
              }
            },
            child: const Text('Verify & Start Trip', style: TextStyle(color: VayaDriverTheme.saffron, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }
}
