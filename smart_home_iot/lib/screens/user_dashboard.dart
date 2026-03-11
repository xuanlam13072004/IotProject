import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/connectivity_service.dart';
import '../services/notification_service.dart';
import '../widgets/device_dashboard.dart';

class UserDashboardScreen extends StatefulWidget {
  const UserDashboardScreen({super.key});

  @override
  State<UserDashboardScreen> createState() => _UserDashboardScreenState();
}

class _UserDashboardScreenState extends State<UserDashboardScreen> {
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
        if (mounted) {
          setState(() {
            _permissions = data['permissions'] ?? {};
            _permissionsLoaded = true;
          });
        }
      } else {
        if (mounted) setState(() => _permissionsLoaded = true);
      }
    } catch (e) {
      print('Error loading permissions: $e');
      if (mounted) setState(() => _permissionsLoaded = true);
    }
  }

  bool _hasPermission(String category, String action) {
    if (_isAdmin) return true; // Admin có tất cả quyền
    return _permissions[category]?[action] == true;
  }

  String _getFriendlyMessage(String action) {
    // Extract base action if it has parameters
    final baseAction = action.split('&').first;

    // Extract sensor parameter if present
    String sensorInfo = '';
    if (action.contains('sensor=')) {
      final sensorMatch = RegExp(r'sensor=(\w+)').firstMatch(action);
      if (sensorMatch != null) {
        final sensor = sensorMatch.group(1);
        if (sensor == 'fire') {
          sensorInfo = ' (Fire)';
        } else if (sensor == 'gas')
          sensorInfo = ' (Gas)';
        else if (sensor == 'all') sensorInfo = ' (All)';
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
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    if (token == null) {
      if (mounted) {
        NotificationService.show(context, 'Not logged in!', true);
      }
      return;
    }

    // Parse action and parameters (e.g., "set_snooze&seconds=300")
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

      // Add parameters to body
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
          'Send failed. Try again!',
          true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      NotificationService.show(context, 'Send failed. Try again!', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsLoaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: DeviceDashboard(
        enabled: true,
        onAction: _sendCommand,
        isAdmin: _isAdmin,
        permissions: _permissions,
      ),
    );
  }
}
