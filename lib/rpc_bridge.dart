// lib/rpc_bridge.dart

import 'package:flutter/foundation.dart' show kIsWeb;

import 'rpc_bridge_interface.dart';

import 'rpc_bridge_stub.dart'
    if (dart.library.html) 'rpc_bridge_web_impl.dart'
    if (dart.library.io) 'rpc_bridge_native_impl.dart';

class AppRpcBridge {
  static final IRpcBridge instance = RpcBridgeImpl();
}
