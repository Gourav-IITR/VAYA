import 'package:flutter/material.dart';
import '../services/razorpay_service.dart';
import 'vaya_loader.dart';

class PaymentMethodSheet extends StatefulWidget {
  final double amount;
  final String purpose; // 'dues_repayment'
  final String userPhone;
  final String userName;
  final RazorpayPaymentService razorpayService;
  final String apiBaseUrl;
  final String token;
  final Function(String error) onFailure;

  const PaymentMethodSheet({
    super.key,
    required this.amount,
    required this.purpose,
    required this.userPhone,
    required this.userName,
    required this.razorpayService,
    required this.apiBaseUrl,
    required this.token,
    required this.onFailure,
  });

  @override
  State<PaymentMethodSheet> createState() => _PaymentMethodSheetState();
}

class _PaymentMethodSheetState extends State<PaymentMethodSheet> {
  final TextEditingController _vpaController = TextEditingController();
  bool _isSubmitting = false;
  String _selectedMethod = 'intent';
  String? _selectedPackage;
  List<Map<String, dynamic>> _upiApps = [];
  bool _loadingApps = true;

  @override
  void initState() {
    super.initState();
    _loadUpiApps();
  }

  Future<void> _loadUpiApps() async {
    final apps = await widget.razorpayService.getAvailableUpiApps();
    if (mounted) {
      setState(() {
        _upiApps = apps;
        if (apps.isNotEmpty) {
          _selectedPackage = (apps.first['packageName'] ?? apps.first['package_name'] ?? '').toString();
        }
        _loadingApps = false;
      });
    }
  }

  @override
  void dispose() {
    _vpaController.dispose();
    super.dispose();
  }

  Future<void> _processPayment({String? package, String? vpa}) async {
    if (_isSubmitting) return;

    setState(() => _isSubmitting = true);

    try {
      final orderData = await widget.razorpayService.createOrder(
        apiBaseUrl: widget.apiBaseUrl,
        token: widget.token,
        amount: widget.amount,
        purpose: widget.purpose,
      );

      if (!mounted) return;
      Navigator.pop(context); // Close sheet before native app launch

      await widget.razorpayService.submitPayment(
        keyId: orderData['keyId'],
        orderId: orderData['orderId'],
        amountPaise: orderData['amountPaise'],
        purpose: widget.purpose,
        userPhone: widget.userPhone,
        userName: widget.userName,
        upiPackageName: package,
        upiVpa: vpa,
        onFailure: widget.onFailure,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        widget.onFailure('Payment initialization error: $e');
      }
    }
  }

  Widget _buildAppIcon(String appName) {
    final nameLower = appName.toLowerCase();
    IconData iconData = Icons.account_balance_wallet_outlined;
    Color iconColor = const Color(0xFF6366F1);

    if (nameLower.contains('google') || nameLower.contains('gpay')) {
      iconData = Icons.g_mobiledata_rounded;
      iconColor = const Color(0xFF4285F4);
    } else if (nameLower.contains('phonepe')) {
      iconData = Icons.flash_on_rounded;
      iconColor = const Color(0xFFA855F7);
    } else if (nameLower.contains('paytm')) {
      iconData = Icons.payment_rounded;
      iconColor = const Color(0xFF38BDF8);
    } else if (nameLower.contains('bhim') || nameLower.contains('upi')) {
      iconData = Icons.account_balance_rounded;
      iconColor = const Color(0xFF2DD4BF);
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(iconData, size: 24, color: iconColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF181816),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C28),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header: Amount
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Platform Dues Repayment',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  Text(
                    '₹${widget.amount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFDFCF7),
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFF2C2C28)),
          const SizedBox(height: 16),

          const Text(
            'SELECT UPI APP FOR PAYMENT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFFCBD5E1),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),

          if (_loadingApps)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: VayaLoader.inline(size: 24, color: Color(0xFFF26430)),
              ),
            )
          else ...[
            ..._upiApps.map((app) {
              final String name = (app['appName'] ?? app['name'] ?? 'UPI App').toString();
              final String pkg = (app['packageName'] ?? app['package_name'] ?? '').toString();
              final bool isSelected = _selectedMethod == 'intent' && _selectedPackage == pkg;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedMethod = 'intent';
                      _selectedPackage = pkg;
                    });
                    _processPayment(package: pkg);
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF26241E) : const Color(0xFF1E1E1B),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? const Color(0xFFFFB800) : const Color(0xFF2C2C28),
                        width: isSelected ? 1.5 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        _buildAppIcon(name),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFFDFCF7),
                                ),
                              ),
                              const Text(
                                'Instant UPI Payment',
                                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 16,
                          color: isSelected ? const Color(0xFFFFB800) : const Color(0xFF64748B),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),

            const SizedBox(height: 8),

            InkWell(
              onTap: () {
                setState(() {
                  _selectedMethod = _selectedMethod == 'vpa' ? 'intent' : 'vpa';
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _selectedMethod == 'vpa' ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: const Color(0xFFFFB800),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _selectedMethod == 'vpa' ? 'Hide manual UPI ID' : 'Or pay using UPI ID / VPA',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFFFB800),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_selectedMethod == 'vpa') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _vpaController,
                style: const TextStyle(color: Color(0xFFFDFCF7), fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  hintText: 'Enter UPI ID (e.g. name@upi)',
                  hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1B),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF2C2C28)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFFB800), width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isSubmitting
                    ? null
                    : () {
                        final vpa = _vpaController.text.trim();
                        if (vpa.isEmpty || !vpa.contains('@')) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a valid UPI ID (e.g. user@upi)')),
                          );
                          return;
                        }
                        _processPayment(vpa: vpa);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFB800),
                  foregroundColor: const Color(0xFF0F172A),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text('Pay via UPI ID', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ],
          ],

          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.shield_outlined, size: 14, color: Color(0xFF94A3B8)),
              SizedBox(width: 6),
              Text(
                '256-bit Encrypted Payment • Direct App Handoff',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
