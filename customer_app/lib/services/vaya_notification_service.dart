import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

/// Background FCM handler when app is terminated or in background
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    debugPrint('[FCM Background] Handling background message: ${message.messageId}');
  } catch (e) {
    debugPrint('[FCM Background] Error initializing Firebase: $e');
  }
}

class VayaNotificationService {
  static final VayaNotificationService instance = VayaNotificationService._internal();
  factory VayaNotificationService() => instance;
  VayaNotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  Function(String bookingId)? _onOpenDeliveryScreen;
  bool _isInitialized = false;

  /// Initialize FCM and Local Notifications
  Future<void> initialize({
    required Function(String bookingId) onOpenDeliveryScreen,
    String? apiBaseUrl,
    Future<String?> Function()? getAuthToken,
  }) async {
    if (_isInitialized) return;
    _onOpenDeliveryScreen = onOpenDeliveryScreen;

    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    } catch (e) {
      debugPrint('[FCM] Background handler registration skipped/failed: $e');
    }

    // 1. Initialize Local Notifications Plugin
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(android: androidSettings, iOS: darwinSettings);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final bookingId = response.payload;
        if (bookingId != null && bookingId.isNotEmpty) {
          debugPrint('[Notification Tap] Tapped local notification for booking: $bookingId');
          _onOpenDeliveryScreen?.call(bookingId);
        }
      },
    );

    // 2. Create High-Priority Android Channel
    const androidChannel = AndroidNotificationChannel(
      'order_updates',
      'Order Status Updates',
      description: 'Real-time notifications for active VAYA shipment orders',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    final androidPlatform = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlatform != null) {
      await androidPlatform.createNotificationChannel(androidChannel);
    }

    // 3. Request FCM Permissions
    try {
      final messaging = FirebaseMessaging.instance;
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      debugPrint('[FCM] Notification authorization status: ${settings.authorizationStatus}');

      // 4. Fetch & Register FCM Token with Backend
      final token = await messaging.getToken();
      if (token != null && apiBaseUrl != null && getAuthToken != null) {
        await _registerFcmToken(token, apiBaseUrl, getAuthToken);
      }

      messaging.onTokenRefresh.listen((newToken) {
        if (apiBaseUrl != null && getAuthToken != null) {
          _registerFcmToken(newToken, apiBaseUrl, getAuthToken);
        }
      });
    } catch (e) {
      debugPrint('[FCM] Error requesting FCM permissions / fetching token: $e');
    }

    // 5. Handle Foreground FCM Messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('[FCM Foreground] Received message: ${message.data}');
      _showLocalNotification(message);
    });

    // 6. Handle Background Notification Tap (when app is opened via notification tap)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final bookingId = message.data['bookingId'] ?? message.data['booking_id'] ?? '';
      debugPrint('[FCM Tap] App opened from background notification for booking: $bookingId');
      if (bookingId.isNotEmpty) {
        _onOpenDeliveryScreen?.call(bookingId.toString());
      }
    });

    // 7. Check if app was launched from terminated state via notification tap
    try {
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        final bookingId = initialMessage.data['bookingId'] ?? initialMessage.data['booking_id'] ?? '';
        debugPrint('[FCM Launch] App launched from terminated state via notification for booking: $bookingId');
        if (bookingId.isNotEmpty) {
          Future.delayed(const Duration(milliseconds: 500), () {
            _onOpenDeliveryScreen?.call(bookingId.toString());
          });
        }
      }
    } catch (e) {
      debugPrint('[FCM Launch] Error checking initial message: $e');
    }

    _isInitialized = true;
    debugPrint('[VayaNotificationService] Initialized successfully.');
  }

  /// Register FCM Token with Customer Profile API
  Future<void> _registerFcmToken(
    String fcmToken,
    String apiBaseUrl,
    Future<String?> Function() getAuthToken,
  ) async {
    try {
      final authToken = await getAuthToken();
      if (authToken == null) return;

      final res = await http.put(
        Uri.parse('$apiBaseUrl/api/customer/profile'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: json.encode({'fcmToken': fcmToken}),
      );

      if (res.statusCode == 200) {
        debugPrint('[FCM] Token registered with server successfully.');
      } else {
        debugPrint('[FCM] Failed to register token: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('[FCM] Error registering token with backend: $e');
    }
  }

  /// Display a local notification with a stable notification ID per booking
  void _showLocalNotification(RemoteMessage message) {
    final notification = message.notification;
    final data = message.data;

    final title = notification?.title ?? data['title'] ?? 'VAYA Order Update';
    final body = notification?.body ?? data['body'] ?? '';
    final bookingId = data['bookingId'] ?? data['booking_id'] ?? '';

    // Stable Notification ID: Hash of bookingId ensures new status updates replace old ones
    final int notificationId = bookingId.toString().isNotEmpty 
        ? (bookingId.toString().hashCode.abs() % 2147483647) 
        : 1001;

    final androidDetails = AndroidNotificationDetails(
      'order_updates',
      'Order Status Updates',
      channelDescription: 'Real-time notifications for active VAYA shipment orders',
      importance: Importance.max,
      priority: Priority.high,
      tag: bookingId.toString().isNotEmpty ? 'booking_$bookingId' : null,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'VAYA Delivery Update',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    _localNotifications.show(
      notificationId,
      title,
      body,
      details,
      payload: bookingId.toString(),
    );
  }
}
