import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
// import '../config.dart';
import '../services/connectivity_service.dart';
import 'user_form.dart';
import 'voice_data_management.dart';
import 'voice_profiles_admin.dart';

class AdminManageUsersScreen extends StatefulWidget {
  const AdminManageUsersScreen({super.key});

  @override
  State<AdminManageUsersScreen> createState() => _AdminManageUsersScreenState();
}

class _AdminManageUsersScreenState extends State<AdminManageUsersScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFDCE5F0),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Manage Center',
                style: TextStyle(
                  color: Color(0xFF3E4E5E),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Select a management module',
                style: TextStyle(
                  color: const Color(0xFF3E4E5E).withValues(alpha: 0.7),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              _ManageMenuCard(
                icon: Icons.group,
                title: 'User Management',
                subtitle: 'Manage member accounts, roles, and permissions.',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminUserListScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              _ManageMenuCard(
                icon: Icons.mic,
                title: 'Voice Data Management',
                subtitle:
                    'Record voice samples, organize voice profiles, and tune anti-spoof thresholds.',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const VoiceDataManagementScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              _ManageMenuCard(
                icon: Icons.library_music,
                title: 'Voice Library (Admin)',
                subtitle: 'View stored voices and sample counts.',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const VoiceProfilesAdminScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageMenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ManageMenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFDCE5F0),
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Colors.white,
                offset: Offset(-6, -6),
                blurRadius: 12,
              ),
              BoxShadow(
                color: Color(0xFFA6BCCF),
                offset: Offset(6, 6),
                blurRadius: 12,
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFDCE5F0),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.white,
                      offset: Offset(-3, -3),
                      blurRadius: 6,
                    ),
                    BoxShadow(
                      color: Color(0xFFA6BCCF),
                      offset: Offset(3, 3),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Icon(icon, color: const Color(0xFF5D9CEC)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF3E4E5E),
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: const Color(0xFF3E4E5E).withValues(alpha: 0.75),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF3E4E5E)),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminUserListScreen extends StatefulWidget {
  const AdminUserListScreen({super.key});

  @override
  State<AdminUserListScreen> createState() => _AdminUserListScreenState();
}

class _AdminUserListScreenState extends State<AdminUserListScreen> {
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
    return Scaffold(
      backgroundColor: const Color(0xFFDCE5F0),
      appBar: AppBar(
        title: const Text('User Management'),
        backgroundColor: const Color(0xFFDCE5F0),
        elevation: 0,
        foregroundColor: const Color(0xFF3E4E5E),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF5D9CEC)),
            onPressed: () => _openForm(),
            tooltip: 'Add user',
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final users = snapshot.data ?? [];
          if (users.isEmpty) {
            return const Center(child: Text('No users available'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: users.length,
            itemBuilder: (context, index) {
              final u = users[index];
              final id = u['_id']?.toString() ?? '';
              final username = u['username']?.toString() ?? '';
              final role = u['role']?.toString() ?? '';
              final isAdmin = role.toLowerCase() == 'admin';

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCE5F0),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.white,
                      offset: Offset(-4, -4),
                      blurRadius: 8,
                    ),
                    BoxShadow(
                      color: Color(0xFFA6BCCF),
                      offset: Offset(4, 4),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: ListTile(
                  title: Text(username),
                  subtitle: Text('Role: $role'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isAdmin) ...[
                        TextButton(
                          onPressed: () => _openForm(user: u),
                          child: const Text('Edit'),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Confirm delete'),
                                content: Text('Delete user "$username"?'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              try {
                                await _deleteUser(id);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(
                                  content: Text('Deleted'),
                                ));
                                setState(() {
                                  _usersFuture = _fetchUsers();
                                });
                              } catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Delete error: $e')),
                                );
                              }
                            }
                          },
                        ),
                      ] else
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}
