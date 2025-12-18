import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'rpc_bridge.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppRpcBridge.instance.init();
  runApp(const RpcDemoApp());
}

class RpcDemoApp extends StatelessWidget {
  const RpcDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GAS RPC POC',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: AppRpcBridge.instance.wrapApp(const RpcDemoHomePage()),
      debugShowCheckedModeBanner: false,
    );
  }
}

class RpcDemoHomePage extends StatefulWidget {
  const RpcDemoHomePage({super.key});

  @override
  State<RpcDemoHomePage> createState() => _RpcDemoHomePageState();
}

class _RpcDemoHomePageState extends State<RpcDemoHomePage> {
  final List<String> _logs = [];
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AppRpcBridge.instance.gasResponses?.listen((msg) {
      _log('[GAS RESPONSE] $msg at ${DateTime.now().toIso8601String()}');
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _log(String msg) {
    setState(() {
      _logs.add(msg);
    });
  }

  Future<void> _wrap(String label, Future<void> Function() fn) async {
    _log('$label... ${DateTime.now().toIso8601String()}');
    try {
      await fn();
      _log('$label ✅ done at ${DateTime.now().toIso8601String()}\n');
    } catch (e) {
      _log('$label ❌ error: $e at ${DateTime.now().toIso8601String()}\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = kIsWeb
        ? 'Web (iframe → postMessage → google.script.run)'
        : 'Native (HTTP POST → GAS WebApp)';

    return Scaffold(
      appBar: AppBar(
        title: const Text('GAS RPC POC — Flutter Client'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () => _wrap('Get Temperature', () async {
                  final result = await AppRpcBridge.instance
                      .requestTemperature();
                  _log(
                    'Temperature result: $result at ${DateTime.now().toIso8601String()}',
                  );
                }),
                child: const Text('Get Temperature'),
              ),
              ElevatedButton(
                onPressed: () => _wrap(
                  'Make Vanilla Call',
                  AppRpcBridge.instance.sendVanillaEvent,
                ),
                child: const Text('Make Vanilla Call'),
              ),
              ElevatedButton(
                onPressed: () => _wrap(
                  'Capture Camera',
                  AppRpcBridge.instance.sendCameraEvent,
                ),
                child: const Text('Capture Camera'),
              ),
              ElevatedButton(
                onPressed: () => _wrap(
                  'Send Location',
                  AppRpcBridge.instance.sendLocationEvent,
                ),
                child: const Text('Send Location'),
              ),
              ElevatedButton(
                onPressed: () =>
                    _wrap('Pick File', AppRpcBridge.instance.sendFileEvent),
                child: const Text('Pick File'),
              ),
              ElevatedButton(
                onPressed: () =>
                    _wrap('Record Mic', AppRpcBridge.instance.sendMicEvent),
                child: const Text('Record Mic (3s)'),
              ),
            ],
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.grey.shade100,
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: TextEditingController(text: _logs.join('\n')),
                readOnly: true,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
