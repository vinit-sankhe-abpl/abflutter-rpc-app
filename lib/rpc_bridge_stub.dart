// lib/rpc_bridge_stub.dart

import 'package:flutter/material.dart';

import 'rpc_bridge_interface.dart';

class RpcBridgeImpl implements IRpcBridge {
  @override
  Future<void> init() async {}

  @override
  Stream<Map<String, dynamic>>? get gasResponses => null;

  @override
  Widget wrapApp(Widget app) {
    throw UnsupportedError('wrapApp not supported in this environment');
  }

  @override
  Future<Map<String, dynamic>> requestTemperature() async =>
      throw UnsupportedError(
        'requestTemperature not supported in this environment',
      );

  @override
  Future<void> sendCameraEvent() async => throw UnsupportedError(
    'sendCameraEvent not supported in this environment',
  );

  @override
  Future<void> sendMicEvent() async =>
      throw UnsupportedError('sendMicEvent not supported in this environment');

  @override
  Future<void> sendFileEvent() async =>
      throw UnsupportedError('sendFileEvent not supported in this environment');

  @override
  Future<void> sendLocationEvent() async => throw UnsupportedError(
    'sendLocationEvent not supported in this environment',
  );

  @override
  Future<void> sendVanillaEvent() => throw UnsupportedError(
    'sendVanillaEvent not supported in this environment',
  );
}
