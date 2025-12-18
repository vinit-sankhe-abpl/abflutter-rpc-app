// lib/rpc_bridge_native_impl.dart
//
// Native (Android/iOS/desktop) implementation.
// Minimal changes: add JS-bridge fast path (WebView + google.script.run) with readiness gating.
// Fallback remains HTTP POST if runtime not attached.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

// ✅ NEW: for always-alive WebView runtime
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'rpc_bridge_interface.dart';

class AppRpcBridgeNative {
  AppRpcBridgeNative._internal();
  static final AppRpcBridgeNative instance = AppRpcBridgeNative._internal();

  // NOTE: You can keep /exec here for HTTP fallback.
  static const String gasEndpoint =
      "https://script.google.com/macros/s/AKfycbxVMtXvb0DlxGDlhv31W8ot2EIe5Q9TOGB_-xLdG4xwpzKhCMMAFdOKoOtDtuT4enh1pQ/exec";

  int _nextRequestId = 1;

  int _allocateRequestId() {
    final id = _nextRequestId;
    _nextRequestId = _nextRequestId == 0x7fffffff ? 1 : _nextRequestId + 1;
    return id;
  }

  // ---------------------------------------------------------------------------
  // ✅ NEW: GAS JS runtime state
  // ---------------------------------------------------------------------------

  WebViewController? _webViewController;

  // 👇 FORCE transport toggle (true = HTTP, false = JS)
  bool forceHttp = false;

  // Readiness must be driven by GAS page itself.
  bool _gasReady = false;

  // Completer for "ready" so _callGAS can await readiness safely.
  Completer<void>? _readyCompleter;

  // Pending request resolvers for JS path
  final Map<int, Completer<Map<String, dynamic>>> _pendingJs = {};

  // Optional: native can also surface gasResponses later if you want
  final _gasResponseController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get gasResponses =>
      _gasResponseController.stream;

  /// Called once by the always-alive host widget (below).
  void attachWebViewController(WebViewController controller) {
    _webViewController = controller;
    // When a new controller attaches, we must re-handshake.
    _gasReady = false;
    _readyCompleter = Completer<void>();
  }

  /// Called by JavaScriptChannel "ABBridge"
  void handleJsBridgeMessage(String raw) {
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }

    debugPrint("handleJsBridgeMessage at ${DateTime.now().toIso8601String()}");

    // Surface to listeners (log UI etc.)
    _gasResponseController.add(msg);

    // Handshake: GAS page announces it is ready.
    if (msg['type'] == 'GAS_READY') {
      _gasReady = true;
      _readyCompleter?.complete();
      return;
    }

    // Response to a request
    final reqId = msg['requestId'];
    if (reqId is int) {
      final completer = _pendingJs.remove(reqId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(msg);
      }
    } else if (reqId is String) {
      // If GAS returns string, try parse to int to keep your numeric contract
      final parsed = int.tryParse(reqId);
      if (parsed != null) {
        final completer = _pendingJs.remove(parsed);
        if (completer != null && !completer.isCompleted) {
          completer.complete(msg);
        }
      }
    }
  }

  Future<void> _ensureJsReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final c = _webViewController;
    if (c == null) {
      throw StateError("WebView runtime not attached");
    }
    if (_gasReady) return;

    final completer = _readyCompleter ??= Completer<void>();
    await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        "GAS native page not ready (GAS_READY not received)",
      ),
    );
  }

  /// JS fast path: send request to GAS html page via window.__fromFlutter(jsonString)
  Future<Map<String, dynamic>> _callGASViaJs(Map<String, dynamic> body) async {
    try {
      final ts = DateTime.now();
      final controller = _webViewController;
      if (controller == null) {
        throw StateError("WebView runtime not attached");
      }

      await _ensureJsReady(timeout: const Duration(seconds: 20));

      final requestId = body['requestId'];
      if (requestId is! int) {
        throw StateError(
          "requestId must be int (got ${requestId.runtimeType})",
        );
      }
      debugPrint("_callGASViaJs start ${ts.toIso8601String()}");

      final completer = Completer<Map<String, dynamic>>();
      _pendingJs[requestId] = completer;

      // IMPORTANT: Do NOT inline raw JSON into JS; pass as a JS string literal.
      final jsonStr = jsonEncode(body);
      final js =
          '''(function(){
          var msg = { type: 'FROM_FLUTTER', json: ${jsonEncode(jsonStr)} };
          try { window.ABBridge.postMessage(msg, '*'); } catch(e) {}
          try { window.postMessage(msg, '*'); } catch(e) {}
          try {
            for (var i=0; i<window.frames.length; i++) {
              try { window.frames[i].postMessage(msg, '*'); } catch(e2) {}
            }
          } catch(e3) {}
        })();
        ''';

      await controller.runJavaScript(js);

      final resp = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          "Timeout waiting for GAS JS response (requestId=$requestId)",
        ),
      );

      debugPrint("_callGASViaJs end ${DateTime.now().toIso8601String()}");

      return resp;
    } catch (e) {
      return _callGASViaHttp(body);
    }
  }

  // ---------------------------------------------------------------------------
  // Existing HTTP path (kept as fallback, unchanged behavior)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _callGASViaHttp(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse(gasEndpoint);

    http.Response response;

    try {
      response = await http.post(
        uri,
        headers: const {
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: jsonEncode(payload),
      );
    } catch (e) {
      throw Exception("GAS request failed: $e");
    }

    // Handle GAS 30x redirect (common for WebApp exec)
    if (response.statusCode == 302 || response.statusCode == 301) {
      final redirectUrl = response.headers["location"];

      if (redirectUrl == null) {
        throw Exception("GAS returned redirect without a Location header");
      }

      try {
        response = await http.get(Uri.parse(redirectUrl));
      } catch (e) {
        throw Exception("Redirect GET failed: $e");
      }
    }

    final raw = response.body.trim();
    if (raw.isEmpty) {
      throw Exception("Empty response from GAS");
    }

    if (raw.startsWith("<!DOCTYPE html") || raw.startsWith("<html")) {
      throw Exception(
        "GAS returned HTML instead of JSON — likely a permissions or script error.\nBody:\n$raw",
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw Exception("Failed to decode GAS JSON: $e\nBody:\n$raw");
    }

    if (decoded is! Map) {
      throw Exception("Unexpected GAS response type: ${decoded.runtimeType}");
    }

    final Map<String, dynamic> map = decoded is Map<String, dynamic>
        ? decoded
        : decoded.cast<String, dynamic>();

    _gasResponseController.add(map);

    return map;
  }

  // ---------------------------------------------------------------------------
  // ✅ SINGLE SEAM: _callGAS (signature unchanged)
  // - attaches requestId
  // - chooses JS fast path when available + ready
  // - otherwise uses existing HTTP fallback
  // - preserves your exact payloads (deviceevent / temperature etc.)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _callGAS(Map<String, dynamic> payload) async {
    final requestId = _allocateRequestId();

    // Attach requestId to payload (unchanged behavior)
    final Map<String, dynamic> body = {...payload, 'requestId': requestId};

    Map<String, dynamic> map;

    // JS fast-path when WebView runtime exists (mobile)
    final hasJsRuntime = _webViewController != null;

    if (!forceHttp && hasJsRuntime) {
      map = await _callGASViaJs(body);
    } else {
      map = await _callGASViaHttp(body);
    }

    // Verify requestId matches (your existing invariant)
    final respId = map['requestId'];
    final respInt = (respId is int)
        ? respId
        : int.tryParse(respId?.toString() ?? '');
    if (respInt != requestId) {
      throw Exception(
        "GAS response requestId mismatch. Expected $requestId, got $respId",
      );
    }

    // Surface explicit GAS error (your existing invariant)
    if (map['status'] == 'error') {
      final msg = map['message'] ?? 'Unknown GAS error';
      throw Exception("GAS error: $msg");
    }

    return map;
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  // ----------------------------------------------------------
  // Temperature via native location + GAS (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<Map<String, dynamic>> requestTemperature() async {
    if (!await _ensureLocationPermission()) {
      throw Exception("Location permission denied");
    }
    final pos = await Geolocator.getCurrentPosition();
    return _callGAS({
      "action": "temperature",
      "lat": pos.latitude,
      "lng": pos.longitude,
    });
  }

  // ----------------------------------------------------------
  // LOCATION DEVICE EVENT (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<void> sendLocationEvent() async {
    debugPrint("sendLocationEvent at ${DateTime.now().toIso8601String()}");
    if (!await _ensureLocationPermission()) {
      throw Exception("Location permission denied");
    }

    final pos = await Geolocator.getCurrentPosition();

    final resp = await _callGAS({
      "action": "deviceevent",
      "payload": {
        "kind": "location",
        "data": {
          "lat": pos.latitude,
          "lng": pos.longitude,
          "accuracy": pos.accuracy,
        },
      },
    });
    if (resp['status'] != 'success') {
      throw Exception("Device event failed: ${resp['message']}");
    }
  }

  // ----------------------------------------------------------
  // CAMERA DEVICE EVENT (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<void> sendCameraEvent() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.camera);

    if (img == null) return;

    final bytes = await img.readAsBytes();
    final base64Data = base64Encode(bytes);

    final resp = await _callGAS({
      "action": "deviceevent",
      "payload": {
        "kind": "camera",
        "data": "data:image/png;base64,$base64Data",
      },
    });
    if (resp['status'] != 'success') {
      throw Exception("Device event failed: ${resp['message']}");
    }
  }

  // ----------------------------------------------------------
  // MIC DEVICE EVENT (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<void> sendMicEvent() async {
    final recorder = AudioRecorder();

    final hasPerm = await recorder.hasPermission();
    if (!hasPerm) {
      throw Exception("Microphone permission not granted");
    }

    final tempDir = await getTemporaryDirectory();
    final tempPath =
        "${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav";

    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 128000,
        sampleRate: 16000,
      ),
      path: tempPath,
    );

    await Future.delayed(const Duration(seconds: 3));

    final path = await recorder.stop();
    if (path == null) return;

    final bytes = await File(path).readAsBytes();
    final b64 = base64Encode(bytes);

    final resp = await _callGAS({
      "action": "deviceevent",
      "payload": {
        "kind": "mic",
        "data": "data:audio/wav;base64,$b64",
        "meta": {"duration_sec": 3},
      },
    });
    if (resp['status'] != 'success') {
      throw Exception("Device event failed: ${resp['message']}");
    }
  }

  // ----------------------------------------------------------
  // VANILLA DEVICE EVENT (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<void> sendVanillaEvent() async {
    final resp = await _callGAS({
      "action": "deviceevent",
      "payload": {"kind": "vanilla"},
    });
    if (resp['status'] != 'success') {
      throw Exception("Device event failed: ${resp['message']}");
    }
  }

  // ----------------------------------------------------------
  // FILE DEVICE EVENT (UNCHANGED PAYLOAD)
  // ----------------------------------------------------------
  Future<void> sendFileEvent() async {
    final result = await FilePicker.platform.pickFiles(withData: true);

    if (result == null) return;

    final f = result.files.first;
    if (f.bytes == null) return;

    final mime = lookupMimeType(f.name) ?? 'application/octet-stream';
    final b64 = base64Encode(f.bytes!);

    final resp = await _callGAS({
      "action": "deviceevent",
      "payload": {
        "kind": "file",
        "data": "data:$mime;base64,$b64",
        "meta": {"name": f.name, "size": f.size, "mime": mime},
      },
    });
    if (resp['status'] != 'success') {
      throw Exception("Device event failed: ${resp['message']}");
    }
  }
}

// -----------------------------------------------------------------------------
// ✅ NEW: Always-alive WebView host widget (native only)
// You add this ONCE above MaterialApp so it survives routes.
// -----------------------------------------------------------------------------

class GasNativeRuntimeHost extends StatefulWidget {
  final Widget child;
  const GasNativeRuntimeHost({super.key, required this.child});

  @override
  State<GasNativeRuntimeHost> createState() => _GasNativeRuntimeHostState();
}

class _GasNativeRuntimeHostState extends State<GasNativeRuntimeHost> {
  WebViewController? _controller;
  bool _forceHttp = false;

  @override
  void initState() {
    super.initState();

    // This file is only in dart.library.io build, so safe.

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'ABBridge',
        onMessageReceived: (msg) {
          AppRpcBridgeNative.instance.handleJsBridgeMessage(msg.message);
        },
      )
      ..loadRequest(Uri.parse('${AppRpcBridgeNative.gasEndpoint}?mode=native'));

    AppRpcBridgeNative.instance.attachWebViewController(controller);
    _controller = controller;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned(
          right: 12,
          bottom: 12,
          child: FloatingActionButton.extended(
            heroTag: 'transport-toggle',
            backgroundColor: (_forceHttp ? Colors.lightBlue : Colors.lightGreen)
                .withValues(alpha: 0.35),
            icon: Icon(_forceHttp ? Icons.web : Icons.flash_on),
            label: Text(_forceHttp ? 'HTTP' : 'JS'),
            onPressed: () {
              setState(() {
                _forceHttp = !_forceHttp;
                AppRpcBridgeNative.instance.forceHttp = _forceHttp;
              });
            },
          ),
        ),
        Offstage(
          offstage: true,
          child: SizedBox(
            width: 1,
            height: 1,
            child: WebViewWidget(controller: controller),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// IRpcBridge adapter (Native) — minimal changes:
// - gasResponses now wired (was null)
// -----------------------------------------------------------------------------

class RpcBridgeImpl implements IRpcBridge {
  @override
  Future<void> init() async {
    // no-op for native
  }

  @override
  Stream<Map<String, dynamic>>? get gasResponses =>
      AppRpcBridgeNative.instance.gasResponses;

  @override
  Widget wrapApp(Widget app) {
    return GasNativeRuntimeHost(child: app);
  }

  @override
  Future<Map<String, dynamic>> requestTemperature() =>
      AppRpcBridgeNative.instance.requestTemperature();

  @override
  Future<void> sendCameraEvent() =>
      AppRpcBridgeNative.instance.sendCameraEvent();

  @override
  Future<void> sendMicEvent() => AppRpcBridgeNative.instance.sendMicEvent();

  @override
  Future<void> sendFileEvent() => AppRpcBridgeNative.instance.sendFileEvent();

  @override
  Future<void> sendLocationEvent() =>
      AppRpcBridgeNative.instance.sendLocationEvent();

  @override
  Future<void> sendVanillaEvent() =>
      AppRpcBridgeNative.instance.sendVanillaEvent();
}
