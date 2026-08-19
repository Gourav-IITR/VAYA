import 'dart:math' as math;
import 'package:flutter/material.dart';

enum VayaVehicleType { miniTruck, threeWheeler, twoWheeler }

enum VayaLoaderVariant { fullscreen, section, inline }

/// VAYA Branded Loader Widget for Flutter
class VayaLoader extends StatefulWidget {
  final VayaLoaderVariant variant;
  final double size;
  final String? message;
  final VayaVehicleType vehicleType;
  final double? progress; // null for indeterminate, 0..100 for determinate
  final Color? color;
  final bool blur;

  const VayaLoader({
    super.key,
    this.variant = VayaLoaderVariant.section,
    this.size = 96.0,
    this.message,
    this.vehicleType = VayaVehicleType.miniTruck,
    this.progress,
    this.color,
    this.blur = true,
  });

  const VayaLoader.fullscreen({
    super.key,
    this.size = 140.0,
    this.message = 'Verifying VAYA Operations...',
    this.vehicleType = VayaVehicleType.miniTruck,
    this.progress,
    this.blur = true,
  })  : variant = VayaLoaderVariant.fullscreen,
        color = null;

  const VayaLoader.section({
    super.key,
    this.size = 96.0,
    this.message,
    this.vehicleType = VayaVehicleType.miniTruck,
    this.progress,
  })  : variant = VayaLoaderVariant.section,
        color = null,
        blur = false;

  const VayaLoader.inline({
    super.key,
    this.size = 20.0,
    this.color,
  })  : variant = VayaLoaderVariant.inline,
        message = null,
        vehicleType = VayaVehicleType.miniTruck,
        progress = null,
        blur = false;

  @override
  State<VayaLoader> createState() => _VayaLoaderState();
}

class _VayaLoaderState extends State<VayaLoader> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  static const Color saffron = Color(0xFFF26430);
  static const Color cream = Color(0xFFF4EFE6);
  static const Color slate = Color(0xFF3C3A34);
  static const Color inkBlack = Color(0xFF0E0E0C);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.variant == VayaLoaderVariant.inline) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: _InlineLoaderPainter(
                progress: _controller.value,
                color: widget.color ?? Colors.white,
              ),
            );
          },
        ),
      );
    }

    final loaderBody = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return CustomPaint(
                painter: _VayaScenePainter(
                  animationValue: _controller.value,
                  vehicleType: widget.vehicleType,
                  determinateProgress: widget.progress,
                ),
              );
            },
          ),
        ),
        if (widget.message != null && widget.message!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            widget.message!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cream,
              letterSpacing: -0.2,
            ),
          ),
          if (widget.progress != null) ...[
            const SizedBox(height: 4),
            Text(
              '${widget.progress!.clamp(0, 100).round()}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: saffron,
              ),
            ),
          ],
        ],
      ],
    );

    if (widget.variant == VayaLoaderVariant.fullscreen) {
      return Container(
        color: inkBlack.withValues(alpha: 0.95),
        alignment: Alignment.center,
        child: Material(
          type: MaterialType.transparency,
          child: loaderBody,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: loaderBody,
    );
  }
}

/// Custom Painter for VAYA Scene (Route, Nodes, Markers, Vehicle, Wheel Rotation)
class _VayaScenePainter extends CustomPainter {
  final double animationValue;
  final VayaVehicleType vehicleType;
  final double? determinateProgress;

  static const Color saffron = Color(0xFFF26430);
  static const Color inkBlack = Color(0xFF0E0E0C);
  static const Color cream = Color(0xFFF4EFE6);
  static const Color slate = Color(0xFF3C3A34);

  _VayaScenePainter({
    required this.animationValue,
    required this.vehicleType,
    this.determinateProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 200.0;
    canvas.save();
    canvas.scale(scale, scale);

    final path = Path()
      ..moveTo(28, 148)
      ..cubicTo(60, 148, 76, 108, 100, 100)
      ..cubicTo(124, 92, 148, 60, 172, 60);

    final bgPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, bgPaint);

    final pathMetrics = path.computeMetrics().toList();
    if (pathMetrics.isEmpty) {
      canvas.restore();
      return;
    }

    final pathMetric = pathMetrics.first;
    final totalLength = pathMetric.length;

    final isDeterminate = determinateProgress != null;
    double currentProgressPct;

    if (isDeterminate) {
      currentProgressPct = (determinateProgress! / 100.0).clamp(0.0, 1.0);
    } else {
      final t = animationValue;
      if (t < 0.7) {
        final norm = t / 0.7;
        currentProgressPct = norm * norm * (3 - 2 * norm);
      } else {
        currentProgressPct = 1.0;
      }
    }

    final saffronTrackLength = totalLength * currentProgressPct;
    if (saffronTrackLength > 0) {
      final activePath = pathMetric.extractPath(0, saffronTrackLength);
      final saffronPaint = Paint()
        ..color = saffron
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(activePath, saffronPaint);
    }

    final nodePoints = [
      const Offset(62, 140),
      const Offset(100, 100),
      const Offset(138, 74),
    ];

    for (int i = 0; i < nodePoints.length; i++) {
      final center = nodePoints[i];
      double pulseScale = 1.0;
      if (!isDeterminate) {
        final phaseShift = i * 0.3;
        final phase = (animationValue * 2 * math.pi + phaseShift) % (2 * math.pi);
        pulseScale = 0.85 + 0.3 * math.sin(phase);
      }
      final nodePaint = Paint()
        ..color = saffron
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 2.2 * pulseScale, nodePaint);
    }

    final pickupCenter = const Offset(28, 148);
    final pickupRect = Rect.fromCenter(center: pickupCenter, width: 8, height: 8);
    final pickupRRect = RRect.fromRectAndRadius(pickupRect, const Radius.circular(1));
    final pickupPaint = Paint()
      ..color = saffron
      ..style = PaintingStyle.fill;
    canvas.drawRRect(pickupRRect, pickupPaint);

    final dropCenter = const Offset(172, 60);
    final dropFillPaint = Paint()
      ..color = cream
      ..style = PaintingStyle.fill;
    final dropStrokePaint = Paint()
      ..color = saffron
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawCircle(dropCenter, 5, dropFillPaint);
    canvas.drawCircle(dropCenter, 5, dropStrokePaint);

    final vehicleDistance = (saffronTrackLength).clamp(0.0, totalLength);
    final tangent = pathMetric.getTangentForOffset(vehicleDistance);

    if (tangent != null && currentProgressPct < 0.98) {
      canvas.save();
      canvas.translate(tangent.position.dx, tangent.position.dy);
      canvas.rotate(tangent.angle);

      double alpha = 1.0;
      if (!isDeterminate) {
        if (animationValue < 0.06) {
          alpha = animationValue / 0.06;
        } else if (animationValue > 0.82 && animationValue < 0.92) {
          alpha = 1.0 - (animationValue - 0.82) / 0.1;
        } else if (animationValue >= 0.92) {
          alpha = 0.0;
        }
      }

      final wheelRotation = animationValue * 4 * math.pi;

      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: alpha));
      _drawVehicleGraphic(canvas, vehicleType, wheelRotation);
      canvas.restore();

      canvas.restore();
    }

    if (isDeterminate && currentProgressPct >= 0.98) {
      final vmarkPath = Path()
        ..moveTo(60, 60)
        ..lineTo(100, 140)
        ..lineTo(148, 40)
        ..lineTo(138, 36);

      final vmarkPaint = Paint()
        ..color = inkBlack
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter;
      canvas.drawPath(vmarkPath, vmarkPaint);
    }

    canvas.restore();
  }

  void _drawVehicleGraphic(Canvas canvas, VayaVehicleType type, double wheelAngle) {
    canvas.scale(1.8, 1.8);

    final inkPaint = Paint()..color = inkBlack..style = PaintingStyle.fill;
    final saffronPaint = Paint()..color = saffron..style = PaintingStyle.fill;
    final creamPaint = Paint()..color = cream..style = PaintingStyle.fill;

    if (type == VayaVehicleType.miniTruck) {
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-14, -11, 16, 9), const Radius.circular(1.2)), inkPaint);
      
      final cabPath = Path()
        ..moveTo(2, -8)
        ..lineTo(8, -8)
        ..lineTo(11, -3)
        ..lineTo(11, -2)
        ..lineTo(2, -2)
        ..close();
      canvas.drawPath(cabPath, saffronPaint);

      final winPath = Path()
        ..moveTo(3.5, -6.8)
        ..lineTo(7.5, -6.8)
        ..lineTo(9.6, -3.8)
        ..lineTo(3.5, -3.8)
        ..close();
      canvas.drawPath(winPath, creamPaint);

      canvas.drawRect(const Rect.fromLTWH(-14, -2, 25, 1.6), inkPaint);

      _drawWheel(canvas, const Offset(-9, 1), 2.6, wheelAngle);
      _drawWheel(canvas, const Offset(7, 1), 2.6, wheelAngle);
    } else if (type == VayaVehicleType.threeWheeler) {
      final roofPath = Path()
        ..moveTo(-10, -8)
        ..quadraticBezierTo(-10, -11, -7, -11)
        ..lineTo(3, -11)
        ..quadraticBezierTo(6, -11, 6, -8)
        ..lineTo(6, -2)
        ..lineTo(-10, -2)
        ..close();
      canvas.drawPath(roofPath, saffronPaint);

      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-7, -9, 10, 3), const Radius.circular(0.5)), creamPaint);
      canvas.drawRect(const Rect.fromLTWH(-11, -2, 19, 1.4), inkPaint);

      _drawWheel(canvas, const Offset(-7, 1), 2.4, wheelAngle);
      _drawWheel(canvas, const Offset(5, 1), 2.4, wheelAngle);
    } else {
      canvas.drawCircle(const Offset(0, -10), 1.8, inkPaint);
      final riderBody = Path()
        ..moveTo(-1.5, -8.5)
        ..lineTo(-0.5, -3.5)
        ..lineTo(1.5, -3.5)
        ..lineTo(2.5, -8.5)
        ..close();
      canvas.drawPath(riderBody, inkPaint);

      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-6, -6, 4.5, 4), const Radius.circular(0.6)), saffronPaint);

      final barPath = Path()
        ..moveTo(-5, 1)
        ..lineTo(-1, -3)
        ..lineTo(3, -3)
        ..lineTo(6, 1);
      final barPaint = Paint()..color = inkBlack..style = PaintingStyle.stroke..strokeWidth = 1.2..strokeCap = StrokeCap.round;
      canvas.drawPath(barPath, barPaint);

      _drawWheel(canvas, const Offset(-5, 1), 2.4, wheelAngle);
      _drawWheel(canvas, const Offset(6, 1), 2.4, wheelAngle);
    }
  }

  void _drawWheel(Canvas canvas, Offset center, double radius, double angle) {
    final inkPaint = Paint()..color = inkBlack..style = PaintingStyle.fill;
    final creamPaint = Paint()..color = cream..style = PaintingStyle.fill;
    final spokePaint = Paint()
      ..color = cream
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;

    canvas.drawCircle(center, radius, inkPaint);
    canvas.drawCircle(center, radius * 0.35, creamPaint);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    canvas.drawLine(Offset(0, -radius * 0.8), Offset(0, radius * 0.8), spokePaint);
    canvas.drawLine(Offset(-radius * 0.8, 0), Offset(radius * 0.8, 0), spokePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VayaScenePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.vehicleType != vehicleType ||
        oldDelegate.determinateProgress != determinateProgress;
  }
}

/// Custom Painter for Inline Loader Wheel & Unrolling Chevron
class _InlineLoaderPainter extends CustomPainter {
  final double progress;
  final Color color;

  _InlineLoaderPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale, scale);

    final chevronPath = Path()
      ..moveTo(3, 18)
      ..lineTo(10, 11)
      ..lineTo(15, 15)
      ..lineTo(21, 6);

    final chevronPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(chevronPath, chevronPaint);

    final center = const Offset(12, 12);
    final angle = progress * 2 * math.pi;

    canvas.drawCircle(center, 4.2, Paint()..color = color..style = PaintingStyle.fill);
    canvas.drawCircle(center, 1.4, Paint()..color = const Color(0xFFF4EFE6)..style = PaintingStyle.fill);

    canvas.save();
    canvas.translate(12, 12);
    canvas.rotate(angle);
    canvas.drawLine(
      const Offset(0, -4),
      const Offset(0, 4),
      Paint()
        ..color = const Color(0xFFF4EFE6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9,
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _InlineLoaderPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
