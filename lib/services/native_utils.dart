import 'dart:typed_data';
import 'package:flutter/services.dart';

class NativeUtils {
  static const MethodChannel _channel = MethodChannel('com.example.vpn_all/utils');

  static Future<bool> saveImageToGallery(Uint8List bytes, String filename) async {
    try {
      return await _channel.invokeMethod<bool>('saveImageToGallery', {
        'bytes': bytes,
        'filename': filename,
      }) ?? false;
    } catch (_) {
      return false;
    }
  }
}