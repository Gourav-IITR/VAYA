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
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
                  initialValue: _vehicleType,
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
    _checkActiveJob();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached || state == AppLifecycleState.paused) {
      _setOfflineOnClose();
    }
  }

  Future<void> _setOfflineOnClose() async {
    // If driver is not in an active job, mark status offline when app is closed/detached
    if (_activeJob == null) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) return;
        final token = await user.getIdToken();
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
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/booking/active'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['exists'] == true) {
          setState(() {
            _activeJob = data['booking'];
          });
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
  }

  @override
  Widget build(BuildContext context) {
    // If an active trip is underway, switch to a full-screen operational trip flow (hiding bottom navigation)
    if (_activeJob != null) {
      return ActiveTripWorkflowScreen(
        driverData: widget.driverData,
        activeJob: _activeJob!,
        onJobUpdated: (updated) => _onJobStateChanged(updated),
      );
    }

    final pages = [
      DriverHomeScreen(driverData: widget.driverData, onJobAccepted: (job) => _onJobStateChanged(job)),
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
        backgroundColor: const Color(0xFF1A1A17),
        selectedItemColor: VayaDriverTheme.saffron,
        unselectedItemColor: VayaDriverTheme.slate,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.local_shipping_outlined), activeIcon: Icon(Icons.local_shipping), label: 'Trips'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet_outlined), activeIcon: Icon(Icons.account_balance_wallet), label: 'Earnings'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: 'Account'),
        ],
      ),
    );
  }
}

/// 5. Driver Home Dashboard Screen
class DriverHomeScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  final Function(Map<String, dynamic>) onJobAccepted;

  const DriverHomeScreen({super.key, required this.driverData, required this.onJobAccepted});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  bool _isOnline = false;
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  IOWebSocketChannel? _channel;
  StreamSubscription<Position>? _positionSubscription;

  Map<String, dynamic>? _incomingAlert;
  double _todayEarnings = 0.0;
  int _completedTripsCount = 0;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static const int _onlineNotificationId = 888;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _fetchTodayEarnings();
    _checkLocationPermission();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);

    final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
    }
  }

  Future<void> _fetchTodayEarnings() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/today-earnings'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['success'] == true) {
          setState(() {
            _todayEarnings = (data['todayEarnings'] as num).toDouble();
          });
          if (_isOnline) {
            _updateOnlineNotification();
          }
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
      ongoing: true, // Persistent in drawer
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
      'VAYA Partner is Online 🟢',
      'Active & ready for orders | Today\'s Earnings: $earningsText',
      notificationDetails,
    );
  }

  Future<void> _cancelOnlineNotification() async {
    await _notificationsPlugin.cancel(_onlineNotificationId);
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      final bool? proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A17),
            title: const Row(
              children: [
                Icon(Icons.location_on, color: VayaDriverTheme.saffron),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Location Permission Required',
                    style: TextStyle(color: VayaDriverTheme.signalCream, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
              ],
            ),
            content: const Text(
              'VAYA Partner collects location data to enable real-time order tracking and ETA updates for customers even when the app is closed or not in use.',
              style: TextStyle(color: VayaDriverTheme.signalCream, height: 1.5),
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
    }

    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return;
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    setState(() {
      _currentPosition = LatLng(pos.latitude, pos.longitude);
    });
  }

  Future<void> _toggleOnline(bool online) async {
    if (online) {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        await _checkLocationPermission();
        perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      }
    }

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
          _updateOnlineNotification();
        } else {
          _disconnectWebSocket();
          _stopLocationStreaming();
          _cancelOnlineNotification();
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
            if (_currentPosition != null && booking['pickup_lat'] != null) {
              final double dist = Geolocator.distanceBetween(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
                booking['pickup_lat'],
                booking['pickup_lng'],
              );
              if (dist <= 5000) { 
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
        final acceptedJob = data['booking'];
        setState(() {
          _incomingAlert = null;
        });
        widget.onJobAccepted(acceptedJob);
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

  @override
  void dispose() {
    _stopLocationStreaming();
    _disconnectWebSocket();
    _cancelOnlineNotification();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.driverData['name'] ?? 'Driver Dashboard'),
      ),
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator(color: VayaDriverTheme.saffron))
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(target: _currentPosition!, zoom: 14),
                  myLocationEnabled: _isOnline,
                  myLocationButtonEnabled: true,
                  onMapCreated: (c) => _mapController = c,
                ),

                // Top Dashboard Cards (Online Switch & Today's Earnings Summary)
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: Column(
                    children: [
                      // Online / Offline Switch Card
                      Card(
                        color: const Color(0xFF1A1A17),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: _isOnline ? VayaDriverTheme.routeGreen : VayaDriverTheme.slate,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _isOnline ? 'YOU ARE ONLINE' : 'YOU ARE OFFLINE',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: _isOnline ? VayaDriverTheme.routeGreen : VayaDriverTheme.signalCream,
                                    ),
                                  ),
                                ],
                              ),
                              Switch(
                                value: _isOnline,
                                activeTrackColor: VayaDriverTheme.routeGreen,
                                onChanged: _toggleOnline,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Today's Earnings Summary Card
                      Card(
                        color: const Color(0xFF1A1A17),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                children: [
                                  const Text("TODAY'S EARNINGS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                                  const SizedBox(height: 4),
                                  Text("₹${_todayEarnings.toStringAsFixed(0)}", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: VayaDriverTheme.saffron)),
                                ],
                              ),
                              Container(height: 30, width: 1, color: VayaDriverTheme.slate),
                              Column(
                                children: [
                                  const Text("COMPLETED TRIPS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                                  const SizedBox(height: 4),
                                  Text("$_completedTripsCount", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: VayaDriverTheme.signalCream)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Incoming Order Overlay Request Card
                if (_incomingAlert != null)
                  Positioned(
                    bottom: 24,
                    left: 16,
                    right: 16,
                    child: Card(
                      color: const Color(0xFF1A1A17),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: const BorderSide(color: VayaDriverTheme.saffron, width: 2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: VayaDriverTheme.saffron.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('NEW CARGO REQUEST', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaDriverTheme.saffron)),
                                ),
                                Text(
                                  '₹${_incomingAlert!['estimated_cost']}',
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: VayaDriverTheme.saffron),
                                ),
                              ],
                            ),
                            const Divider(color: VayaDriverTheme.slate, height: 24),
                            Text('Pickup: ${_incomingAlert!['pickup_name']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.signalCream)),
                            const SizedBox(height: 4),
                            Text('Dropoff: ${_incomingAlert!['dropoff_name']}', style: const TextStyle(fontSize: 14, color: VayaDriverTheme.signalCream)),
                            const SizedBox(height: 8),
                            Text('Cargo Weight: ${_incomingAlert!['weight']} kg', style: const TextStyle(fontSize: 12, color: VayaDriverTheme.signalCream)),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                                    onPressed: () => setState(() => _incomingAlert = null),
                                    child: const Text('Reject', style: TextStyle(color: Colors.red)),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: ElevatedButton(
                                    onPressed: () => _acceptJob(_incomingAlert!['id']),
                                    child: const Text('ACCEPT TRIP'),
                                  ),
                                ),
                              ],
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
  final TextEditingController _otpController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _job = widget.activeJob;
  }

  Future<void> _updateStatus(String newStatus) async {
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
          'bookingId': _job['id'],
          'status': newStatus
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (newStatus == 'completed' || newStatus == 'cancelled') {
          widget.onJobUpdated(null);
        } else {
          setState(() {
            _job = data['booking'];
          });
          widget.onJobUpdated(_job);
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _verifyOtp() async {
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
          'bookingId': _job['id'],
          'otp': _otpController.text.trim()
        }),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          _job = data['booking'];
        });
        widget.onJobUpdated(_job);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid OTP code. Please try again.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Verification error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _job['status'] ?? 'accepted';

    return Scaffold(
      appBar: AppBar(
        title: Text('Trip #${_job['id'].toString().substring(0, 8).toUpperCase()}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.call, color: VayaDriverTheme.routeGreen),
            onPressed: () async {
              final url = Uri.parse('tel:9876543210');
              if (await canLaunchUrl(url)) await launchUrl(url);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  double.parse(_job['pickup_lat']?.toString() ?? '20.2961'),
                  double.parse(_job['pickup_lng']?.toString() ?? '85.8245'),
                ),
                zoom: 14,
              ),
            ),
          ),
          Container(
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
                      status == 'accepted' ? 'NAVIGATE TO PICKUP' : (status == 'dropping_off' ? 'NAVIGATE TO DROPOFF' : status.toUpperCase()),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaDriverTheme.saffron),
                    ),
                    Text('Fare: ₹${_job['estimated_cost']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: VayaDriverTheme.signalCream)),
                  ],
                ),
                const Divider(color: VayaDriverTheme.slate, height: 20),
                Text('Pickup: ${_job['pickup_name']}', style: const TextStyle(fontSize: 13, color: VayaDriverTheme.signalCream)),
                const SizedBox(height: 4),
                Text('Dropoff: ${_job['dropoff_name']}', style: const TextStyle(fontSize: 13, color: VayaDriverTheme.signalCream)),
                const SizedBox(height: 16),

                if (status == 'accepted') ...[
                  ElevatedButton(
                    onPressed: () => _updateStatus('arrived_pickup'),
                    child: const Text('Arrived at Pickup Location'),
                  ),
                ] else if (status == 'arrived_pickup') ...[
                  TextField(
                    controller: _otpController,
                    maxLength: 6,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(letterSpacing: 8, fontSize: 20, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(labelText: 'Enter Customer Pickup OTP'),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.liveBlue),
                    onPressed: _verifyOtp,
                    child: const Text('Verify OTP & Start Trip'),
                  ),
                ] else if (status == 'dropping_off') ...[
                  ElevatedButton(
                    onPressed: () => _updateStatus('arrived_dropoff'),
                    child: const Text('Arrived at Dropoff Location'),
                  ),
                ] else if (status == 'arrived_dropoff') ...[
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: VayaDriverTheme.routeGreen),
                    onPressed: () => _updateStatus('completed'),
                    child: const Text('Complete Delivery & Collect Cash'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 7. Driver Trips History Screen (Trips Tab)
class DriverTripsScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverTripsScreen({super.key, required this.driverData});

  @override
  State<DriverTripsScreen> createState() => _DriverTripsScreenState();
}

class _DriverTripsScreenState extends State<DriverTripsScreen> {
  bool _isLoading = true;
  List<dynamic> _trips = [];

  @override
  void initState() {
    super.initState();
    _fetchTrips();
  }

  Future<void> _fetchTrips() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/trips'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['success'] == true) {
          setState(() {
            _trips = data['trips'] ?? [];
            _isLoading = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Error fetching driver trips: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final completedTrips = _trips.where((t) => t['status'] == 'completed').toList();
    final cancelledTrips = _trips.where((t) => t['status'] == 'cancelled').toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Trip History'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() => _isLoading = true);
                _fetchTrips();
              },
            ),
          ],
          bottom: const TabBar(
            labelColor: VayaDriverTheme.saffron,
            indicatorColor: VayaDriverTheme.saffron,
            tabs: [
              Tab(text: 'Completed'),
              Tab(text: 'Cancelled'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: VayaDriverTheme.saffron))
            : TabBarView(
                children: [
                  _buildTripList(completedTrips, isCompleted: true),
                  _buildTripList(cancelledTrips, isCompleted: false),
                ],
              ),
      ),
    );
  }

  Widget _buildTripList(List<dynamic> list, {required bool isCompleted}) {
    if (list.isEmpty) {
      return Center(
        child: Text(
          isCompleted ? 'No completed trips yet.' : 'No cancelled trips.',
          style: const TextStyle(color: VayaDriverTheme.slate),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final idStr = (item['id']?.toString() ?? '1000').substring(0, 6).toUpperCase();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(
              isCompleted ? Icons.check_circle : Icons.cancel,
              color: isCompleted ? VayaDriverTheme.routeGreen : Colors.red,
            ),
            title: Text('Trip #VY-$idStr', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${item['pickup_name']} ➔ ${item['dropoff_name']}'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₹${item['estimated_cost']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 2),
                Text(
                  isCompleted ? 'Completed' : 'Cancelled',
                  style: TextStyle(
                    color: isCompleted ? VayaDriverTheme.routeGreen : Colors.red,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 8. Driver Earnings & Payouts Screen (Earnings Tab)
class DriverEarningsScreen extends StatefulWidget {
  final Map<String, dynamic> driverData;
  const DriverEarningsScreen({super.key, required this.driverData});

  @override
  State<DriverEarningsScreen> createState() => _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends State<DriverEarningsScreen> {
  bool _isLoading = true;
  double _totalGross = 0.0;
  int _completedCount = 0;
  double _todayGross = 0.0;
  double _platformFee = 0.0;
  double _netEarnings = 0.0;

  @override
  void initState() {
    super.initState();
    _fetchEarningsStats();
  }

  Future<void> _fetchEarningsStats() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();

      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/driver/earnings-stats'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted && data['success'] == true) {
          final stats = data['stats'];
          setState(() {
            _totalGross = (stats['totalGross'] as num).toDouble();
            _completedCount = (stats['completedCount'] as num).toInt();
            _todayGross = (stats['todayGross'] as num).toDouble();
            _platformFee = (stats['platformFee'] as num).toDouble();
            _netEarnings = (stats['netEarnings'] as num).toDouble();
            _isLoading = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Error fetching earnings stats: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Earnings & Payouts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              _fetchEarningsStats();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: VayaDriverTheme.saffron))
          : Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    color: const Color(0xFF1A1A17),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('TOTAL NET EARNINGS', style: TextStyle(color: VayaDriverTheme.signalCream, fontSize: 11, letterSpacing: 1.0)),
                          const SizedBox(height: 8),
                          Text('₹${_netEarnings.toStringAsFixed(2)}', style: const TextStyle(color: VayaDriverTheme.saffron, fontSize: 32, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Total Trips Completed: $_completedCount', style: const TextStyle(color: VayaDriverTheme.signalCream, fontSize: 12)),
                              Text('Today: ₹${_todayGross.toStringAsFixed(0)}', style: const TextStyle(color: VayaDriverTheme.routeGreen, fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('EARNINGS BREAKDOWN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.0, color: VayaDriverTheme.slate)),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.local_taxi, color: VayaDriverTheme.saffron),
                      title: const Text('Trip Gross Fares'),
                      trailing: Text('₹${_totalGross.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.remove_circle_outline, color: Colors.red),
                      title: const Text('Platform Fee (10%)'),
                      trailing: Text('-₹${_platformFee.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                    ),
                  ),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_balance_wallet, color: VayaDriverTheme.routeGreen),
                      title: const Text('Net Balance Credited'),
                      trailing: Text('₹${_netEarnings.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen)),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// 9. Driver Account & Vehicle Settings Screen (Account Tab)
class DriverAccountScreen extends StatelessWidget {
  final Map<String, dynamic> driverData;
  const DriverAccountScreen({super.key, required this.driverData});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Partner Account')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: VayaDriverTheme.inkBlack,
                  border: Border.all(color: Colors.white24, width: 2),
                ),
                child: const Icon(Icons.drive_eta, color: VayaDriverTheme.saffron, size: 32),
              ),
              title: Text(driverData['name'] ?? 'Driver Partner', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Plate: ${driverData['vehicle_reg'] ?? ''} • Class: ${driverData['vehicle_type']?.toString().toUpperCase()}'),
            ),
          ),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.phone, color: VayaDriverTheme.signalCream),
            title: const Text('Phone Number'),
            subtitle: Text(driverData['phone'] ?? user?.phoneNumber ?? 'Not provided'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.fitness_center, color: VayaDriverTheme.signalCream),
            title: const Text('Max Weight Capacity'),
            subtitle: Text('${driverData['weight_capacity'] ?? 20} kg'),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.verified, color: VayaDriverTheme.routeGreen),
            title: Text('Document Verification Status'),
            subtitle: Text('Driving License & Vehicle RC Verified'),
            trailing: Icon(Icons.check_circle, color: VayaDriverTheme.routeGreen),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.account_balance, color: VayaDriverTheme.liveBlue),
            title: Text('Bank Account & Payout Details'),
            subtitle: Text('Direct Bank Transfer (Active)'),
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
                  MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
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
