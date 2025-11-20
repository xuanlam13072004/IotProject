import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
// import '../config.dart';
import '../services/connectivity_service.dart';
import 'user_form.dart';

class AdminManageUsersScreen extends StatefulWidget {
  const AdminManageUsersScreen({super.key});

  @override
  State<AdminManageUsersScreen> createState() => _AdminManageUsersScreenState();
}

class _AdminManageUsersScreenState extends State<AdminManageUsersScreen> {
  late Future<List<Map<String, dynamic>>> _usersFuture;

  @override
  void initState() {
    super.initState();
    _usersFuture = _fetchUsers();
  }

  Future<List<Map<String, dynamic>>> _fetchUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    final url = connectivityService.uri('/accounts');
    final res = await http.get(url,
        headers: connectivityService.buildHeaders(token: token));
    if (res.statusCode != 200) {
      throw Exception('Tải danh sách thất bại: ${res.statusCode} ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> _deleteUser(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    final url = connectivityService.uri('/accounts/$id');
    final res = await http.delete(url,
        headers: connectivityService.buildHeaders(token: token));
    if (res.statusCode != 204) {
      throw Exception('Xóa thất bại: ${res.statusCode} ${res.body}');
    }
  }

  Future<void> _openForm({Map<String, dynamic>? user}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => UserFormScreen(existingUser: user)),
    );
    if (changed == true && mounted) {
      setState(() {
        _usersFuture = _fetchUsers();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // AppBar-like header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          color: const Color(0xFFDCE5F0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Quản lý người dùng',
                style: TextStyle(
                  color: Color(0xFF3E4E5E),
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: Color(0xFF5D9CEC)),
                onPressed: () => _openForm(),
                tooltip: 'Thêm người dùng',
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _usersFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Lỗi: ${snapshot.error}'));
              }
              final users = snapshot.data ?? [];
              if (users.isEmpty) {
                return const Center(child: Text('Chưa có người dùng'));
              }
              return ListView.builder(
                itemCount: users.length,
                itemBuilder: (context, index) {
                  final u = users[index];
                  final id = u['_id']?.toString() ?? '';
                  final username = u['username']?.toString() ?? '';
                  final role = u['role']?.toString() ?? '';
                  final isAdmin = role.toLowerCase() == 'admin';

                  return ListTile(
                    title: Text(username),
                    subtitle: Text('Role: $role'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Chỉ hiện nút Sửa cho user/guest, ẩn với admin
                        if (!isAdmin) ...[
                          TextButton(
                            onPressed: () => _openForm(user: u),
                            child: const Text('Sửa'),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Xác nhận xóa'),
                                  content: Text('Xóa người dùng "$username"?'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('Hủy')),
                                    ElevatedButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('Xóa')),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                try {
                                  await _deleteUser(id);
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text('Đã xóa'),
                                  ));
                                  setState(() {
                                    _usersFuture = _fetchUsers();
                                  });
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Lỗi xóa: $e')));
                                }
                              }
                            },
                          ),
                        ] else
                          // Admin không được sửa/xóa
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              '🔒 Admin',
                              style: TextStyle(
                                color: Colors.grey,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ], // End of Column children
    ); // End of Column
  }
}
