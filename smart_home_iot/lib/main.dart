import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jwt_decode/jwt_decode.dart';

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

// --- NÂNG CẤP: WIDGET ĐỔ BÓNG NEUMORPHISM ---
class NeuContainer extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color color;

  const NeuContainer(
      {super.key,
      required this.child,
      this.radius = 16,
      this.padding = const EdgeInsets.all(16),
      this.color = const Color(0xFFE0E5EC),
      Til});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0xFFB8C6D1),
            offset: Offset(6, 6),
            blurRadius: 12,
          ),
          BoxShadow(
            color: Colors.white,
            offset: Offset(-6, -6),
            blurRadius: 12,
          ),
        ],
      ),
      child: child,
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
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    connectivityService.startMonitoring();
    _maybeAutoLogin();
  }

  // Logic an toàn từ File 1
  Future<void> _maybeAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('user_token');
    final role = prefs.getString('user_role');
    final isLocked = prefs.getBool('session_locked') ?? false;

    if (token != null && role != null) {
      if (isLocked) return;
      try {
        final expired = Jwt.isExpired(token);
        if (expired) throw Exception('expired');

        // Kiểm tra phiên không hoạt động quá 30 phút
        final lastActive = prefs.getInt('last_active_time') ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        const sessionTimeout = 5 * 60 * 1000; // 5 phút
        if (lastActive > 0 && (now - lastActive) > sessionTimeout) {
          throw Exception('session_timeout');
        }

        if (mounted) {
          _navigateByRole(role);
          return;
        }
      } catch (_) {}
      await prefs.remove('user_token');
      await prefs.remove('user_role');
      await prefs.remove('user_username');
      await prefs.remove('last_active_time');
      await prefs.remove('session_locked');
    }
  }

  // Logic Login kết hợp trim() của File 2
  Future<void> _login() async {
    setState(() => _isLoading = true);
    final url = connectivityService.uri('/accounts/login');

    try {
      final response = await http.post(
        url,
        headers: connectivityService.buildHeaders(),
        body: jsonEncode({
          'username': _userController.text.trim(), // Nâng cấp trim()
          'password': _passController.text.trim(),
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'];

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_token', token);
        await prefs.setInt(
            'last_active_time', DateTime.now().millisecondsSinceEpoch);
        await prefs.setBool('session_locked', false);

        Map<String, dynamic> payload = Jwt.parseJwt(token);
        final role = (payload['role'] ?? 'user').toString();
        await prefs.setString('user_role', role);

        // Lưu username từ JWT để dùng làm voice owner_id
        final username = (payload['username'] ?? '').toString();
        if (username.isNotEmpty) {
          await prefs.setString('user_username', username);
        }

        if (mounted) _navigateByRole(role);
      } else {
        _showError('Đăng nhập thất bại: ${response.body}');
      }
    } catch (e) {
      _showError('Lỗi kết nối: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- ĐĂNG NHẬP SINH TRẮC HỌc (VÂN TAY / KHUÔN MẶT ĐIỆN THOẠI) ---
  Future<void> _loginByBiometric() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      // Kiểm tra thiết bị có hỗ trợ sinh trắc học không
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isDeviceSupported) {
        _showError('Thiết bị không hỗ trợ vân tay / khuôn mặt');
        return;
      }

      // Kiểm tra đã từng đăng nhập thành công chưa (có token lưu sẵn)
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString('user_token');
      final savedRole = prefs.getString('user_role');

      if (savedToken == null || savedRole == null) {
        _showError('Bạn cần đăng nhập bằng tài khoản ít nhất 1 lần trước');
        return;
      }

      final available = await _localAuth.getAvailableBiometrics();
      final hasBiometric = available.any((b) =>
          b == BiometricType.fingerprint ||
          b == BiometricType.face ||
          b == BiometricType.strong ||
          b == BiometricType.weak);

      // Tránh popup lặp: nếu có biometric thì chỉ cho biometric;
      // nếu không có thì mới dùng PIN/Password thiết bị.
      final didAuth = await _localAuth.authenticate(
        localizedReason: hasBiometric
            ? 'Dùng vân tay/khuôn mặt để đăng nhập Smart Home'
            : 'Dùng mật khẩu thiết bị để đăng nhập Smart Home',
        options: AuthenticationOptions(
          stickyAuth: false,
          biometricOnly: hasBiometric,
          useErrorDialogs: false,
        ),
      );

      if (!didAuth) {
        _showError(hasBiometric
            ? 'Xác thực sinh trắc học thất bại'
            : 'Xác thực thiết bị thất bại');
        return;
      }

      // Xác thực thành công → kiểm tra token còn hạn không
      try {
        final expired = Jwt.isExpired(savedToken);
        if (expired) {
          await prefs.remove('user_token');
          await prefs.remove('user_role');
          await prefs.remove('user_username');
          await prefs.remove('session_locked');
          _showError('Phiên đã hết hạn, vui lòng đăng nhập lại bằng tài khoản');
          return;
        }
      } catch (_) {
        _showError('Token không hợp lệ, vui lòng đăng nhập lại');
        return;
      }

      await prefs.setBool('session_locked', false);
      await prefs.setInt(
          'last_active_time', DateTime.now().millisecondsSinceEpoch);

      if (mounted) _navigateByRole(savedRole);
    } catch (e) {
      _showError('Lỗi xác thực sinh trắc học: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _navigateByRole(String role) {
    Widget screen =
        (role == 'guest') ? const GuestDashboardScreen() : const MainScreen();
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => screen));
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE0E5EC), // Nền Neumorphism
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Nâng cấp: Logo dự án
              SizedBox(
                  width: 180,
                  height: 180,
                  child: Image.asset('assets/images/logo.png',
                      errorBuilder: (c, e, s) =>
                          const Icon(Icons.home, size: 100))),
              const SizedBox(height: 20),
              const Text("SMART HOME",
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF3E4E5E))),
              const SizedBox(height: 40),

              NeuContainer(
                child: TextField(
                  controller: _userController,
                  decoration: const InputDecoration(
                      border: InputBorder.none,
                      icon: Icon(Icons.person),
                      hintText: 'Username'),
                ),
              ),
              const SizedBox(height: 20),
              NeuContainer(
                child: TextField(
                  controller: _passController,
                  obscureText: true,
                  decoration: const InputDecoration(
                      border: InputBorder.none,
                      icon: Icon(Icons.lock),
                      hintText: 'Password'),
                ),
              ),
              const SizedBox(height: 30),

              _isLoading
                  ? const CircularProgressIndicator()
                  : Column(
                      children: [
                        GestureDetector(
                          onTap: _login,
                          child: NeuContainer(
                            color: Colors.blueAccent,
                            radius: 30,
                            child: const Center(
                                child: Text("Sign In",
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold))),
                          ),
                        ),
                        const SizedBox(height: 15),
                        GestureDetector(
                          onTap: _loginByBiometric,
                          child: NeuContainer(
                            color: Colors.black87,
                            radius: 30,
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.fingerprint,
                                    color: Colors.white, size: 22),
                                SizedBox(width: 8),
                                Text("Fingerprint / Face ID",
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
