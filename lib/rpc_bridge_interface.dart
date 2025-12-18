// lib/rpc_bridge_interface.dart

import 'package:flutter/material.dart';

abstract class IRpcBridge {
  Future<void> init();

  Stream<Map<String, dynamic>>? get gasResponses;

  /// NEW — platform-specific wrapper
  Widget wrapApp(Widget app);

  Future<Map<String, dynamic>> requestTemperature();
  Future<void> sendCameraEvent();
  Future<void> sendMicEvent();
  Future<void> sendFileEvent();
  Future<void> sendLocationEvent();
  Future<void> sendVanillaEvent();
}
