import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/connectivity_service.dart';

class UserFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existingUser;
  const UserFormScreen({super.key, this.existingUser});

  @override
  State<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends State<UserFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String _role = 'user';
  bool _canRead = false;
  bool _canControl = false;
  bool _submitting = false;

  // Granular permissions
  Map<String, dynamic> _permissions = {
    'door': {'view': true, 'open': false, 'close': false},
    'awning': {'view': true, 'open': false, 'close': false, 'setMode': false},
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
    }
  };

  @override
  void initState() {
    super.initState();
    final u = widget.existingUser;
    if (u != null) {
      _usernameCtrl.text = (u['username'] ?? '').toString();
      _role = (u['role'] ?? 'user').toString();

      // Load old modules format (backward compatibility)
      final modules = (u['modules'] as List?) ?? [];
      final esp = modules.cast<Map?>().firstWhere(
            (m) => (m?['moduleId']?.toString() ?? '') == deviceId,
            orElse: () => null,
          );
      if (esp != null) {
        _canRead = (esp['canRead'] ?? false) == true;
        _canControl = (esp['canControl'] ?? false) == true;
      }

      // Load granular permissions
      if (u['permissions'] != null) {
        final perms = u['permissions'] as Map<String, dynamic>;
        setState(() {
          _permissions = {
            'door': perms['door'] ?? _permissions['door'],
            'awning': perms['awning'] ?? _permissions['awning'],
            'alarm': perms['alarm'] ?? _permissions['alarm'],
            'sensors': perms['sensors'] ?? _permissions['sensors'],
          };
        });
      }
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');

      final modules = [
        {'moduleId': deviceId, 'canRead': _canRead, 'canControl': _canControl}
      ];

      if (widget.existingUser == null) {
        // Create new user with permissions
        final body = {
          'username': _usernameCtrl.text.trim(),
          'password': _passwordCtrl.text,
          'role': _role,
          'modules': modules,
          'permissions': _permissions, // Add granular permissions
        };
        final url = connectivityService.uri('/accounts');
        final res = await http.post(url,
            headers: connectivityService.buildHeaders(token: token),
            body: jsonEncode(body));
        if (res.statusCode != 201) {
          throw Exception('Tạo thất bại: ${res.statusCode} ${res.body}');
        }
      } else {
        // Update existing user
        final Map<String, dynamic> body = {
          'role': _role,
          'modules': modules,
          'permissions': _permissions, // Update permissions
        };
        if (_passwordCtrl.text.isNotEmpty) {
          body['password'] = _passwordCtrl.text;
        }
        final id = widget.existingUser!['_id'].toString();
        final url = connectivityService.uri('/accounts/$id');
        final res = await http.patch(url,
            headers: connectivityService.buildHeaders(token: token),
            body: jsonEncode(body));
        if (res.statusCode != 200) {
          throw Exception('Cập nhật thất bại: ${res.statusCode} ${res.body}');
        }
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingUser != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Sửa người dùng' : 'Tạo người dùng')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(labelText: 'Username'),
                enabled: !isEdit, // Backend hiện chưa hỗ trợ đổi username
                validator: (v) {
                  if (!isEdit && (v == null || v.trim().isEmpty))
                    return 'Bắt buộc';
                  return null;
                },
              ),
              TextFormField(
                controller: _passwordCtrl,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: isEdit
                        ? 'Mật khẩu (để trống nếu giữ nguyên)'
                        : 'Mật khẩu'),
                validator: (v) {
                  if (!isEdit && (v == null || v.isEmpty)) return 'Bắt buộc';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _role,
                items: const [
                  DropdownMenuItem(value: 'user', child: Text('user')),
                  DropdownMenuItem(value: 'guest', child: Text('guest')),
                ],
                onChanged: (v) => setState(() => _role = v ?? 'user'),
                decoration: const InputDecoration(labelText: 'Role'),
              ),
              const SizedBox(height: 12),
              const Text('Quyền cho thiết bị esp32_1',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              CheckboxListTile(
                value: _canRead,
                onChanged: (v) => setState(() => _canRead = v ?? false),
                title: const Text('canRead'),
              ),
              CheckboxListTile(
                value: _canControl,
                onChanged: (v) => setState(() => _canControl = v ?? false),
                title: const Text('canControl'),
              ),
              const SizedBox(height: 24),

              // Granular Permissions Section
              const Divider(),
              const Text(
                'Quyền chi tiết (Granular Permissions)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Cấu hình chi tiết quyền truy cập cho từng tính năng',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),

              _buildPermissionCategory(
                'Thiết bị Cửa',
                Icons.door_front_door,
                ['Xem', 'Mở', 'Đóng'],
                ['view', 'open', 'close'],
                'door',
              ),
              const SizedBox(height: 12),

              _buildPermissionCategory(
                'Mái Che',
                Icons.roofing,
                ['Xem', 'Mở', 'Đóng', 'Chế độ Auto'],
                ['view', 'open', 'close', 'setMode'],
                'awning',
              ),
              const SizedBox(height: 12),

              _buildPermissionCategory(
                'Quản Lý Báo Động',
                Icons.notifications_active,
                [
                  'Xem',
                  'Tạm hoãn',
                  'Kích hoạt lại',
                  'Tắt tất cả',
                  'Tắt lửa',
                  'Tắt gas'
                ],
                [
                  'view',
                  'snooze',
                  'cancelSnooze',
                  'snoozeAll',
                  'snoozeFire',
                  'snoozeGas'
                ],
                'alarm',
              ),
              const SizedBox(height: 12),

              _buildPermissionCategory(
                'Cảm Biến',
                Icons.sensors,
                ['Nhiệt độ', 'Độ ẩm', 'Khí Gas', 'Lửa'],
                ['viewTemperature', 'viewHumidity', 'viewGas', 'viewFire'],
                'sensors',
              ),
              const SizedBox(height: 16),
              _submitting
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _save,
                      child: const Text('Lưu'),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionCategory(
    String title,
    IconData icon,
    List<String> labels,
    List<String> actions,
    String category,
  ) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...List.generate(actions.length, (index) {
              final action = actions[index];
              final label = labels[index];
              final isEnabled = _permissions[category]?[action] ?? false;

              return SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(label, style: const TextStyle(fontSize: 14)),
                value: isEnabled,
                onChanged: (value) {
                  setState(() {
                    _permissions[category]![action] = value;
                  });
                },
              );
            }),
          ],
        ),
      ),
    );
  }
}
