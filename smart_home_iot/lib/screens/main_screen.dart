import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/connectivity_service.dart';
import '../services/notification_service.dart';
import '../services/voice_api_service.dart'; // Từ File 1
import '../widgets/device_dashboard.dart';
import '../main.dart';
import 'history_screen.dart';
import 'admin_manage_users.dart';

// Import thêm từ File 2
import 'door_cam_screen.dart';
import '../widgets/esp32_cam_menu.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const _bgColor = Color(0xFFDCE5F0);
  static const _textColor = Color(0xFF3E4E5E);
  static const _accentColor = Color(0xFF5D9CEC);
  static const _sessionTimeout = 5 * 60 * 1000; // 5 phút

  int _currentIndex = 0;
  bool _isAdmin = false;
  Map<String, dynamic> _permissions = {};
  bool _permissionsLoaded = false;

  // --- LOGIC TỪ FILE 1 (VOICE CONTROL) ---
  final AudioRecorder _voiceRecorder = AudioRecorder();
  late final VoiceApiService _voiceApi;
  bool _isVoiceRecording = false;
  bool _isVoiceBusy = false;

  // --- LOGIC TỪ FILE 2 (ESP32-CAM) ---
  bool _isDoorCamLoading = false;

  // --- SESSION TIMEOUT ---
  Timer? _sessionCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Khởi tạo VoiceApi từ File 1
    _voiceApi =
        VoiceApiService(baseUrl: () => connectivityService.voiceBaseUrl);
    _loadRoleAndPermissions();
    _updateLastActive();
    // Kiểm tra phiên mỗi 1 phút ngay cả khi app đang mở
    _sessionCheckTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _checkSessionTimeout(),
    );
  }

  @override
  void dispose() {
    _sessionCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Hủy Recorder từ File 1
    _voiceRecorder.dispose();
    super.dispose();
  }

  Future<void> _loadRoleAndPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('user_role') ?? 'user';

    setState(() {
      _isAdmin = role == 'admin';
    });

    // Load permissions from backend
    await _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');
      if (token == null) {
        if (mounted) setState(() => _permissionsLoaded = true);
        return;
      }

      final url = connectivityService.uri('/accounts/me/permissions');
      final response = await http.get(
        url,
        headers: connectivityService.buildHeaders(token: token),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = (data['permissions'] ?? {}) as Map<String, dynamic>;
        final merged = _withDefaultPermissions(raw);
        if (mounted) {
          setState(() {
            _permissions = merged;
            _permissionsLoaded = true;
          });
        }
      } else {
        // Lấy logic xử lý lỗi fallback từ File 2
        if (mounted) {
          setState(() {
            _permissions = _withDefaultPermissions({});
            _permissionsLoaded = true;
          });
        }
      }
    } catch (e) {
      print('Error loading permissions: $e');
      // Lấy logic xử lý lỗi fallback từ File 2
      if (mounted) {
        setState(() {
          _permissions = _withDefaultPermissions({});
          _permissionsLoaded = true;
        });
      }
    }
  }

  Map<String, dynamic> _withDefaultPermissions(Map<String, dynamic> raw) {
    if (raw.isEmpty) {
      return {
        'door': {'view': true, 'open': false, 'close': false},
        'awning': {
          'view': true,
          'open': false,
          'close': false,
          'setMode': false
        },
        'alarm': {
          'view': true,
          'snooze': false,
          'cancelSnooze': false,
          'snoozeAll': false,
          'snoozeFire': false,
          'snoozeGas': false
        },
        'sensors': {
          'viewTemperature': true,
          'viewHumidity': true,
          'viewGas': true,
          'viewFire': true
        },
        'voice': {'use': false},
        'camera': {'use': false},
      };
    }

    final result = <String, dynamic>{};
    raw.forEach((category, value) {
      if (value is Map) {
        result[category] = Map<String, dynamic>.from(value);
      } else {
        result[category] = value;
      }
    });
    return result;
  }

  bool _hasPermission(String category, String action) {
    if (_isAdmin) return true;
    final categoryPerms = _permissions[category];
    if (categoryPerms is! Map) return false;
    return categoryPerms[action] == true;
  }

  String _getFriendlyMessage(String action) {
    final baseAction = action.split('&').first;

    String sensorInfo = '';
    if (action.contains('sensor=')) {
      final sensorMatch = RegExp(r'sensor=(\w+)').firstMatch(action);
      if (sensorMatch != null) {
        final sensor = sensorMatch.group(1);
        if (sensor == 'fire') {
          sensorInfo = ' (Fire)';
        } else if (sensor == 'gas') {
          sensorInfo = ' (Gas)';
        } else if (sensor == 'all') {
          sensorInfo = ' (All)';
        }
      }
    }

    const Map<String, String> actionMessages = {
      'open_door': 'Sent command: Open Main Door.',
      'close_door': 'Sent command: Close Main Door.',
      'open_awning': 'Sent command: Open Awning.',
      'close_awning': 'Sent command: Close Awning.',
      'set_auto': 'Switched Awning to Auto mode.',
      'set_manual': 'Switched Awning to Manual mode.',
      'set_snooze': 'Alarm snoozed',
      'cancel_snooze': 'Alarm reactivated',
    };

    final baseMessage =
        actionMessages[baseAction] ?? 'Sent command: $baseAction';
    return baseMessage + sensorInfo + (sensorInfo.isNotEmpty ? '' : '.');
  }

  Future<void> _sendCommand(String action) async {
    _updateLastActive();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    if (token == null) {
      if (mounted) {
        NotificationService.show(context, 'Not logged in!', true);
      }
      return;
    }

    final parts = action.split('&');
    final baseAction = parts[0];
    final params = <String, dynamic>{};

    for (int i = 1; i < parts.length; i++) {
      final kv = parts[i].split('=');
      if (kv.length == 2) {
        params[kv[0]] = kv[1];
      }
    }

    final url = connectivityService.uri('/devices/$deviceId/control');
    try {
      final body = <String, dynamic>{
        'action': baseAction,
      };

      if (params.isNotEmpty) {
        body.addAll(params);
      }

      final response = await http.post(
        url,
        headers: connectivityService.buildHeaders(token: token),
        body: jsonEncode(body),
      );

      if (!mounted) return;
      if (response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 202) {
        NotificationService.show(
          context,
          _getFriendlyMessage(action),
          false,
        );
      } else {
        NotificationService.show(
          context,
          'Command failed, please try again!',
          true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      NotificationService.show(
          context, 'Command failed, please try again!', true);
    }
  }

  /* ================= LOGIC VOICE (TỪ FILE 1) ================= */

  Future<void> _onVoiceFabPressed() async {
    if (_isVoiceBusy) return;

    if (_isVoiceRecording) {
      await _stopAndProcessVoiceCommand();
      return;
    }

    await _startVoiceRecording();
  }

  Future<void> _startVoiceRecording() async {
    final hasPermission = await _voiceRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        NotificationService.show(
            context, 'Microphone permission is required.', true);
      }
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final filePath =
          '${tempDir.path}${Platform.pathSeparator}voice_cmd_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _voiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 128000,
        ),
        path: filePath,
      );

      if (!mounted) return;
      setState(() => _isVoiceRecording = true);
      NotificationService.show(context, 'Listening voice command...', false);
    } catch (_) {
      if (!mounted) return;
      NotificationService.show(
          context, 'Could not start voice recording.', true);
    }
  }

  Future<void> _stopAndProcessVoiceCommand() async {
    setState(() {
      _isVoiceBusy = true;
    });

    try {
      final path = await _voiceRecorder.stop();
      if (path == null || path.isEmpty) {
        if (mounted) {
          NotificationService.show(context, 'No audio captured.', true);
        }
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final ownerId = prefs.getString('user_username') ?? 'home_owner';

      final verifyRes = await _voiceApi.verify(
        ownerId: ownerId,
        sample: File(path),
      );

      if (!mounted) return;

      if (verifyRes['is_valid'] != true) {
        final msg = verifyRes['message']?.toString() ??
            'Voice verification failed. Command rejected.';
        NotificationService.show(context, msg, true);
        return;
      }

      final processingError = verifyRes['processing_stage_error']?.toString();
      if (processingError != null && processingError.isNotEmpty) {
        NotificationService.show(
            context, 'Voice translation error: $processingError', true);
        return;
      }

      final processingStage = verifyRes['processing_stage'];
      Map<String, dynamic>? actionJson;
      if (processingStage is Map) {
        final rawAction = processingStage['action_json'];
        if (rawAction is Map) {
          actionJson = Map<String, dynamic>.from(rawAction);
        }
      }

      // Check if server already dispatched the command successfully
      if (processingStage is Map) {
        final dispatch = processingStage['backend_dispatch'];
        if (dispatch is Map && dispatch['status'] == 'accepted') {
          final corrected = actionJson?['corrected_text']?.toString() ?? '';
          final label = corrected.isEmpty
              ? 'Voice command executed.'
              : 'Executed: "$corrected"';
          NotificationService.show(context, label, false);
          return;
        }
      }

      // Server didn't dispatch — map and send from client
      final translatedAction = _mapProcessingActionToDeviceAction(actionJson);

      if (translatedAction == null) {
        final transcript = processingStage is Map<String, dynamic>
            ? (processingStage['transcript_text']?.toString() ?? '')
            : '';
        final displayText =
            transcript.isEmpty ? 'Unknown voice command.' : transcript;
        NotificationService.show(
          context,
          'Could not map command: "$displayText"',
          true,
        );
        return;
      }

      await _sendCommand(translatedAction);
    } catch (e) {
      if (mounted) {
        // Extract a human-readable message from the exception
        final raw = e.toString();
        final detail = raw.startsWith('Exception: ')
            ? raw.substring('Exception: '.length)
            : raw;
        NotificationService.show(context, detail, true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVoiceRecording = false;
          _isVoiceBusy = false;
        });
      }
    }
  }

  String? _mapProcessingActionToDeviceAction(Map<String, dynamic>? actionJson) {
    if (actionJson == null) return null;

    // --- NEW format: backend_action from Gemini + server normalization ---
    final backendAction =
        (actionJson['backend_action'] ?? '').toString().trim();
    if (backendAction.isNotEmpty && backendAction != 'unknown') {
      const validActions = {
        'open_door',
        'close_door',
        'open_awning',
        'close_awning',
        'set_auto',
        'set_manual',
        'set_snooze',
        'cancel_snooze',
      };
      if (validActions.contains(backendAction)) {
        String result = backendAction;
        final params = actionJson['parameters'];
        if (params is Map) {
          if (params['sensor'] != null) {
            result += '&sensor=${params['sensor']}';
          }
          if (params['seconds'] != null) {
            result += '&seconds=${params['seconds']}';
          }
        }
        return result;
      }
    }

    // --- LEGACY format: action=set_field, target_field, value ---
    final actionType = (actionJson['action'] ?? '').toString();
    final targetField = (actionJson['target_field'] ?? '').toString();
    final dynamic rawValue = actionJson['value'];

    bool? value;
    if (rawValue is bool) {
      value = rawValue;
    } else if (rawValue is String) {
      if (rawValue.toLowerCase() == 'true') {
        value = true;
      }
      if (rawValue.toLowerCase() == 'false') {
        value = false;
      }
    }

    if (actionType != 'set_field' || value == null) {
      return null;
    }

    switch (targetField) {
      case 'doorOpen':
        return value ? 'open_door' : 'close_door';
      case 'awningOpen':
        return value ? 'open_awning' : 'close_awning';
      case 'awningAutoMode':
        return value ? 'set_auto' : 'set_manual';
      default:
        return null;
    }
  }

  /* ================= LOGIC ESP32-CAM (TỪ FILE 2) ================= */

  Future<void> _openDoorByEsp32Cam() async {
    if (_isDoorCamLoading) return;
    setState(() => _isDoorCamLoading = true);
    try {
      final base = esp32CamLocalBase;
      final healthUri = Uri.parse('$base/');
      final openUri = Uri.parse('$base$esp32CamOpenDoorPath');

      // Preflight nhanh để phân biệt "sai IP/không tới được ESP32-CAM"
      // với "đang xử lý lâu ở /open_cam".
      try {
        await http.get(healthUri).timeout(const Duration(seconds: 2));
      } catch (_) {
        if (!mounted) return;
        NotificationService.show(
          context,
          'Không kết nối được ESP32-CAM tại $base (kiểm tra IP/WiFi).',
          true,
        );
        return;
      }

      // /open_cam có thể mất thời gian (chụp + gọi Face AI + gửi lệnh) nên timeout dài hơn
      final resp = await http.get(openUri).timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (resp.statusCode != 200) {
        NotificationService.show(
          context,
          'ESP32-CAM error: HTTP ${resp.statusCode} (url=$openUri)',
          true,
        );
        return;
      }

      final data = jsonDecode(resp.body);
      final ok = data is Map && (data['ok'] == true);

      if (ok) {
        final identity = (data['identity'] ?? '').toString();
        NotificationService.show(
          context,
          identity.isEmpty
              ? 'Đã gửi lệnh mở cửa (ESP32-CAM).'
              : 'Xác thực OK ($identity) → đã gửi lệnh mở cửa.',
          false,
        );
      } else {
        final step = data is Map ? (data['step'] ?? '').toString() : '';
        final identity = data is Map ? (data['identity'] ?? '').toString() : '';
        final msg = data is Map ? (data['message'] ?? '').toString() : '';
        NotificationService.show(
          context,
          'Mở cửa bằng ESP32-CAM thất bại'
          '${step.isNotEmpty ? ' (step=$step)' : ''}'
          '${identity.isNotEmpty ? ' identity=$identity' : ''}'
          '${msg.isNotEmpty ? ' msg=$msg' : ''}',
          true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      NotificationService.show(
        context,
        'Lỗi kết nối ESP32-CAM: $e (base=$esp32CamLocalBase)',
        true,
      );
    } finally {
      if (mounted) {
        setState(() => _isDoorCamLoading = false);
      }
    }
  }

  /* ================= UI WIDGETS ================= */

  Widget _buildBody() {
    if (!_permissionsLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (_currentIndex) {
      case 0: // Dashboard
        return DeviceDashboard(
          enabled: true,
          onAction: _sendCommand,
          isAdmin: _isAdmin,
          permissions: _permissions,
          // Bổ sung callback từ File 2 vào File 1
          onEsp32FaceAuth: _openDoorByEsp32Cam,
        );
      case 1: // History
        return HistoryContent(isAdmin: _isAdmin);
      case 2: // Admin/Manage
        if (_isAdmin) {
          return const AdminManageUsersScreen();
        } else {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock, size: 64, color: _textColor.withOpacity(0.3)),
                const SizedBox(height: 16),
                Text(
                  'Admin access only',
                  style: TextStyle(
                    color: _textColor.withOpacity(0.5),
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }
      default:
        return const Center(child: Text('Unknown tab'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: _buildBody(),
      floatingActionButton: _currentIndex == 0 && _hasPermission('voice', 'use')
          ? FloatingActionButton(
              onPressed: _onVoiceFabPressed,
              backgroundColor:
                  _isVoiceRecording ? Colors.redAccent : _accentColor,
              tooltip:
                  _isVoiceRecording ? 'Stop voice command' : 'Voice command',
              child: _isVoiceBusy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : (_isVoiceRecording
                      ? const Icon(Icons.stop)
                      : SizedBox(
                          width: 40,
                          height: 40,
                          child: Lottie.asset(
                            'assets/icon/microphone.json',
                            fit: BoxFit.contain,
                            repeat: true,
                          ),
                        )),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // Giữ nguyên toàn bộ UI của BottomNavigationBar từ cả 2 file
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: _bgColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              offset: const Offset(0, -2),
              blurRadius: 8,
            ),
          ],
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          currentIndex: _currentIndex,
          selectedItemColor: _accentColor,
          unselectedItemColor: _textColor.withOpacity(0.5),
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.tune),
              label: 'Control',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: 'History',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.manage_accounts),
              label: 'Manage',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.logout, color: Colors.redAccent),
              label: 'Đăng xuất',
            ),
          ],
          onTap: (index) {
            if (index == 3) {
              _confirmLogout();
              return;
            }
            _updateLastActive();
            setState(() {
              _currentIndex = index;
            });
          },
        ),
      ),
    );
  }

  // --- CẬP NHẬT THỜI GIAN HOẠT ĐỘNG ---
  Future<void> _updateLastActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        'last_active_time', DateTime.now().millisecondsSinceEpoch);
  }

  // --- KIỂM TRA PHIÊN KHI APP QUAY LẠI ---
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSessionTimeout();
    } else if (state == AppLifecycleState.paused) {
      _updateLastActive();
    }
  }

  Future<void> _checkSessionTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    final lastActive = prefs.getInt('last_active_time') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastActive > 0 && (now - lastActive) > _sessionTimeout) {
      _sessionCheckTimer?.cancel();
      await _lockSession();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Your session has expired, please log in again.')),
        );
      }
    }
  }

  // --- ĐĂNG XUẤT ---
  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lock Session'),
        content: const Text(
            'Do you want to lock the session and log in again with biometric authentication?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _lockSession();
            },
            child:
                const Text('Lock Session', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _lockSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('session_locked', true);
    await prefs.remove('last_active_time');
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }
}
