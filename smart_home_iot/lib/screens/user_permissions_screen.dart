import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/connectivity_service.dart';

class UserPermissionsScreen extends StatefulWidget {
  final String userId;
  final String username;

  const UserPermissionsScreen({
    super.key,
    required this.userId,
    required this.username,
  });

  @override
  State<UserPermissionsScreen> createState() => _UserPermissionsScreenState();
}

class _UserPermissionsScreenState extends State<UserPermissionsScreen> {
  bool _loading = true;
  Map<String, dynamic> _permissions = {};

  static const _bgColor = Color(0xFFDCE5F0);
  static const _textColor = Color(0xFF3E4E5E);
  static const _accentColor = Color(0xFF5D9CEC);

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');
      if (token == null) return;

      final url =
          connectivityService.uri('/admin/users/${widget.userId}/permissions');
      final response = await http.get(
        url,
        headers: connectivityService.buildHeaders(token: token),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _permissions = data['permissions'] ?? {};
          _loading = false;
        });
      }
    } catch (e) {
      print('Error loading permissions: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _savePermissions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');
      if (token == null) return;

      final url =
          connectivityService.uri('/admin/users/${widget.userId}/permissions');
      final response = await http.put(
        url,
        headers: connectivityService.buildHeaders(token: token),
        body: jsonEncode({'permissions': _permissions}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Đã lưu quyền thành công'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true để reload list
      } else {
        final error = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Lỗi: ${error['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Lỗi: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _updatePermission(String category, String action, bool value) {
    setState(() {
      if (_permissions[category] == null) {
        _permissions[category] = {};
      }
      _permissions[category][action] = value;
    });
  }

  bool _getPermission(String category, String action) {
    return _permissions[category]?[action] ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: Text('Phân quyền: ${widget.username}'),
        backgroundColor: _accentColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _savePermissions,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCategoryCard(
                    'Cửa Chính',
                    Icons.door_front_door,
                    'door',
                    [
                      PermissionItem('view', 'Xem trạng thái'),
                      PermissionItem('open', 'Mở cửa'),
                      PermissionItem('close', 'Đóng cửa'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildCategoryCard(
                    'Mái Che',
                    Icons.roofing,
                    'awning',
                    [
                      PermissionItem('view', 'Xem trạng thái'),
                      PermissionItem('open', 'Mở mái che'),
                      PermissionItem('close', 'Đóng mái che'),
                      PermissionItem('setMode', 'Chuyển chế độ Auto/Manual'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildCategoryCard(
                    'Quản lý Báo động',
                    Icons.notifications_active,
                    'alarm',
                    [
                      PermissionItem('view', 'Xem trạng thái'),
                      PermissionItem('snooze', 'Tạm hoãn báo động'),
                      PermissionItem('snoozeAll', 'Tắt TẤT CẢ báo động'),
                      PermissionItem('snoozeFire', 'Tắt báo động LỬA'),
                      PermissionItem('snoozeGas', 'Tắt báo động GAS'),
                      PermissionItem('cancelSnooze', 'Kích hoạt lại (Admin)'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildCategoryCard(
                    'Dữ liệu Cảm biến',
                    Icons.sensors,
                    'sensors',
                    [
                      PermissionItem('viewTemperature', 'Xem nhiệt độ'),
                      PermissionItem('viewHumidity', 'Xem độ ẩm'),
                      PermissionItem('viewGas', 'Xem khí gas'),
                      PermissionItem('viewFire', 'Xem cảm biến lửa'),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildCategoryCard(
    String title,
    IconData icon,
    String category,
    List<PermissionItem> items,
  ) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: _accentColor, size: 28),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _textColor,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...items.map((item) => _buildPermissionSwitch(category, item)),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionSwitch(String category, PermissionItem item) {
    final value = _getPermission(category, item.action);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.label,
              style: TextStyle(fontSize: 15, color: _textColor),
            ),
          ),
          Switch(
            value: value,
            onChanged: (newValue) =>
                _updatePermission(category, item.action, newValue),
            activeColor: _accentColor,
          ),
        ],
      ),
    );
  }
}

class PermissionItem {
  final String action;
  final String label;

  PermissionItem(this.action, this.label);
}
