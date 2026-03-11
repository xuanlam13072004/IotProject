import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart' as config;

enum ConnectivityMode { local, cloud, offline }

class ConnectivityService {
  ConnectivityService._internal();
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;

  final ValueNotifier<ConnectivityMode> modeNotifier =
      ValueNotifier<ConnectivityMode>(ConnectivityMode.offline);

  String _currentBaseUrl = config.cloudUrl;
  Timer? _timer;

  String get currentBaseUrl => _currentBaseUrl;
  ConnectivityMode get mode => modeNotifier.value;
  bool get isLocalMode => mode == ConnectivityMode.local;
  bool get isCloudMode => mode == ConnectivityMode.cloud;
  bool get isOffline => mode == ConnectivityMode.offline;

  /// Face AI base URL (local or cloud based on current mode)
  String get faceAiBaseUrl =>
      isLocalMode ? config.faceAiLocalBase : config.faceAiCloudBase;

  /// Voice/audio_control base URL (local or cloud based on current mode)
  String get voiceBaseUrl =>
      isLocalMode ? config.voiceLocalUrl : config.voiceCloudUrl;

  /// ESP32-CAM snapshot URL (local direct or cloud proxy based on current mode)
  String camSnapshotUrl({int? ts}) {
    if (isLocalMode) {
      final suffix = ts != null ? '?ts=$ts' : '';
      return '${config.esp32CamLocalBase}/snapshot.jpg$suffix';
    }
    // Cloud: use backend_account proxy, need auth token
    final suffix = ts != null ? '?ts=$ts' : '';
    return '${config.esp32CamCloudSnapshotUrl}$suffix';
  }

  /// Start periodic probing and run an immediate probe once.
  void startMonitoring({Duration? interval}) {
    _timer?.cancel();
    _timer = Timer.periodic(
      interval ?? config.connectivityProbeInterval,
      (_) => findBestConnection(),
    );
    // Immediate first check
    // Fire-and-forget; caller can also await if needed.
    // ignore: discarded_futures
    findBestConnection();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Returns best available mode (LOCAL preferred, else CLOUD, else OFFLINE)
  Future<ConnectivityMode> findBestConnection({Duration? timeout}) async {
    final Duration probeTimeout = timeout ?? config.connectivityProbeTimeout;
    final String localOrigin = _originFromBase(config.localUrl);
    final String cloudOrigin = _originFromBase(config.cloudUrl);

    // 1) Try LOCAL first
    final bool localOk = await _probe(
      origin: localOrigin,
      timeout: probeTimeout,
    );
    if (localOk) {
      _setMode(ConnectivityMode.local, config.localUrl);
      return ConnectivityMode.local;
    }

    // 2) Fallback to CLOUD (Cloudflare Tunnel)
    final bool cloudOk = await _probe(
      origin: cloudOrigin,
      timeout: probeTimeout,
    );
    if (cloudOk) {
      _setMode(ConnectivityMode.cloud, config.cloudUrl);
      return ConnectivityMode.cloud;
    }

    // 3) Both failed -> OFFLINE (keep cloud as base to allow future recoveries)
    _setMode(ConnectivityMode.offline, config.cloudUrl);
    return ConnectivityMode.offline;
  }

  /// Build request headers with Authorization.
  Map<String, String> buildHeaders(
      {String? token, Map<String, String>? extra}) {
    final Map<String, String> headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    if (extra != null) headers.addAll(extra);
    return headers;
  }

  /// Convenience to create a Uri against the current base URL.
  Uri uri(String path) {
    final String trimmed = path.startsWith('/') ? path.substring(1) : path;
    final String base = _currentBaseUrl.endsWith('/')
        ? _currentBaseUrl.substring(0, _currentBaseUrl.length - 1)
        : _currentBaseUrl;
    return Uri.parse('$base/$trimmed');
  }

  void _setMode(ConnectivityMode m, String baseUrl) {
    if (_currentBaseUrl != baseUrl) {
      _currentBaseUrl = baseUrl;
    }
    if (modeNotifier.value != m) {
      modeNotifier.value = m;
    }
  }

  Future<bool> _probe({
    required String origin,
    required Duration timeout,
  }) async {
    final Uri url = Uri.parse('$origin${config.connectivityHealthPath}');

    final http.Client client = http.Client();
    try {
      final http.Response resp = await client.get(url).timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  String _originFromBase(String base) {
    // Drop trailing /api or /api/{...}
    return base.replaceFirst(RegExp(r"/api/?$"), '');
  }
}

// Export a shared singleton instance for easy access.
final ConnectivityService connectivityService = ConnectivityService();
