import 'package:flutter/material.dart';

class Esp32CamActionScreen extends StatelessWidget {
  final VoidCallback onOpenCam;
  final VoidCallback onFaceAuth;
  final bool isLoading;
  const Esp32CamActionScreen({
    super.key,
    required this.onOpenCam,
    required this.onFaceAuth,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32-cam'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.videocam, color: Colors.white),
                label: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Open Camera',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: Colors.blue,
                  textStyle: const TextStyle(fontSize: 18),
                ),
                onPressed: isLoading ? null : onOpenCam,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.verified_user, color: Colors.white),
                label: const Text('Face Authentication',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: Colors.green,
                  textStyle: const TextStyle(fontSize: 18),
                ),
                onPressed: isLoading ? null : onFaceAuth,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
