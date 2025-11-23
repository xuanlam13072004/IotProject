import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jwt_decode/jwt_decode.dart';
// import 'config.dart';
import 'services/connectivity_service.dart';
import 'screens/main_screen.dart';
import 'screens/guest_screen.dart';

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

  @override
  void initState() {
    super.initState();
    // Start Local/Cloud connectivity monitoring early
    connectivityService.startMonitoring();
    _maybeAutoLogin();
  }

  Future<void> _maybeAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    final role = prefs.getString('user_role');
    if (token != null && role != null) {
      try {
        final expired = Jwt.isExpired(token);
        if (!expired && mounted) {
          _navigateByRole(role);
          return;
        }
      } catch (_) {
        // If token is malformed, treat as invalid
      }
      await prefs.remove('user_token');
      await prefs.remove('user_role');
    }
  }

  Future<void> _login() async {
    setState(() => _isLoading = true);
    final url = connectivityService.uri('/accounts/login');

    try {
      final response = await http.post(
        url,
        headers: connectivityService.buildHeaders(),
        body: jsonEncode({
          'username': _userController.text,
          'password': _passController.text,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'];

        // Lưu token vào bộ nhớ máy
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_token', token);
        // Backend hiện trả token (JWT) chứa role
        Map<String, dynamic> payload = Jwt.parseJwt(token);
        final role = (payload['role'] ?? 'user').toString();
        await prefs.setString('user_role', role);

        if (mounted) _navigateByRole(role);
      } else {
        _showError('Login failed: ${response.body}');
      }
    } catch (e) {
      _showError('Connection error: $e\n(Check IP and Firewall)');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _navigateByRole(String role) {
    Widget screen;
    switch (role) {
      case 'admin':
      case 'user':
        screen = const MainScreen(); // Unified navigation for admin and user
        break;
      case 'guest':
        screen = const GuestDashboardScreen();
        break;
      default:
        screen = const MainScreen();
    }
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => screen));
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Smart Home Login")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
                controller: _userController,
                decoration: const InputDecoration(labelText: 'Username')),
            TextField(
                controller: _passController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true),
            const SizedBox(height: 20),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _login,
                    child: const Text("LOGIN", style: TextStyle(fontSize: 18)),
                  ),
          ],
        ),
      ),
    );
  }
}
