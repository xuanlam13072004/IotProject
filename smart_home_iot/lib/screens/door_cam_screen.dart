import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/connectivity_service.dart';

class DoorCamScreen extends StatefulWidget {
  const DoorCamScreen({super.key});

  @override
  State<DoorCamScreen> createState() => _DoorCamScreenState();
}

class _DoorCamScreenState extends State<DoorCamScreen> {
  Timer? _timer;
  int _ts = DateTime.now().millisecondsSinceEpoch;
  String? _authToken;

  @override
  void initState() {
    super.initState();
    _loadToken();

    // Giả lập stream bằng snapshot
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      setState(() {
        _ts = DateTime.now().millisecondsSinceEpoch;
      });
    });
  }

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString('user_token');
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = connectivityService.camSnapshotUrl(ts: _ts);
    final isCloud = !connectivityService.isLocalMode;
    final headers = <String, String>{
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
    if (isCloud && _authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }

    const bgColor = Color(0xFFE0E0E0);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: bgColor,
        centerTitle: true,
        title: const Text(
          'Door Camera',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Center(
        child: Container(
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              // Bóng tối (lõm)
              BoxShadow(
                color: Colors.black26,
                offset: Offset(6, 6),
                blurRadius: 12,
              ),
              // Bóng sáng (nổi)
              BoxShadow(
                color: Colors.white,
                offset: Offset(-6, -6),
                blurRadius: 12,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                imageUrl,

                /// 🚫 Tránh cache ảnh cũ
                headers: headers,

                fit: BoxFit.cover,
                gaplessPlayback: true,

                /// ⏳ Loading
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.black54,
                      ),
                    ),
                  );
                },

                /// ❌ Error
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: bgColor,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(16),
                    child: const Text(
                      '❌ Unable to load image from ESP32-CAM\n\n'
                      '• Check IP\n'
                      '• Check WiFi\n'
                      '• Endpoint /snapshot.jpg',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
