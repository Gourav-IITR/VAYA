import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class VehicleIconHelper {
  static final Map<String, BitmapDescriptor> _markerCache = {};

  /// Normalizes vehicle type strings to standard keys
  static String normalizeVehicleType(String? rawType) {
    if (rawType == null) return 'bike';
    final type = rawType.toLowerCase().trim();
    if (type.contains('bike') || type.contains('motorcycle') || type == '2_wheeler') {
      return 'bike';
    } else if (type.contains('three') || type.contains('3') || type.contains('auto') || type.contains('rickshaw')) {
      return 'three_wheeler';
    } else if (type.contains('ace') || type.contains('mini') || type.contains('pickup')) {
      return 'ace';
    } else if (type.contains('truck') || type.contains('lcv') || type.contains('box') || type.contains('container')) {
      return 'truck';
    }
    return 'bike';
  }

  /// Returns the SVG asset path for a vehicle type
  static String getSvgAssetPath(String? rawType) {
    final type = normalizeVehicleType(rawType);
    switch (type) {
      case 'three_wheeler':
        return 'assets/icons/vehicle-icon-auto-rickshaw.svg';
      case 'ace':
        return 'assets/icons/vehicle-icon-mini-truck.svg';
      case 'truck':
        return 'assets/icons/vehicle-icon-box-truck.svg';
      case 'bike':
      default:
        return 'assets/icons/vehicle-icon-motorcycle.svg';
    }
  }

  /// Returns an SvgPicture widget for UI displays
  static Widget getVehicleSvgWidget(
    String? vehicleType, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
  }) {
    final assetPath = getSvgAssetPath(vehicleType);
    return SvgPicture.asset(
      assetPath,
      width: width,
      height: height,
      fit: fit,
    );
  }

  /// Renders the vehicle SVG onto a map marker canvas with a clean badge container
  static Future<BitmapDescriptor> getVehicleMarkerIcon(
    String? vehicleType, {
    int targetSize = 130,
  }) async {
    final normType = normalizeVehicleType(vehicleType);
    final cacheKey = '$normType-$targetSize';

    if (_markerCache.containsKey(cacheKey)) {
      return _markerCache[cacheKey]!;
    }

    try {
      final assetPath = getSvgAssetPath(normType);
      final PictureInfo pictureInfo = await vg.loadPicture(SvgAssetLoader(assetPath), null);

      final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(pictureRecorder);
      final double size = targetSize.toDouble();

      // Draw Pure SVG Vehicle Icon without background circle, border, or shadow
      final double scaleX = size / pictureInfo.size.width;
      final double scaleY = size / pictureInfo.size.height;
      final double scale = scaleX < scaleY ? scaleX : scaleY;

      final double dx = (size - (pictureInfo.size.width * scale)) / 2;
      final double dy = (size - (pictureInfo.size.height * scale)) / 2;

      canvas.save();
      canvas.translate(dx, dy);
      canvas.scale(scale, scale);
      canvas.drawPicture(pictureInfo.picture);
      canvas.restore();

      pictureInfo.picture.dispose();

      final ui.Image image = await pictureRecorder.endRecording().toImage(targetSize, targetSize);
      final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);

      if (bytes != null) {
        final descriptor = BitmapDescriptor.bytes(bytes.buffer.asUint8List());
        _markerCache[cacheKey] = descriptor;
        return descriptor;
      }
    } catch (e) {
      debugPrint('Error generating SVG marker for $vehicleType: $e');
    }

    // Fallback descriptor if rasterization fails
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
  }
}
