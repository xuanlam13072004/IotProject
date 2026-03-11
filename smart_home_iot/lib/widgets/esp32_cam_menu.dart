import 'package:flutter/material.dart';
import '../screens/door_cam_screen.dart';

class Esp32CamMenu extends StatelessWidget {
  final VoidCallback onOpenCam;
  final VoidCallback onFaceAuth;
  final bool isLoading;
  const Esp32CamMenu({
    super.key,
    required this.onOpenCam,
    required this.onFaceAuth,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('ESP32-cam'),
      children: [
        SimpleDialogOption(
          onPressed: isLoading ? null : onOpenCam,
          child: Row(
            children: [
              const Icon(Icons.videocam, color: Colors.blue),
              const SizedBox(width: 12),
              isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Open Camera',
                      style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        SimpleDialogOption(
          onPressed: isLoading ? null : onFaceAuth,
          child: Row(
            children: [
              const Icon(Icons.verified_user, color: Colors.green),
              const SizedBox(width: 12),
              const Text('Face Authentication',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }
}
