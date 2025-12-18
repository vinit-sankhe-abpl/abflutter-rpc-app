// lib/rpc_bridge_web_impl.dart
//
// Web-side implementation that talks to GAS via the wrapper iframe.
// Minimal changes: introduce numeric requestId and match responses atomically.

@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'rpc_bridge_interface.dart';

@JS('window.parent.postMessage')
external void _jsPostMessage(JSAny? message, JSAny? targetOrigin);

@JS('rpcCaptureCamera')
external JSPromise _rpcCaptureCameraJs();

@JS('rpcRecordAudio')
external JSPromise _rpcRecordAudioJs([int durationMs = 3000]);

class AppRpcBridgeWeb {
  AppRpcBridgeWeb._();
  static final AppRpcBridgeWeb instance = AppRpcBridgeWeb._();

  bool _connected = false;
  bool _iframeDetected = false;
  bool _handshakeCompleted = false;
  String? _parentOrigin;

  // Numeric request counter for correlation
  int _nextRequestId = 1;

  final _gasResponseController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get gasResponses =>
      _gasResponseController.stream;

  int _allocateRequestId() {
    // simple monotonically increasing integer; wrap if it overflows
    final id = _nextRequestId;
    _nextRequestId = _nextRequestId == 0x7fffffff ? 1 : _nextRequestId + 1;
    return id;
  }

  // Detect iframe presence safely
  bool get _hasIframe {
    final self = jsu.getProperty(web.window, 'self');
    final top = jsu.getProperty(web.window, 'top');
    return self != top;
  }

  bool get isOperational => _connected && _iframeDetected;

  Future<void> init() async {
    _iframeDetected = _hasIframe;

    if (!_iframeDetected) {
      // No parent wrapper — we stay in fallback mode
      print("⚠ Web RPC: No parent iframe detected — switching to fallback.");
      return;
    }

    _setupMessageListener();

    // initial hello; parent responds with parent-init
    _postToParent({'type': 'child-hello'}, '*');
  }

  void _setupMessageListener() {
    web.window.addEventListener(
      'message',
      ((web.Event event) {
        final msgEvent = event as web.MessageEvent;
        final jsData = msgEvent.data;
        if (jsData == null) return;

        final dynamic obj = jsu.dartify(jsData);
        if (obj is! Map) return;

        final Map<String, dynamic> data = {};
        obj.forEach((k, v) {
          if (k is String) data[k] = v;
        });

        final type = data['type']?.toString();
        if (type == null) return;

        if (type == 'parent-init') {
          if (_handshakeCompleted) return;

          _handshakeCompleted = true;
          _connected = true;
          _parentOrigin = msgEvent.origin;

          if (_parentOrigin != null && _parentOrigin!.isNotEmpty) {
            _postToParent({'type': 'child-ready'}, _parentOrigin!);
          }
          return;
        }

        if (type == 'gas-response') {
          _gasResponseController.add(data);
          return;
        }
      }).toJS,
    );
  }

  void _postToParent(Map<String, dynamic> msg, String targetOrigin) {
    if (!_iframeDetected) {
      print("⚠ postMessage() skipped — no iframe.");
      return;
    }

    final jsMsg = jsu.jsify(msg);
    _jsPostMessage(jsMsg, targetOrigin.toJS);
  }

  // ------------------------------------------
  // RPC with explicit requestId correlation
  // ------------------------------------------

  Future<Map<String, dynamic>> sendRpc({
    required String action,
    Map<String, dynamic>? params,
  }) async {
    if (!isOperational) {
      return Future.error(
        "Web RPC unavailable — not inside GAS wrapper iframe.",
      );
    }

    final requestId = _allocateRequestId();
    final completer = Completer<Map<String, dynamic>>();

    late StreamSubscription sub;
    sub = gasResponses.listen((msg) {
      final msgId = msg['requestId'];
      if (msgId == requestId) {
        sub.cancel();

        if (msg.containsKey('error')) {
          completer.completeError(msg['error']);
          return;
        }

        final result = msg['result'];
        if (result is Map<String, dynamic>) {
          completer.complete(result);
          return;
        }

        final Map<String, dynamic> normalized = {};
        if (result is Map) {
          result.forEach((k, v) {
            if (k is String) normalized[k] = v;
          });
        }
        completer.complete(normalized);
      }
    });

    _postToParent({
      'type': 'flutter-request',
      'requestId': requestId,
      'payload': {'action': action, ...?params},
    }, _parentOrigin ?? '*');

    return completer.future;
  }

  // ------------------------------------------
  // DEVICE EVENTS — with requestId + ACK wait
  // ------------------------------------------

  Future<void> sendDeviceEvent({
    required String kind,
    dynamic data,
    Map<String, dynamic>? meta,
  }) async {
    if (!_connected || _parentOrigin == null || _parentOrigin!.isEmpty) {
      throw StateError(
        "Device event '$kind' cannot reach GAS (not inside GAS iframe)",
      );
    }

    final requestId = _allocateRequestId();
    final completer = Completer<void>();

    late StreamSubscription sub;
    sub = gasResponses.listen((msg) {
      final msgId = msg['requestId'];
      if (msgId == requestId) {
        sub.cancel();

        if (msg.containsKey('error')) {
          completer.completeError(msg['error']);
        } else {
          // For device events we only care that it succeeded.
          completer.complete();
        }
      }
    });

    _postToParent({
      'type': 'deviceevent', // MUST match wrapper.html
      'requestId': requestId,
      'payload': {'kind': kind, 'data': data, 'meta': meta},
    }, _parentOrigin!);

    return completer.future;
  }

  // ------------------------------------------
  // LOCATION → temperature lookup
  // ------------------------------------------

  Future<Map<String, dynamic>> requestTemperature() async {
    if (!isOperational) {
      return Future.error("Web RPC unavailable — fallback to native mode.");
    }

    final geoloc = web.window.navigator.geolocation;
    final pos = await _getPos(geoloc);

    return sendRpc(
      action: 'temperature',
      params: {'lat': pos.coords.latitude, 'lng': pos.coords.longitude},
    );
  }

  Future<web.GeolocationPosition> _getPos(web.Geolocation geoloc) {
    final completer = Completer<web.GeolocationPosition>();

    geoloc.getCurrentPosition(
      ((web.GeolocationPosition pos) {
        if (!completer.isCompleted) completer.complete(pos);
      }).toJS,
      ((web.GeolocationPositionError err) {
        if (!completer.isCompleted) {
          completer.completeError(StateError("Geo error: ${err.message}"));
        }
      }).toJS,
    );

    return completer.future;
  }

  //-------------------------------------------
  // Camera / microphone (JS-only)
  //-------------------------------------------

  Future<void> sendCameraEvent() async {
    if (!isOperational) {
      throw StateError("Camera unavailable — no GAS iframe.");
    }
    final data = await jsu.promiseToFuture<String>(_rpcCaptureCameraJs());
    await sendDeviceEvent(kind: 'camera', data: data);
  }

  Future<void> sendMicEvent() async {
    if (!isOperational) {
      throw StateError("Mic unavailable — no GAS iframe.");
    }
    final data = await jsu.promiseToFuture<String>(_rpcRecordAudioJs(3000));
    await sendDeviceEvent(kind: 'mic', data: data, meta: {'duration_sec': 3});
  }

  // ----------------------------------------------------------
  // VANILLA DEVICE EVENT
  // ----------------------------------------------------------
  Future<void> sendVanillaEvent() async {
    await sendDeviceEvent(kind: 'vanilla', data: {}, meta: {});
  }

  //-------------------------------------------
  // File picker
  //-------------------------------------------

  Future<void> sendFileEvent() async {
    final input = web.HTMLInputElement();
    input.type = 'file';
    input.accept = '*/*';

    final changeCompleter = Completer<void>();
    input.onchange = ((web.Event e) {
      if (!changeCompleter.isCompleted) changeCompleter.complete();
    }).toJS;

    input.click();
    await changeCompleter.future;

    final files = input.files;
    if (files == null || files.length == 0) return;

    final file = files.item(0);
    if (file == null) return;

    final reader = web.FileReader();

    final loadCompleter = Completer<void>();

    reader.onload = ((web.ProgressEvent e) {
      if (!loadCompleter.isCompleted) loadCompleter.complete();
    }).toJS;

    reader.onerror = ((web.ProgressEvent e) {
      if (!loadCompleter.isCompleted) {
        loadCompleter.completeError(StateError("FileReader error"));
      }
    }).toJS;

    reader.readAsDataURL(file);
    await loadCompleter.future;

    final result = reader.result;
    if (result == null) return;

    final dataUrl = result.toString();
    final mime = file.type;

    await sendDeviceEvent(
      kind: 'file',
      data: dataUrl,
      meta: {'name': file.name, 'size': file.size, 'mime': mime},
    );
  }

  //-------------------------------------------
  // Location event
  //-------------------------------------------

  Future<void> sendLocationEvent() async {
    if (!isOperational) {
      throw StateError("Location unavailable — not inside GAS iframe.");
    }

    final geoloc = web.window.navigator.geolocation;
    final pos = await _getPos(geoloc);

    await sendDeviceEvent(
      kind: 'location',
      data: {
        'lat': pos.coords.latitude,
        'lng': pos.coords.longitude,
        'accuracy': pos.coords.accuracy,
      },
    );
  }
}

// -----------------------------------------------------------------------------
// IRpcBridge adapter (Web)
// -----------------------------------------------------------------------------

class RpcBridgeImpl implements IRpcBridge {
  @override
  Future<void> init() => AppRpcBridgeWeb.instance.init();

  @override
  Stream<Map<String, dynamic>>? get gasResponses =>
      AppRpcBridgeWeb.instance.gasResponses;

  @override
  Widget wrapApp(Widget app) {
    return app;
  }

  @override
  Future<Map<String, dynamic>> requestTemperature() =>
      AppRpcBridgeWeb.instance.requestTemperature();

  @override
  Future<void> sendCameraEvent() => AppRpcBridgeWeb.instance.sendCameraEvent();

  @override
  Future<void> sendMicEvent() => AppRpcBridgeWeb.instance.sendMicEvent();

  @override
  Future<void> sendFileEvent() => AppRpcBridgeWeb.instance.sendFileEvent();

  @override
  Future<void> sendLocationEvent() =>
      AppRpcBridgeWeb.instance.sendLocationEvent();

  @override
  Future<void> sendVanillaEvent() =>
      AppRpcBridgeWeb.instance.sendVanillaEvent();
}
