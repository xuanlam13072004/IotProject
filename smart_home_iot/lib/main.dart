import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ================= CẤU HÌNH HỆ THỐNG =================
// ⚠️ QUAN TRỌNG: Chỉ để 1 dấu '/api' ở cuối. Nếu dùng LAN: 'http://<IP_LAPTOP>:4000/api'
const String baseUrl = 'https://lorna-biometrical-ireland.ngrok-free.dev/api';
const String deviceId = 'esp32_1';
// =====================================================

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Home IoT',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const LoginScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- MÀN HÌNH ĐĂNG NHẬP ---
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() => _isLoading = true);
    final url = Uri.parse('$baseUrl/accounts/login');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': 'true',
        },
        body: jsonEncode({
          'username': _userController.text,
          'password': _passController.text,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token']; // Backend trả về { "token": "..." }

        // Lưu token vào bộ nhớ máy
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_token', token);

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const DashboardScreen()),
          );
        }
      } else {
        _showError('Đăng nhập thất bại: ${response.body}');
      }
    } catch (e) {
      _showError('Lỗi kết nối: $e\n(Kiểm tra IP và Tường lửa)');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Đăng Nhập Smart Home")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
                controller: _userController,
                decoration: const InputDecoration(labelText: 'Tài khoản')),
            TextField(
                controller: _passController,
                decoration: const InputDecoration(labelText: 'Mật khẩu'),
                obscureText: true),
            const SizedBox(height: 20),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _login,
                    child:
                        const Text("ĐĂNG NHẬP", style: TextStyle(fontSize: 18)),
                  ),
          ],
        ),
      ),
    );
  }
}

// --- MÀN HÌNH ĐIỀU KHIỂN ---
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Future<void> _sendCommand(String action) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');

    if (token == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Chưa đăng nhập!")));
      return;
    }

    // API Control: POST /api/devices/:id/control
    final url = Uri.parse('$baseUrl/devices/$deviceId/control');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token', // Gửi kèm Token xác thực
          'ngrok-skip-browser-warning': 'true',
        },
        // Backend mong đợi action là 1 object (ví dụ: { type, value })
        body: jsonEncode({
          'action': {'type': action, 'value': '1'}
        }),
      );

      if (response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 202) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("✅ Đã gửi lệnh: $action"),
          backgroundColor: Colors.green,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text("❌ Thất bại: ${response.statusCode} - ${response.body}"),
          backgroundColor: Colors.red,
        ));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Lỗi mạng: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Bảng Điều Khiển"),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (mounted) {
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()));
              }
            },
          )
        ],
      ),
      body: Center(
        child: GridView.count(
          crossAxisCount: 2,
          padding: const EdgeInsets.all(20),
          crossAxisSpacing: 20,
          mainAxisSpacing: 20,
          children: [
            _buildBtn("MỞ CỬA", "open_door", Colors.orange),
            _buildBtn("ĐÓNG CỬA", "close_door", Colors.grey),
            _buildBtn("MỞ MÁI CHE", "open_awning", Colors.blue),
            _buildBtn("ĐÓNG MÁI CHE", "close_awning", Colors.blueGrey),
            _buildBtn("REBOOT ESP", "reboot", Colors.redAccent),
          ],
        ),
      ),
    );
  }

  Widget _buildBtn(String label, String action, Color color) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
      onPressed: () => _sendCommand(action),
      child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
    );
  }
}
