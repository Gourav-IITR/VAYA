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
  String get deleteAccount => _t('Delete account', 'ଖାତା ବିଲୋପ', 'खाता हटाएं');
  String get signOut => _t('Sign out', 'ସାଇନ୍ ଆଉଟ୍', 'साइन आउट');
  String get signOutConfirm => _t('Sign out of VAYA?', 'VAYA ରୁ ସାଇନ୍ ଆଉଟ୍ କରିବେ?', 'VAYA से साइन आउट करें?');
  String get chooseLanguage => _t('Choose language', 'ଭାଷା ଚୟନ କରନ୍ତୁ', 'भाषा चुनें');
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
  bool _fetchingCurrentLocation = false;
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

  Future<Map<String, dynamic>?> _geocodeAddress(String address) async {
    final url = 'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(address)}&limit=1';
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'Accept-Language': 'en', 'User-Agent': 'VAYACustomerApp/1.0'},
      );
      if (res.statusCode == 200) {
        final List<dynamic> data = json.decode(res.body);
        if (data.isNotEmpty) {
          return {
            'lat': double.parse(data[0]['lat'] as String),
            'lon': double.parse(data[0]['lon'] as String),
            'display_name': data[0]['display_name'] as String,
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
        // Reverse geocode
        final url = 'https://nominatim.openstreetmap.org/reverse?format=json&lat=${pos.latitude}&lon=${pos.longitude}';
        String address = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
        try {
          final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'VAYACustomerApp/1.0'});
          if (res.statusCode == 200) {
            final data = json.decode(res.body);
            address = data['display_name'] ?? address;
          }
        } catch (_) {}
        if (mounted) {
          Navigator.pop(context, {
            'address': address,
            'coords': LatLng(pos.latitude, pos.longitude),
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied. Please enable it in Settings.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Current location error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not determine your location. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _fetchingCurrentLocation = false);
    }
  }

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
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final viewbox = '85.70,20.40,85.95,20.20';
      final url = 'https://nominatim.openstreetmap.org/search?format=json&addressdetails=1&q=${Uri.encodeComponent(query)}&viewbox=$viewbox&limit=8';
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
                final outside = (lat < 20.15 || lat > 20.45 || lon < 85.65 || lon > 85.98);
                // Build a short name from address details if available
                final addr = d['address'] as Map<String, dynamic>?;
                String shortName = '';
                if (addr != null) {
                  shortName = addr['amenity'] ?? addr['building'] ?? addr['road'] ?? addr['neighbourhood'] ?? '';
                }
                if (shortName.isEmpty) {
                  final fullName = d['display_name'] as String;
                  shortName = fullName.split(',').first.trim();
                }
                return {
                  'display_name': d['display_name'] as String,
                  'short_name': shortName,
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
    final l = LocalizedStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isPickup ? l.selectPickup : l.selectDropoff),
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
                hintText: l.searchPlaceholder,
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

          // Use my current location tile
          ListTile(
            leading: CircleAvatar(
              backgroundColor: VayaTheme.liveBlue.withValues(alpha: 0.15),
              child: _fetchingCurrentLocation
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VayaTheme.liveBlue))
                  : const Icon(Icons.my_location, color: VayaTheme.liveBlue, size: 20),
            ),
            title: Text(
              _fetchingCurrentLocation ? l.fetchingLocation : l.useMyCurrentLocation,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.liveBlue),
            ),
            subtitle: Text(
              isPickup ? 'Set pickup to your GPS position' : 'Set drop-off to your GPS position',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _fetchingCurrentLocation ? null : _useCurrentLocation,
          ),
          const Divider(height: 1),

          // Map Picker quick tile
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: VayaTheme.saffron,
              child: Icon(Icons.map, color: Colors.white, size: 20),
            ),
            title: Text(l.chooseOnMap, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                  Text(l.noMatchingPlaces, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                  final shortName = p['short_name'] as String? ?? '';
                  final fullName = p['display_name'] as String;
                  // Build a secondary line from fullName minus shortName
                  String secondary = fullName;
                  if (shortName.isNotEmpty && fullName.startsWith(shortName)) {
                    secondary = fullName.substring(shortName.length).replaceFirst(RegExp(r'^,\s*'), '');
                  }

                  return ListTile(
                    leading: Icon(
                      outside ? Icons.location_off_outlined : Icons.location_on_outlined,
                      color: outside ? Colors.red : VayaTheme.saffron,
                    ),
                    title: Row(
                      children: [
                        if (outside)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Outside area', style: TextStyle(fontSize: 8, color: Colors.red, fontWeight: FontWeight.bold)),
                          ),
                        Expanded(
                          child: Text(
                            shortName.isNotEmpty ? shortName : fullName.split(',').first,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      secondary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: VayaTheme.slate),
                    ),
                    onTap: () {
                      Navigator.pop(context, {
                        'address': fullName,
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
                        Text(l.savedLocations, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                        TextButton.icon(
                          onPressed: _addSavedPlace,
                          icon: const Icon(Icons.add, size: 12),
                          label: Text(l.addNew, style: const TextStyle(fontSize: 11)),
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
                              color: VayaTheme.slate.withValues(alpha: 0.1),
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
                      onTap: () async {
                        // Geocode the saved address to get real coordinates
                        final geo = await _geocodeAddress('${sp['subtitle']}, Bhubaneswar');
                        if (mounted) {
                          Navigator.pop(context, {
                            'address': sp['subtitle']!,
                            'coords': geo != null
                                ? LatLng(geo['lat'], geo['lon'])
                                : widget.currentLocation,
                          });
                        }
                      },
                    );
                  }),
                  const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(l.recentSearches, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                  ),
                  ..._recentSearches.map((rs) => ListTile(
                        leading: const Icon(Icons.history, color: VayaTheme.slate),
                        title: Text(rs['title']!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        subtitle: Text(rs['subtitle']!, style: const TextStyle(fontSize: 11)),
                        onTap: () async {
                          // Geocode recent search address to get real coordinates
                          final geo = await _geocodeAddress('${rs['subtitle']}, Bhubaneswar');
                          if (mounted) {
                            Navigator.pop(context, {
                              'address': rs['subtitle']!,
                              'coords': geo != null
                                  ? LatLng(geo['lat'], geo['lon'])
                                  : widget.currentLocation,
                            });
                          }
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
    final l = LocalizedStrings.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: VayaTheme.slate.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      l.helpMeChooseTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.helpMeChooseSubtitle,
                      style: const TextStyle(fontSize: 12, color: VayaTheme.slate),
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
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
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

class _TrackingScreenState extends State<TrackingScreen> with SingleTickerProviderStateMixin {
  IOWebSocketChannel? _channel;
  GoogleMapController? _mapController;
  late AnimationController _pulseController;

  String _status = "searching"; // searching, driver_assigned, arrived_pickup, loading, in_transit, arrived_drop, completed
  String _driverName = "Searching nearby drivers...";
  String _driverPlate = "-";
  String _driverPhone = "";
  String _otp = "";
  double _estimatedCost = 0.0;
  String _vehicleType = "bike";
  bool _isCancelling = false;
  DateTime _searchStartTime = DateTime.now();
  Timer? _searchTimer;
  String _elapsedText = '0:00';

  LatLng _pickupPos = const LatLng(20.2961, 85.8245);
  LatLng _dropPos = const LatLng(20.3150, 85.8178);
  LatLng? _driverPos;
  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _searchStartTime = DateTime.now();
    _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'searching') {
        final elapsed = DateTime.now().difference(_searchStartTime);
        setState(() {
          _elapsedText = '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
        });
      }
    });
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
              _driverPhone = booking['driver_phone'] ?? "+919876543210";
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
            _mapController?.animateCamera(CameraUpdate.newLatLng(_driverPos!));
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

  Future<void> _cancelBooking() async {
    final l = LocalizedStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.cancelConfirmTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text(l.cancelConfirmMsg, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.close),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.cancelBooking, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isCancelling = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final token = await user.getIdToken();
        await http.delete(
          Uri.parse('$apiBaseUrl/api/booking/${widget.bookingId}'),
          headers: {'Authorization': 'Bearer $token'},
        );
      }
    } catch (e) {
      debugPrint('Cancel booking error: $e');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Booking cancelled successfully.')),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
        (route) => false,
      );
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _searchTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizedStrings.of(context);
    final isSearching = _status == 'searching';

    return Scaffold(
      appBar: AppBar(
        title: Text('Booking #${widget.bookingId.substring(0, 8).toUpperCase()}'),
        actions: [
          if (isSearching || _status == 'driver_assigned')
            IconButton(
              icon: const Icon(Icons.cancel_outlined, color: Colors.red),
              tooltip: l.cancelBooking,
              onPressed: _isCancelling ? null : _cancelBooking,
            ),
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

          // Searching state overlay
          if (isSearching)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Card(
                color: Colors.white,
                elevation: 8,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Pulsing search animation
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          final scale = 1.0 + (_pulseController.value * 0.3);
                          final opacity = 1.0 - _pulseController.value;
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: VayaTheme.saffron.withValues(alpha: opacity * 0.3),
                                  ),
                                ),
                              ),
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: VayaTheme.saffron.withValues(alpha: 0.15),
                                ),
                                child: const Icon(Icons.local_shipping, color: VayaTheme.saffron, size: 28),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.searchingDrivers,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: VayaTheme.inkBlack),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Elapsed: $_elapsedText',
                        style: const TextStyle(fontSize: 12, color: VayaTheme.slate),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Est. Fare: ₹${_estimatedCost.toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.saffron),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _isCancelling ? null : _cancelBooking,
                          icon: _isCancelling
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.close, size: 18),
                          label: Text(_isCancelling ? 'Cancelling...' : l.cancelBooking),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Driver assigned / in-transit status card
          if (!isSearching)
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
                              color: VayaTheme.saffron.withValues(alpha: 0.15),
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
                            '${l.estimatedFare}: ₹${_estimatedCost.toStringAsFixed(0)}',
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
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Calling driver at ${_driverPhone.isEmpty ? "+919876543210" : _driverPhone}...')),
                                );
                              },
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
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.pickupVerificationOtp, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.slate)),
                              Text(l.shareWithDriver, style: const TextStyle(fontSize: 10, color: VayaTheme.slate)),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: VayaTheme.routeGreen.withValues(alpha: 0.1),
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

                      // Action buttons row
                      Row(
                        children: [
                          if (_status == 'driver_assigned')
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isCancelling ? null : _cancelBooking,
                                icon: const Icon(Icons.close, size: 16),
                                label: Text(l.cancelBooking, style: const TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: const BorderSide(color: Colors.red),
                                ),
                              ),
                            ),
                          if (_status == 'driver_assigned') const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Live tracking link copied to clipboard!')),
                                );
                              },
                              icon: const Icon(Icons.share, size: 16),
                              label: Text(l.shareTracking, style: const TextStyle(fontSize: 12)),
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
/// 9. Payments Screen (Payments Tab)
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  int _walletBalance = 500;
  String _defaultPayment = 'Cash'; // 'Wallet', 'UPI', 'Cash'
  final ScrollController _scrollController = ScrollController();

  final List<Map<String, dynamic>> _transactions = [
    {
      'title': 'Wallet Top-up',
      'reference': 'TXN-984021',
      'amount': 500,
      'isCredit': true,
      'date': '24 Jul 2026',
    },
    {
      'title': 'Refund booking #VY-729104',
      'reference': 'TXN-729104R',
      'amount': 180,
      'isCredit': true,
      'date': '22 Jul 2026',
    },
    {
      'title': 'Payment for booking #VY-729104',
      'reference': 'TXN-729104',
      'amount': -180,
      'isCredit': false,
      'date': '22 Jul 2026',
    },
  ];

  void _addMoneyDialog() {
    int selectedAmount = 500;
    final customController = TextEditingController();
    String step = 'input'; // 'input', 'processing', 'success'
    String selectedSource = 'UPI'; // 'UPI', 'Card', 'NetBanking'
    String txnRef = '';

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
            if (step == 'processing') {
              return Container(
                padding: const EdgeInsets.all(24),
                height: 250,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: VayaTheme.saffron),
                    SizedBox(height: 20),
                    Text('Processing top-up...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    SizedBox(height: 6),
                    Text('Please do not close or navigate away', style: TextStyle(fontSize: 12, color: VayaTheme.slate)),
                  ],
                ),
              );
            }

            if (step == 'success') {
              return Container(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircleAvatar(
                      backgroundColor: VayaTheme.routeGreen,
                      radius: 30,
                      child: Icon(Icons.check, color: Colors.white, size: 36),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Added ₹$selectedAmount successfully!',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text('Reference: $txnRef', style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Back to payments', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Add money to wallet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Quick add amounts
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [200, 500, 1000].map((amt) {
                        final isSel = selectedAmount == amt;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0),
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: isSel ? VayaTheme.saffron.withValues(alpha: 0.15) : Colors.white,
                                side: BorderSide(color: isSel ? VayaTheme.saffron : VayaTheme.slate.withValues(alpha: 0.3)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                              ),
                              onPressed: () {
                                setModalState(() {
                                  selectedAmount = amt;
                                  customController.clear();
                                });
                              },
                              child: Text('₹$amt', style: TextStyle(fontWeight: FontWeight.bold, color: isSel ? VayaTheme.saffron : VayaTheme.inkBlack)),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    // Custom amount input
                    TextField(
                      controller: customController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Enter custom amount (₹)',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (val) {
                        final parsed = int.tryParse(val);
                        if (parsed != null) {
                          setModalState(() {
                            selectedAmount = parsed;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('Funding source', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: VayaTheme.slate)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedSource,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'UPI', child: Text('UPI / Google Pay / PhonePe')),
                        DropdownMenuItem(value: 'Card', child: Text('Credit / Debit Card')),
                        DropdownMenuItem(value: 'NetBanking', child: Text('Net Banking')),
                      ],
                      onChanged: (val) {
                        setModalState(() {
                          selectedSource = val!;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: VayaTheme.signalCream,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('• Wallet credits cover full bookings and shipping fare.', style: TextStyle(fontSize: 10, color: VayaTheme.slate)),
                          Text('• Non-withdrawable closed-loop credits. Expire in 1 year.', style: TextStyle(fontSize: 10, color: VayaTheme.slate)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VayaTheme.saffron,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: selectedAmount <= 0
                          ? null
                          : () {
                              setModalState(() {
                                step = 'processing';
                              });
                              Future.delayed(const Duration(seconds: 1), () {
                                final ref = 'TXN-${(100000 + (900000 * (selectedAmount % 7) / 7)).round()}';
                                setState(() {
                                  _walletBalance += selectedAmount;
                                  _transactions.insert(0, {
                                    'title': 'Wallet Top-up',
                                    'reference': ref,
                                    'amount': selectedAmount,
                                    'isCredit': true,
                                    'date': '25 Jul 2026',
                                  });
                                });
                                setModalState(() {
                                  step = 'success';
                                  txnRef = ref;
                                });
                              });
                            },
                      child: Text('Confirm Add ₹$selectedAmount', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showInfoDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 12))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Compact Wallet Card
            Card(
              color: VayaTheme.inkBlack,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('VAYA WALLET', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                            const SizedBox(height: 4),
                            Text('₹$_walletBalance', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        Row(
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: VayaTheme.saffron,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: _addMoneyDialog,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add money', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Non-withdrawable credits', style: TextStyle(color: Colors.white54, fontSize: 10)),
                        InkWell(
                          onTap: () {
                            _scrollController.animateTo(
                              _scrollController.position.maxScrollExtent - 150,
                              duration: const Duration(milliseconds: 500),
                              curve: Curves.easeOut,
                            );
                          },
                          child: const Row(
                            children: [
                              Text('View activity', style: TextStyle(color: VayaTheme.saffron, fontSize: 11, fontWeight: FontWeight.bold)),
                              SizedBox(width: 4),
                              Icon(Icons.arrow_downward, color: VayaTheme.saffron, size: 12),
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

            // Default payment method section
            const Text('Default payment method', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            // Wallet option
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: _defaultPayment == 'Wallet' ? VayaTheme.saffron : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: RadioListTile<String>(
                value: 'Wallet',
                groupValue: _defaultPayment,
                activeColor: VayaTheme.saffron,
                title: Row(
                  children: [
                    const Text('VAYA Wallet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: VayaTheme.saffron.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('₹$_walletBalance', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: VayaTheme.saffron)),
                    ),
                  ],
                ),
                subtitle: const Text('Fastest checkout using wallet credits', style: TextStyle(fontSize: 11)),
                onChanged: _walletBalance <= 0 ? null : (val) => setState(() => _defaultPayment = val!),
              ),
            ),
            const SizedBox(height: 6),
            // UPI option
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: _defaultPayment == 'UPI' ? VayaTheme.saffron : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: RadioListTile<String>(
                value: 'UPI',
                groupValue: _defaultPayment,
                activeColor: VayaTheme.saffron,
                title: const Text('UPI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('Pay using any UPI app (GPay, PhonePe, Paytm)', style: TextStyle(fontSize: 11)),
                onChanged: (val) => setState(() => _defaultPayment = val!),
              ),
            ),
            const SizedBox(height: 6),
            // Cash option
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: _defaultPayment == 'Cash' ? VayaTheme.saffron : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: RadioListTile<String>(
                value: 'Cash',
                groupValue: _defaultPayment,
                activeColor: VayaTheme.saffron,
                title: const Text('Cash', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('Pay driver in cash after delivery completion', style: TextStyle(fontSize: 11)),
                onChanged: (val) => setState(() => _defaultPayment = val!),
              ),
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Text(
                'Note: Selected method is pre-filled on booking. You can always change it before placing the order.',
                style: TextStyle(fontSize: 10, color: VayaTheme.slate),
              ),
            ),
            const SizedBox(height: 16),

            // Recent activity section
            const Text('Recent activity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            _transactions.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Text('No transaction history.', style: TextStyle(color: VayaTheme.slate, fontSize: 12)),
                    ),
                  )
                : Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _transactions.length,
                      separatorBuilder: (ctx, i) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final tx = _transactions[i];
                        final isCr = tx['isCredit'] as bool;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isCr ? Colors.green.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1),
                            child: Icon(
                              isCr ? Icons.arrow_downward : Icons.arrow_upward,
                              color: isCr ? Colors.green : Colors.red,
                              size: 16,
                            ),
                          ),
                          title: Text(tx['title'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          subtitle: Text('${tx['date']} • Ref: ${tx['reference']}', style: const TextStyle(fontSize: 10, color: VayaTheme.slate)),
                          trailing: Text(
                            '${isCr ? "+" : ""}₹${tx['amount']}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: isCr ? Colors.green : Colors.red,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
            const SizedBox(height: 24),

            // Footer Links
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => _showInfoDialog('Wallet Terms & Conditions', '• VAYA Wallet is a closed-loop wallet.\n• Wallet balance can be used for booking fare.\n• Balance is non-withdrawable and non-transferable.\n• Promotional credits expire in 30 days.'),
                  child: const Text('Wallet terms', style: TextStyle(fontSize: 11, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
                TextButton(
                  onPressed: () => _showInfoDialog('Refund Rules', '• Order cancellations receive full refund instantly if cancelled before driver arrives.\n• Refund returns automatically to the original source.\n• Promo/discount codes are single-use and cannot be refunded.'),
                  child: const Text('Refund rules', style: TextStyle(fontSize: 11, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
                TextButton(
                  onPressed: () => _showInfoDialog('Payment Support', 'For support or queries regarding failed transactions, contact VAYA support at support@vaya.com or dial +91-1800-VAYA.'),
                  child: const Text('Failed payments?', style: TextStyle(fontSize: 11, color: VayaTheme.saffron, decoration: TextDecoration.underline)),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
  String _name = 'Gourav Mahunta';
  String _phone = '+91 98765 43210';
  String _email = 'gourav@vaya.com';
  bool _phoneVerified = true;

  String _gstin = '21AAAAA1111A1Z1'; 
  String _gstStatus = 'Verified'; // 'Not added', 'Pending', 'Verified'
  String _companyName = 'VAYA Logistics Pvt Ltd';

  bool _notificationsEnabled = true;
  String _appLanguage = 'English';

  final List<Map<String, String>> _addresses = [
    {'label': 'Main Warehouse', 'details': 'Plot B, Chandaka Industrial Estate, Patia, Bhubaneswar', 'default': 'pickup'},
    {'label': 'Janpath Retail Store', 'details': 'Plot 102, Janpath Road, Saheed Nagar, Bhubaneswar', 'default': 'dropoff'},
    {'label': 'Secondary Supplier', 'details': 'Unit 4 Market Complex, Bhubaneswar', 'default': 'none'},
    {'label': 'Default Office', 'details': 'Infocity Road, Patia, Bhubaneswar', 'default': 'none'},
  ];

  void _editProfileDialog() {
    final nameCtrl = TextEditingController(text: _name);
    final phoneCtrl = TextEditingController(text: _phone);
    final emailCtrl = TextEditingController(text: _email);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Full Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(labelText: 'Phone Number'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(labelText: 'Email Address'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                setState(() {
                  _name = nameCtrl.text;
                  _phone = phoneCtrl.text;
                  _email = emailCtrl.text;
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

  void _addressManagerDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Saved addresses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  TextButton.icon(
                    onPressed: () {
                      setModalState(() {
                        _addresses.add({
                          'label': 'New Location',
                          'details': 'Plot 5, VIP Area, Bhubaneswar',
                          'default': 'none',
                        });
                      });
                      setState(() {});
                    },
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _addresses.length,
                  separatorBuilder: (c, i) => const Divider(),
                  itemBuilder: (c, i) {
                    final addr = _addresses[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(addr['label']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      subtitle: Text(addr['details']!, style: const TextStyle(fontSize: 10)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (addr['default'] != 'none')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: VayaTheme.saffron.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                addr['default'] == 'pickup' ? 'Pickup' : 'Drop-off',
                                style: const TextStyle(fontSize: 8, color: VayaTheme.saffron, fontWeight: FontWeight.bold),
                              ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                            onPressed: () {
                              setModalState(() {
                                _addresses.removeAt(i);
                              });
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
              ],
            );
          },
        );
      },
    );
  }

  void _gstDialog() {
    final companyCtrl = TextEditingController(text: _companyName);
    final gstinCtrl = TextEditingController(text: _gstin);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Business & tax details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: companyCtrl,
                decoration: const InputDecoration(labelText: 'Registered business name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: gstinCtrl,
                decoration: const InputDecoration(labelText: 'GSTIN (15-digit code)'),
              ),
              const SizedBox(height: 8),
              Text(
                'Current status: $_gstStatus',
                style: TextStyle(
                  fontSize: 11,
                  color: _gstStatus == 'Verified' ? Colors.green : Colors.amber,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _gstin = '';
                  _companyName = '';
                  _gstStatus = 'Not added';
                });
                Navigator.pop(ctx);
              },
              child: const Text('Remove GSTIN', style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () {
                final gstText = gstinCtrl.text.trim();
                if (gstText.length == 15) {
                  setState(() {
                    _gstin = gstText;
                    _companyName = companyCtrl.text;
                    _gstStatus = 'Verified';
                  });
                } else {
                  setState(() {
                    _gstin = gstText;
                    _companyName = companyCtrl.text;
                    _gstStatus = 'Pending verification';
                  });
                }
                Navigator.pop(ctx);
              },
              child: const Text('Save & Verify', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showHelpCenter() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help Centre', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Q: How is distance calculated?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              Text('A: Distance is computed along the routing path from Bhubaneswar map servers.\n', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
              Text('Q: Can I load fragile goods?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              Text('A: Yes, select Helper options for assistance, and add remarks for fragile handling.\n', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
              Text('Q: How do refunds work?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              Text('A: Cancellations made before driver assignment are refunded instantly to your original payment method.\n', style: TextStyle(fontSize: 11, color: VayaTheme.slate)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showContactSupport() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contact support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Our 24x7 operations helpline is active for active delivery issues and disputes.', style: TextStyle(fontSize: 12)),
            SizedBox(height: 12),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Helpline dialed: 1800-102-VAYA')),
              );
            },
            child: const Text('Call support', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat initialized. Driver details loaded.')),
              );
            },
            child: const Text('Chat now', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showDisputes() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Active cases & disputes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Case ID: #DISP-89201', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Text('Issue: Driver refund delay', style: TextStyle(fontSize: 11)),
            Text('Status: Under investigation (expected closure 24 hrs)', style: TextStyle(fontSize: 11, color: Colors.amber, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _confirmSignOut() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out of VAYA?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: const Text('Active bookings will remain in transit and will not be cancelled. Do you want to sign out on this device?', style: TextStyle(fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await FirebaseAuth.instance.signOut();
              if (mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
            child: const Text('Sign out', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 12))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Profile Card (Whole card is tappable to edit)
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _editProfileDialog,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 24,
                        backgroundColor: VayaTheme.saffron,
                        child: Icon(Icons.person, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_name.isEmpty ? 'Add your name' : _name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VayaTheme.inkBlack)),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(_phone, style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                                if (_phoneVerified) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.verified, size: 11, color: VayaTheme.liveBlue),
                                ],
                              ],
                            ),
                            if (_email.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(_email, style: const TextStyle(fontSize: 11, color: VayaTheme.slate)),
                            ],
                          ],
                        ),
                      ),
                      const Icon(Icons.edit, size: 16, color: VayaTheme.slate),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Logistics Section
            const Text('Logistics', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                leading: const SizedBox(width: 24, child: Icon(Icons.place_outlined, color: VayaTheme.slate)),
                title: const Text('Saved addresses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text('${_addresses.length} saved warehouse, office and shop locations', style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: _addressManagerDialog,
              ),
            ),
            const SizedBox(height: 16),

            // Business & Billing Section
            const Text('Business & billing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                leading: const SizedBox(width: 24, child: Icon(Icons.business_outlined, color: VayaTheme.slate)),
                title: const Text('Business & tax details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text('Status: $_gstStatus • Click to edit details', style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: _gstDialog,
              ),
            ),
            const SizedBox(height: 16),

            // Preferences Section
            const Text('Preferences', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [
                  SwitchListTile(
                    value: _notificationsEnabled,
                    activeColor: VayaTheme.saffron,
                    title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Enabled for dispatch and transit alerts', style: TextStyle(fontSize: 11)),
                    onChanged: (val) => setState(() => _notificationsEnabled = val),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.language, color: VayaTheme.slate)),
                    title: Text(LocalizedStrings.of(context).appLanguage, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text('Current: $_appLanguage', style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => SimpleDialog(
                          title: Text(LocalizedStrings.of(context).chooseLanguage, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          children: [
                            SimpleDialogOption(
                              onPressed: () {
                                Navigator.pop(ctx);
                                setState(() => _appLanguage = 'English');
                                context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('en'));
                              },
                              child: Row(
                                children: [
                                  if (_appLanguage == 'English') const Icon(Icons.check_circle, color: VayaTheme.saffron, size: 20) else const Icon(Icons.radio_button_unchecked, size: 20, color: VayaTheme.slate),
                                  const SizedBox(width: 12),
                                  const Text('English', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                ],
                              ),
                            ),
                            SimpleDialogOption(
                              onPressed: () {
                                Navigator.pop(ctx);
                                setState(() => _appLanguage = 'ଓଡ଼ିଆ (Odia)');
                                context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('or'));
                              },
                              child: Row(
                                children: [
                                  if (_appLanguage.contains('Odia')) const Icon(Icons.check_circle, color: VayaTheme.saffron, size: 20) else const Icon(Icons.radio_button_unchecked, size: 20, color: VayaTheme.slate),
                                  const SizedBox(width: 12),
                                  const Text('ଓଡ଼ିଆ (Odia)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                ],
                              ),
                            ),
                            SimpleDialogOption(
                              onPressed: () {
                                Navigator.pop(ctx);
                                setState(() => _appLanguage = 'हिन्दी (Hindi)');
                                context.findAncestorStateOfType<_VayaCustomerAppState>()?.setLocale(const Locale('hi'));
                              },
                              child: Row(
                                children: [
                                  if (_appLanguage.contains('Hindi')) const Icon(Icons.check_circle, color: VayaTheme.saffron, size: 20) else const Icon(Icons.radio_button_unchecked, size: 20, color: VayaTheme.slate),
                                  const SizedBox(width: 12),
                                  const Text('हिन्दी (Hindi)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Help & Safety Section
            const Text('Help & safety', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.help_center_outlined, color: VayaTheme.slate)),
                    title: const Text('Help centre', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Browse FAQs and shipping guidelines', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: _showHelpCenter,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.support_agent_outlined, color: VayaTheme.slate)),
                    title: const Text('Contact support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('24x7 Chat, helpline and callback options', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: _showContactSupport,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.gavel_outlined, color: VayaTheme.slate)),
                    title: const Text('Disputes & refund cases', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Track refund case status and updates', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: _showDisputes,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Privacy & Legal Section
            const Text('Privacy & legal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: VayaTheme.slate)),
            const SizedBox(height: 8),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.security, color: VayaTheme.slate)),
                    title: const Text('Privacy policy & terms', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Read our data and grievance practices', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      _showInfoDialog('Privacy policy & terms', 'VAYA values your data privacy. We collect geo-coordinates solely for route calculation and delivery dispatch tracking. Read the full document at https://vaya.com/privacy-policy.');
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.download, color: VayaTheme.slate)),
                    title: const Text('Download my data', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text('Export a copy of your bookings and billing ledger', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Data export initiated. Check your email.')),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const SizedBox(width: 24, child: Icon(Icons.delete_forever, color: Colors.red)),
                    title: const Text('Delete account', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.red)),
                    subtitle: const Text('Permanently remove profile and billing records', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete your VAYA account?', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 15)),
                          content: const Text('Warning: This action is permanent. Deleting your account will remove your wallet credits, booking history, and business profile. Proceed?', style: TextStyle(fontSize: 12)),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Account deletion requested. Account deactivated.')),
                                );
                              },
                              child: const Text('Confirm Deletion', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Sign out row
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                leading: const SizedBox(width: 24, child: Icon(Icons.logout, color: Colors.red)),
                title: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.red)),
                onTap: _confirmSignOut,
              ),
            ),
            const SizedBox(height: 24),

            // App version footer
            const Center(
              child: Text(
                'VAYA Customer • Version 1.4.2 (Build 20260725)',
                style: TextStyle(fontSize: 10, color: VayaTheme.slate),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
