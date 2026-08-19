import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../main.dart'; // Imports VayaDriverTheme, etc.
import '../widgets/vaya_loader.dart';

class DeliverySummaryScreen extends StatefulWidget {
  final String bookingId;
  final Map<String, dynamic> booking;
  final String apiBaseUrl;
  final String? authToken;
  final VoidCallback onCompleted;
  final VoidCallback onViewTripDetails;
  final VoidCallback onReportIssue;

  const DeliverySummaryScreen({
    super.key,
    required this.bookingId,
    required this.booking,
    required this.apiBaseUrl,
    this.authToken,
    required this.onCompleted,
    required this.onViewTripDetails,
    required this.onReportIssue,
  });

  @override
  State<DeliverySummaryScreen> createState() => _DeliverySummaryScreenState();
}

class _DeliverySummaryScreenState extends State<DeliverySummaryScreen> {
  bool _isLoading = true;
  bool _isError = false;
  String _errorMessage = '';
  Map<String, dynamic>? _settlement;

  // Cash confirmation checkbox
  bool _isCashCollectedConfirmed = false;

  // 6-digit OTP fields
  final List<TextEditingController> _otpControllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());
  final ScrollController _scrollController = ScrollController();
  final FocusNode _otpContainerFocusNode = FocusNode();

  bool _isCompleting = false;
  String? _otpError;
  bool _isFareUpdatedAlertShown = false;
  Map<String, dynamic>? _completionReceipt;
  bool _isNotifyingCustomer = false;

  @override
  void initState() {
    super.initState();
    _fetchSettlementSummary();
    for (int i = 0; i < 6; i++) {
      _otpControllers[i].addListener(_onOtpChanged);
    }
  }

  @override
  void dispose() {
    for (var c in _otpControllers) {
      c.dispose();
    }
    for (var f in _otpFocusNodes) {
      f.dispose();
    }
    _scrollController.dispose();
    _otpContainerFocusNode.dispose();
    super.dispose();
  }

  void _onOtpChanged() {
    setState(() {
      _otpError = null;
    });
  }

  Map<String, dynamic> _computeLocalFallbackSettlement(Map<String, dynamic> booking) {
    final baseFare = double.tryParse(booking['estimated_cost']?.toString() ?? '0') ?? 0.0;
    final pickupWaitMins = int.tryParse(booking['pickup_wait_minutes']?.toString() ?? '0') ?? 0;
    final dropoffWaitMins = int.tryParse(booking['dropoff_wait_minutes']?.toString() ?? '0') ?? 0;

    final pickupWaitChargeable = math.max(0, pickupWaitMins - 10);
    final dropoffWaitChargeable = math.max(0, dropoffWaitMins - 10);

    final pickupWaitAmount = (pickupWaitChargeable * 2.0 * 100).round() / 100.0;
    final dropoffWaitAmount = (dropoffWaitChargeable * 2.0 * 100).round() / 100.0;

    final vayaFareTotal = ((baseFare + pickupWaitAmount + dropoffWaitAmount) * 100).round() / 100.0;

    final paymentMethod = (booking['payment_type'] ?? booking['payment_method'] ?? 'cash').toString().toLowerCase();
    final isPickupCash = (booking['cash_collection_point'] == 'PICKUP' || (paymentMethod == 'cash' && booking['cash_collection_point'] != 'DROPOFF'));

    double amountCollectedAtPickup = 0.0;
    if (booking['is_pickup_cash_collected'] == true || isPickupCash) {
      final pAmt = double.tryParse(booking['pickup_amount']?.toString() ?? '');
      amountCollectedAtPickup = pAmt ?? (baseFare + pickupWaitAmount);
    }

    double amountPaidOnline = 0.0;
    if (paymentMethod == 'online' || paymentMethod == 'wallet') {
      amountPaidOnline = baseFare;
    }

    double amountDueNow = math.max(0.0, ((vayaFareTotal - amountCollectedAtPickup - amountPaidOnline) * 100).round() / 100.0);

    String paymentStatus = 'payment_due';
    if (amountDueNow == 0.0) {
      paymentStatus = 'paid';
    } else if (amountCollectedAtPickup > 0 && amountDueNow > 0) {
      paymentStatus = 'partially_paid';
    } else if (booking['support_override_approved'] == true) {
      paymentStatus = 'support_override_approved';
    } else if (paymentMethod == 'online' || paymentMethod == 'wallet') {
      paymentStatus = 'waiting_for_customer_payment';
    }

    final bId = (booking['id'] ?? widget.bookingId).toString();
    final shortId = bId.length >= 8 ? bId.substring(0, 8).toUpperCase() : bId.toUpperCase();

    return {
      'settlementId': booking['settlement_id'] ?? 'SETTLE-$shortId-${DateTime.now().millisecondsSinceEpoch}',
      'bookingId': bId,
      'currency': 'INR',
      'baseFare': baseFare,
      'pickupWait': {
        'totalMinutes': pickupWaitMins,
        'freeMinutes': 10,
        'chargeableMinutes': pickupWaitChargeable,
        'ratePerMinute': 2.0,
        'amount': pickupWaitAmount
      },
      'dropoffWait': {
        'totalMinutes': dropoffWaitMins,
        'freeMinutes': 10,
        'chargeableMinutes': dropoffWaitChargeable,
        'ratePerMinute': 2.0,
        'amount': dropoffWaitAmount
      },
      'vayaFareTotal': vayaFareTotal,
      'paymentMethod': paymentMethod,
      'initialCollectionPoint': isPickupCash ? 'pickup' : (paymentMethod == 'cash' ? 'dropoff' : 'online'),
      'initialPayer': isPickupCash ? 'sender' : (paymentMethod == 'cash' ? 'receiver' : 'booking_customer'),
      'adjustmentPayer': paymentMethod == 'cash' ? 'receiver' : 'customer',
      'amountCollectedAtPickup': amountCollectedAtPickup,
      'amountPaidOnline': amountPaidOnline,
      'amountDueNow': amountDueNow,
      'paymentStatus': paymentStatus,
      'settlementVersion': booking['settlement_version'] ?? 1,
      'tollsParkingIncluded': false,
      'tollsParkingMessage': 'Payable separately at actuals, if applicable',
      'isLocalFallback': true
    };
  }

  Future<void> _fetchSettlementSummary({bool isRefresh = false}) async {
    if (!isRefresh) {
      setState(() {
        _isLoading = true;
        _isError = false;
        _errorMessage = '';
      });
    }

    try {
      final token = widget.authToken ?? await DriverAuthHelper.getAuthToken();
      final url = Uri.parse('${widget.apiBaseUrl}/api/booking/${widget.bookingId}/settlement-summary');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _settlement = data;
          _isLoading = false;
          _isError = false;
        });
      } else {
        // Fallback to local computed settlement summary so driver is NEVER trapped on an error screen
        final fallback = _computeLocalFallbackSettlement(widget.booking);
        setState(() {
          _settlement = fallback;
          _isLoading = false;
          _isError = false;
        });
      }
    } catch (e) {
      final fallback = _computeLocalFallbackSettlement(widget.booking);
      setState(() {
        _settlement = fallback;
        _isLoading = false;
        _isError = false;
      });
    }
  }

  String get _enteredOtp => _otpControllers.map((c) => c.text.trim()).join();

  bool get _isOtpComplete => _enteredOtp.length == 6;

  bool get _canSubmit {
    if (_isLoading || _isCompleting || _settlement == null) return false;
    if (!_isOtpComplete) return false;

    final amountDue = double.tryParse(_settlement!['amountDueNow']?.toString() ?? '0') ?? 0.0;

    if (amountDue > 0) {
      if (!_isCashCollectedConfirmed) return false;
    }

    return true;
  }

  Future<void> _handleOtpSubmit() async {
    if (!_canSubmit) return;

    final amountDue = double.tryParse(_settlement!['amountDueNow']?.toString() ?? '0') ?? 0.0;

    if (amountDue > 0 && _isCashCollectedConfirmed) {
      // Show confirmation dialog before recording cash collection
      final confirmed = await _showCashCollectionConfirmationDialog(amountDue);
      if (!confirmed) return;
    }

    await _executeDeliveryCompletion();
  }

  Future<bool> _showCashCollectionConfirmationDialog(double amount) async {
    final amountStr = amount.toStringAsFixed(0);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.payments, color: VayaDriverTheme.saffron, size: 24),
            SizedBox(width: 10),
            Text(
              'Confirm cash collection',
              style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        content: Text(
          'Confirm only after receiving ₹$amountStr from the receiver.',
          style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFFE2E8F0)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Go back', style: TextStyle(fontFamily: 'Inter', color: Color(0xFF9CA3AF), fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: VayaDriverTheme.saffron,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Confirm ₹$amountStr collected', style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<void> _executeDeliveryCompletion() async {
    setState(() {
      _isCompleting = true;
      _otpError = null;
    });

    try {
      final token = widget.authToken ?? await DriverAuthHelper.getAuthToken();
      final url = Uri.parse('${widget.apiBaseUrl}/api/booking/complete-delivery');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final payload = {
        'bookingId': widget.bookingId,
        'settlementId': _settlement?['settlementId'],
        'settlementVersion': _settlement?['settlementVersion'],
        'otp': _enteredOtp,
        'cashCollectedConfirmed': _isCashCollectedConfirmed,
        'idempotencyKey': 'COMP-${widget.bookingId}-${_settlement?['settlementVersion'] ?? 1}',
      };

      final response = await http.post(url, headers: headers, body: json.encode(payload)).timeout(const Duration(seconds: 15));

      final body = json.decode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && body['success'] == true) {
        setState(() {
          _isCompleting = false;
          _completionReceipt = body['receipt'] as Map<String, dynamic>?;
        });
        _showCompletionReceiptModal();
      } else if (response.statusCode == 409 || body['code'] == 'SETTLEMENT_CHANGED') {
        setState(() {
          _isCompleting = false;
        });
        _showFareUpdatedDialog();
      } else if (response.statusCode == 404) {
        // Fallback to legacy completion route (/api/booking/status) if complete-delivery endpoint is not yet on server
        final fallbackUrl = Uri.parse('${widget.apiBaseUrl}/api/booking/status');
        final fallbackResponse = await http.post(
          fallbackUrl,
          headers: headers,
          body: json.encode({
            'bookingId': widget.bookingId,
            'status': 'completed',
            'otp': _enteredOtp,
          }),
        ).timeout(const Duration(seconds: 15));

        final fallbackBody = json.decode(fallbackResponse.body) as Map<String, dynamic>;
        if (fallbackResponse.statusCode == 200 && fallbackBody['success'] == true) {
          setState(() {
            _isCompleting = false;
            _completionReceipt = {
              'bookingId': widget.bookingId,
              'vayaFareTotal': _settlement?['vayaFareTotal'] ?? 0,
              'amountCollectedAtPickup': _settlement?['amountCollectedAtPickup'] ?? 0,
              'amountPaidOnline': _settlement?['amountPaidOnline'] ?? 0,
              'amountDueNow': _settlement?['amountDueNow'] ?? 0,
              'paymentStatus': _settlement?['paymentStatus'] ?? 'paid',
              'settlementId': _settlement?['settlementId'] ?? 'SETTLE-LOCAL',
            };
          });
          _showCompletionReceiptModal();
        } else {
          final errText = fallbackBody['error']?.toString() ?? 'Completion failed. Invalid OTP or server error.';
          setState(() {
            _isCompleting = false;
            _otpError = errText;
          });
        }
      } else {
        final errText = body['error']?.toString() ?? 'Completion failed. Please verify details.';
        setState(() {
          _isCompleting = false;
          _otpError = errText;
        });
      }
    } catch (e) {
      // Emergency catch fallback
      try {
        final token = widget.authToken ?? await DriverAuthHelper.getAuthToken();
        final fallbackUrl = Uri.parse('${widget.apiBaseUrl}/api/booking/status');
        final headers = <String, String>{
          'Content-Type': 'application/json',
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        };
        final fallbackResponse = await http.post(
          fallbackUrl,
          headers: headers,
          body: json.encode({
            'bookingId': widget.bookingId,
            'status': 'completed',
            'otp': _enteredOtp,
          }),
        ).timeout(const Duration(seconds: 15));

        final fallbackBody = json.decode(fallbackResponse.body) as Map<String, dynamic>;
        if (fallbackResponse.statusCode == 200 && fallbackBody['success'] == true) {
          setState(() {
            _isCompleting = false;
            _completionReceipt = {
              'bookingId': widget.bookingId,
              'vayaFareTotal': _settlement?['vayaFareTotal'] ?? 0,
              'amountCollectedAtPickup': _settlement?['amountCollectedAtPickup'] ?? 0,
              'amountPaidOnline': _settlement?['amountPaidOnline'] ?? 0,
              'amountDueNow': _settlement?['amountDueNow'] ?? 0,
              'paymentStatus': _settlement?['paymentStatus'] ?? 'paid',
              'settlementId': _settlement?['settlementId'] ?? 'SETTLE-LOCAL',
            };
          });
          _showCompletionReceiptModal();
          return;
        }
      } catch (_) {}

      setState(() {
        _isCompleting = false;
        _otpError = 'Network error during completion. Please check your connection and retry.';
      });
    }
  }

  void _showFareUpdatedDialog() {
    if (_isFareUpdatedAlertShown) return;
    _isFareUpdatedAlertShown = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFF39C12), size: 24),
            SizedBox(width: 10),
            Text('Fare updated', style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        content: const Text(
          'Waiting charges or payment status changed. Review the updated summary before completing the delivery.',
          style: TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFFE2E8F0)),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: VayaDriverTheme.saffron,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              _isFareUpdatedAlertShown = false;
              setState(() {
                _isCashCollectedConfirmed = false;
              });
              _fetchSettlementSummary(isRefresh: true);
            },
            child: const Text('Review updated fare', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showCompletionReceiptModal() {
    final receipt = _completionReceipt ?? {};
    final customerPaid = receipt['customerPaid'] ?? _settlement?['vayaFareTotal'] ?? 0;
    final cashCollected = receipt['cashCollectedByDriver'] ?? 0;
    final commission = receipt['platformCommission'] ?? 0;
    final driverEarning = receipt['driverEarning'] ?? 0;
    final paymentMethod = receipt['paymentMethod'] ?? 'Cash';
    final paymentStatus = receipt['paymentStatus'] ?? 'Completed';
    final vayaId = 'VAYA #${widget.bookingId.substring(0, 8).toUpperCase()}';

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF18181B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xFF1E3A2B),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded, color: VayaDriverTheme.routeGreen, size: 40),
              ),
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'Delivery completed',
                style: TextStyle(fontFamily: 'General Sans', fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                vayaId,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF22221F),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF2D2D2A)),
              ),
              child: Column(
                children: [
                  _buildReceiptRow('Customer paid', '₹$customerPaid', isBold: true),
                  const Divider(color: Color(0xFF333330), height: 20),
                  _buildReceiptRow('Cash collected by you', '₹$cashCollected'),
                  const SizedBox(height: 8),
                  _buildReceiptRow('Platform commission', '₹$commission', isNegative: true),
                  const SizedBox(height: 8),
                  _buildReceiptRow('Your delivery earning', '₹$driverEarning', isHighlight: true),
                  const Divider(color: Color(0xFF333330), height: 20),
                  _buildReceiptRow('Payment method', '$paymentMethod'),
                  const SizedBox(height: 8),
                  _buildReceiptRow('Payment status', '$paymentStatus', isSuccessState: true),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Tolls/parking: Paid separately at actuals, if applicable',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF9CA3AF)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: VayaDriverTheme.saffron,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  widget.onCompleted();
                },
                child: const Text('Done', style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF4A4A45)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      widget.onViewTripDetails();
                    },
                    child: const Text('View trip details', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFE74C3C)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      widget.onReportIssue();
                    },
                    child: const Text('Report fare issue', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFE74C3C), fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value, {bool isBold = false, bool isNegative = false, bool isHighlight = false, bool isSuccessState = false}) {
    Color valColor = Colors.white;
    if (isNegative) valColor = const Color(0xFFE74C3C);
    if (isHighlight) valColor = VayaDriverTheme.saffron;
    if (isSuccessState) valColor = VayaDriverTheme.routeGreen;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontFamily: 'Inter', fontSize: 14, color: isBold ? Colors.white : const Color(0xFF9CA3AF), fontWeight: isBold ? FontWeight.bold : FontWeight.w500)),
        Text(value, style: TextStyle(fontFamily: 'Inter', fontSize: isHighlight ? 16 : 14, fontWeight: (isBold || isHighlight) ? FontWeight.bold : FontWeight.w600, color: valColor)),
      ],
    );
  }

  Future<void> _notifyCustomerForPayment() async {
    setState(() => _isNotifyingCustomer = true);
    try {
      final token = widget.authToken ?? await DriverAuthHelper.getAuthToken();
      final url = Uri.parse('${widget.apiBaseUrl}/api/booking/${widget.bookingId}/notify-customer-payment');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };
      await http.post(url, headers: headers).timeout(const Duration(seconds: 8));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification sent to customer for payment.')),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to notify customer.')),
      );
    } finally {
      setState(() => _isNotifyingCustomer = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF18181B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181B),
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Delivery summary',
              style: TextStyle(fontFamily: 'General Sans', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 2),
            Text(
              'VAYA #${widget.bookingId.substring(0, 8).toUpperCase()}',
              style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E3A2B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: VayaDriverTheme.routeGreen.withValues(alpha: 0.5)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(radius: 3, backgroundColor: VayaDriverTheme.routeGreen),
                SizedBox(width: 6),
                Text('At drop-off', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: VayaDriverTheme.routeGreen, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VayaLoader.inline(size: 36, color: VayaDriverTheme.saffron),
                  SizedBox(height: 16),
                  Text('Loading settlement summary...', style: TextStyle(fontFamily: 'Inter', color: Color(0xFF9CA3AF), fontSize: 14)),
                ],
              ),
            )
          : _isError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Color(0xFFE74C3C), size: 48),
                        const SizedBox(height: 16),
                        Text(_errorMessage, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Inter', color: Colors.white, fontSize: 14)),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VayaDriverTheme.saffron,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _fetchSettlementSummary(),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry Server Fetch'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFF39C12)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          onPressed: () {
                            final fallback = _computeLocalFallbackSettlement(widget.booking);
                            setState(() {
                              _settlement = fallback;
                              _isLoading = false;
                              _isError = false;
                            });
                          },
                          icon: const Icon(Icons.calculate_outlined, color: Color(0xFFF39C12), size: 18),
                          label: const Text('Use Local Settlement & Enter OTP', style: TextStyle(color: Color(0xFFF39C12), fontFamily: 'Inter', fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: widget.onCompleted,
                          icon: const Icon(Icons.sync_rounded, size: 16, color: Color(0xFF9CA3AF)),
                          label: const Text('Sync / Refresh Active Trip', style: TextStyle(color: Color(0xFF9CA3AF), fontFamily: 'Inter', fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                )
              : SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Compact Route Row
                              _buildCompactRouteRow(),
                              const SizedBox(height: 20),

                              // Fare Summary Card
                              _buildFareSummaryCard(),
                              const SizedBox(height: 20),

                              // Payment Summary Card
                              _buildPaymentSummaryCard(),
                              const SizedBox(height: 20),

                              // Drop-off OTP Input Section
                              _buildOtpSection(),

                              // Bottom padding to ensure content scrolls clear of sticky CTA
                              SizedBox(height: 90 + bottomInset),
                            ],
                          ),
                        ),
                      ),
                      _buildStickyCtaArea(bottomInset),
                    ],
                  ),
                ),
    );
  }

  Widget _buildCompactRouteRow() {
    final pickup = widget.booking['pickup_name']?.toString() ?? 'Pickup Location';
    final dropoff = widget.booking['dropoff_name']?.toString() ?? 'Drop-off Location';
    final shortPickup = _extractShortAddress(pickup);
    final shortDropoff = _extractShortAddress(dropoff);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF22221F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D2A)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.circle, size: 10, color: VayaDriverTheme.saffron),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pickup: $shortPickup',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.location_on, size: 12, color: VayaDriverTheme.routeGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Drop-off: $shortDropoff',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _extractShortAddress(String fullAddr) {
    final parts = fullAddr.split(',');
    if (parts.length > 2) {
      return '${parts[0].trim()}, ${parts[1].trim()}';
    }
    return fullAddr;
  }

  Widget _buildFareSummaryCard() {
    final baseFare = _settlement?['baseFare'] ?? 0;
    final vayaFareTotal = _settlement?['vayaFareTotal'] ?? 0;

    final pickupWait = _settlement?['pickupWait'] as Map<String, dynamic>? ?? {};
    final pTotal = pickupWait['totalMinutes'] ?? 0;
    final pFree = pickupWait['freeMinutes'] ?? 10;
    final pChargeable = pickupWait['chargeableMinutes'] ?? 0;
    final pRate = pickupWait['ratePerMinute'] ?? 2;
    final pAmount = pickupWait['amount'] ?? 0;

    final dropoffWait = _settlement?['dropoffWait'] as Map<String, dynamic>? ?? {};
    final dTotal = dropoffWait['totalMinutes'] ?? 0;
    final dFree = dropoffWait['freeMinutes'] ?? 10;
    final dChargeable = dropoffWait['chargeableMinutes'] ?? 0;
    final dRate = dropoffWait['ratePerMinute'] ?? 2;
    final dAmount = dropoffWait['amount'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF22221F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2D2D2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'VAYA fare total',
                style: TextStyle(fontFamily: 'General Sans', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              Text(
                '₹$vayaFareTotal',
                style: const TextStyle(fontFamily: 'General Sans', fontSize: 22, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron),
              ),
            ],
          ),
          const Divider(color: Color(0xFF333330), height: 24),
          _buildFareItemRow('Base delivery fare', '₹$baseFare'),
          const SizedBox(height: 12),

          // Pickup Waiting
          const Text('Pickup waiting', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$pTotal min total · $pFree min free\n${pChargeable > 0 ? "$pChargeable chargeable min × ₹$pRate" : "No additional charge"}',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF9CA3AF), height: 1.3),
              ),
              Text(
                '₹$pAmount',
                style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: pAmount > 0 ? Colors.white : const Color(0xFF9CA3AF)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Drop-off Waiting
          const Text('Drop-off waiting', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$dTotal min total · $dFree min free\n${dChargeable > 0 ? "$dChargeable chargeable min × ₹$dRate" : "No additional charge"}',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF9CA3AF), height: 1.3),
              ),
              Text(
                '₹$dAmount',
                style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: dAmount > 0 ? Colors.white : const Color(0xFF9CA3AF)),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF181815),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A26)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF9CA3AF)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tolls and parking charges, if applicable, are payable separately by the customer at actuals.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFareItemRow(String label, String amount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFFE2E8F0))),
        Text(amount, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
      ],
    );
  }

  Widget _buildPaymentSummaryCard() {
    final method = _settlement?['paymentMethod']?.toString().toUpperCase() ?? 'CASH';
    final payer = (_settlement?['adjustmentPayer'] ?? _settlement?['initialPayer'] ?? 'Receiver').toString().toUpperCase();
    final point = (_settlement?['initialCollectionPoint'] ?? 'Drop-off').toString().toUpperCase();
    final status = (_settlement?['paymentStatus'] ?? 'payment_due').toString();

    final vayaFareTotal = _settlement?['vayaFareTotal'] ?? 0;
    final collectedAtPickup = _settlement?['amountCollectedAtPickup'] ?? 0;
    final paidOnline = _settlement?['amountPaidOnline'] ?? 0;
    final amountDueNow = _settlement?['amountDueNow'] ?? 0;

    final isCash = method == 'CASH';
    final isOnline = method == 'ONLINE' || method == 'WALLET';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF22221F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2D2D2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Payment summary',
            style: TextStyle(fontFamily: 'General Sans', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          _buildPaymentMetaGrid(method, payer, point, _formatStatusLabel(status)),
          const Divider(color: Color(0xFF333330), height: 24),

          if (isCash && collectedAtPickup == 0) ...[
            // CASH AT DROPOFF
            _buildFareItemRow('VAYA fare total', '₹$vayaFareTotal'),
            const SizedBox(height: 6),
            _buildFareItemRow('Collected earlier', '₹0'),
            const SizedBox(height: 6),
            _buildFareItemRow('Cash due now', '₹$amountDueNow'),
            const SizedBox(height: 6),
            _buildFareItemRow('Collect from', 'Receiver'),
            const SizedBox(height: 14),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF3B2A10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VayaDriverTheme.saffron),
              ),
              child: Text(
                'Collect ₹$amountDueNow in cash from receiver',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),

            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: VayaDriverTheme.saffron,
              value: _isCashCollectedConfirmed,
              onChanged: (val) {
                setState(() => _isCashCollectedConfirmed = val ?? false);
              },
              title: Text(
                'I confirm that I collected ₹$amountDueNow in cash from the receiver.',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ),
          ] else if (isCash && collectedAtPickup > 0) ...[
            // CASH PARTIAL AT PICKUP
            _buildFareItemRow('VAYA fare total', '₹$vayaFareTotal'),
            const SizedBox(height: 6),
            _buildFareItemRow('Collected at pickup', '₹$collectedAtPickup'),
            const SizedBox(height: 6),
            _buildFareItemRow('Additional amount due', '₹$amountDueNow'),
            const SizedBox(height: 12),

            if (amountDueNow > 0) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B2A10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VayaDriverTheme.saffron),
                ),
                child: Text(
                  'Collect ₹$amountDueNow from receiver at drop-off',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: VayaDriverTheme.saffron,
                value: _isCashCollectedConfirmed,
                onChanged: (val) {
                  setState(() => _isCashCollectedConfirmed = val ?? false);
                },
                title: Text(
                  'I confirm that I collected ₹$amountDueNow in cash from the receiver.',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3A2B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VayaDriverTheme.routeGreen),
                ),
                child: const Text(
                  'Nothing more to collect',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ] else if (isOnline) ...[
            // ONLINE / WALLET
            _buildFareItemRow('VAYA fare total', '₹$vayaFareTotal'),
            const SizedBox(height: 6),
            _buildFareItemRow('Paid online', '₹$paidOnline'),
            const SizedBox(height: 6),
            _buildFareItemRow('Additional wait charges due', '₹$amountDueNow'),
            const SizedBox(height: 12),

            if (amountDueNow == 0 || status == 'paid') ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3A2B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VayaDriverTheme.routeGreen),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline_rounded, color: VayaDriverTheme.routeGreen, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Paid in full',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: VayaDriverTheme.routeGreen),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B2A10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VayaDriverTheme.saffron),
                ),
                child: Text(
                  'Collect ₹$amountDueNow in cash for extra waiting time',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 13.5, fontWeight: FontWeight.bold, color: VayaDriverTheme.saffron),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: VayaDriverTheme.saffron,
                value: _isCashCollectedConfirmed,
                onChanged: (val) {
                  setState(() => _isCashCollectedConfirmed = val ?? false);
                },
                title: Text(
                  'I confirm that I collected ₹$amountDueNow in cash from the customer for extra waiting time.',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPaymentMetaGrid(String method, String payer, String point, String status) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildMetaChip('Payment method', method)),
            const SizedBox(width: 8),
            Expanded(child: _buildMetaChip('Payer', payer)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _buildMetaChip('Collection point', point)),
            const SizedBox(width: 8),
            Expanded(child: _buildMetaChip('Payment status', status, isStatus: true)),
          ],
        ),
      ],
    );
  }

  Widget _buildMetaChip(String label, String value, {bool isStatus = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF181815),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2E2E2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isStatus && value.contains('Paid') ? VayaDriverTheme.routeGreen : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  String _formatStatusLabel(String raw) {
    switch (raw) {
      case 'paid':
        return 'Paid in full';
      case 'partially_paid':
        return 'Partially paid';
      case 'support_override_approved':
        return 'Override approved';
      case 'waiting_for_customer_payment':
        return 'Waiting for payment';
      default:
        return 'Payment due';
    }
  }

  Widget _buildOtpSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF22221F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2D2D2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter 6-digit drop-off OTP',
            style: TextStyle(fontFamily: 'General Sans', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ask the receiver for the 6-digit verification code to complete delivery.',
            style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 16),

          // 6 OTP Box Inputs
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(6, (index) {
              return SizedBox(
                width: 44,
                height: 52,
                child: TextField(
                  controller: _otpControllers[index],
                  focusNode: _otpFocusNodes[index],
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 1,
                  style: const TextStyle(fontFamily: 'General Sans', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    counterText: '',
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    filled: true,
                    fillColor: const Color(0xFF181815),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: _otpError != null ? const Color(0xFFE74C3C) : const Color(0xFF3D3D38)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: VayaDriverTheme.saffron, width: 2),
                    ),
                  ),
                  onChanged: (val) {
                    if (val.isNotEmpty && index < 5) {
                      _otpFocusNodes[index + 1].requestFocus();
                    } else if (val.isEmpty && index > 0) {
                      _otpFocusNodes[index - 1].requestFocus();
                    }
                    if (_isOtpComplete) {
                      // Automatically keep OTP in view when completed
                      _scrollToKeepOtpVisible();
                    }
                  },
                ),
              );
            }),
          ),

          if (_otpError != null) ...[
            const SizedBox(height: 10),
            Text(
              _otpError!,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFE74C3C), fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  void _scrollToKeepOtpVisible() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _buildStickyCtaArea(double bottomInset) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 12 + bottomInset,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF18181B),
        boxShadow: [
          BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, -4)),
        ],
      ),
      child: SizedBox(
        height: 56,
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: VayaDriverTheme.saffron,
            disabledBackgroundColor: const Color(0xFF333330),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 2,
          ),
          onPressed: _canSubmit ? _handleOtpSubmit : null,
          child: _isCompleting
              ? VayaLoader.inline(size: 22, color: Colors.white)
              : const Text(
                  'Verify OTP & complete delivery',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold),
                ),
        ),
      ),
    );
  }
}
