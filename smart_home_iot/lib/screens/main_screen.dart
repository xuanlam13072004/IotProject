import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/connectivity_service.dart';
import '../services/notification_service.dart';
import '../widgets/device_dashboard.dart';
import 'history_screen.dart';
import 'admin_manage_users.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const _bgColor = Color(0xFFDCE5F0);
  static const _textColor = Color(0xFF3E4E5E);
  static const _accentColor = Color(0xFF5D9CEC);

  int _currentIndex = 0;
  bool _isAdmin = false;
  Map<String, dynamic> _permissions = {};
  bool _permissionsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadRoleAndPermissions();
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
      if (token == null) return;

      final url = connectivityService.uri('/accounts/me/permissions');
      final response = await http.get(
        url,
        headers: connectivityService.buildHeaders(token: token),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = (data['permissions'] ?? {}) as Map<String, dynamic>;
        final merged = _withDefaultPermissions(raw);
        setState(() {
          _permissions = merged;
          _permissionsLoaded = true;
        });
      }
    } catch (e) {
      print('Error loading permissions: $e');
      setState(() => _permissionsLoaded = true);
    }
  }

  Map<String, dynamic> _withDefaultPermissions(Map<String, dynamic> raw) {
    // Simply return raw permissions from backend
    // If backend returns empty/partial structure, provide minimal fallback
    if (raw.isEmpty) {
      // Guest-level defaults (view only)
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
      };
    }

    // Backend provided permissions - use them directly
    // Deep copy to ensure we don't modify cached data
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

  String _getFriendlyMessage(String action) {
    final baseAction = action.split('&').first;

    String sensorInfo = '';
    if (action.contains('sensor=')) {
      final sensorMatch = RegExp(r'sensor=(\w+)').firstMatch(action);
      if (sensorMatch != null) {
        final sensor = sensorMatch.group(1);
        if (sensor == 'fire')
          sensorInfo = ' (Lửa)';
        else if (sensor == 'gas')
          sensorInfo = ' (Gas)';
        else if (sensor == 'all') sensorInfo = ' (Tất cả)';
      }
    }

    const Map<String, String> actionMessages = {
      'open_door': 'Đã gửi lệnh Mở Cửa chính.',
      'close_door': 'Đã gửi lệnh Đóng Cửa chính.',
      'open_awning': 'Đã gửi lệnh Mở Mái che.',
      'close_awning': 'Đã gửi lệnh Đóng Mái che.',
      'set_auto': 'Đã chuyển Mái che sang chế độ Tự động.',
      'set_manual': 'Đã chuyển Mái che sang chế độ Thủ công.',
      'set_snooze': 'Đã tạm hoãn báo động',
      'cancel_snooze': 'Đã kích hoạt lại báo động',
    };

    final baseMessage =
        actionMessages[baseAction] ?? 'Đã gửi lệnh: $baseAction';
    return baseMessage + sensorInfo + (sensorInfo.isNotEmpty ? '' : '.');
  }

  Future<void> _sendCommand(String action) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    if (token == null) {
      if (mounted) {
        NotificationService.show(context, 'Chưa đăng nhập!', true);
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
          'Gửi lệnh thất bại, vui lòng thử lại!',
          true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      NotificationService.show(
          context, 'Gửi lệnh thất bại, vui lòng thử lại!', true);
    }
  }

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
                  'Chỉ Admin mới có quyền truy cập',
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
              label: 'Điều khiển',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: 'Lịch sử',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.manage_accounts),
              label: 'Quản lý',
            ),
          ],
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
        ),
      ),
    );
  }
}
