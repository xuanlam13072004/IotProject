// Centralized app configuration

import 'package:flutter/foundation.dart';

// Local network API base (Windows Mobile Hotspot default host IP 192.168.137.1)
// Update if your hotspot adapter shows a different IPv4.
const String _mobileHostIp = '192.168.137.1';
const String localUrl =
    kIsWeb ? 'http://127.0.0.1:4000/api' : 'http://$_mobileHostIp:4000/api';

// Local voice-auth API (audio_control FastAPI)
const String voiceLocalUrl =
    kIsWeb ? 'http://127.0.0.1:8080' : 'http://$_mobileHostIp:8080';
// Cloud: Cloudflare Tunnel
const String voiceCloudUrl =
    'https://smarthome-audio-control.lamnguyenxuan.id.vn';

// Cloud (Cloudflare Tunnel) API base
const String cloudUrl =
    'https://smarthome-backend-account.lamnguyenxuan.id.vn/api';

// Device identifier used by the app
const String deviceId = 'esp32_1';

// Connectivity probing
const String connectivityHealthPath = '/health';
const Duration connectivityProbeTimeout =
    Duration(milliseconds: 800); // 500ms - 1s
const Duration connectivityProbeInterval = Duration(seconds: 15); // 10-20s

// ================= FACE AI =================
// Local: PC chạy face_server trên hotspot
const String faceAiLocalBase =
    kIsWeb ? 'http://127.0.0.1:8888' : 'http://$_mobileHostIp:8888';
// Cloud: Cloudflare Tunnel
const String faceAiCloudBase =
    'https://smarthome-face-server.lamnguyenxuan.id.vn';

// API nhận video
const String faceRecognizeVideoPath = '/recognize';

// ================= ESP32-CAM (DOOR CAM) =================
// Static IP of ESP32-CAM on the hotspot network (set in ESP32-CAM firmware)
const String _esp32CamIp = '192.168.137.100';
const String esp32CamLocalBase = 'http://$_esp32CamIp';

// Cloud proxy endpoint (through backend_account Cloudflare Tunnel)
const String esp32CamCloudSnapshotUrl =
    'https://smarthome-backend-account.lamnguyenxuan.id.vn/api/cam/snapshot';

// Endpoint trigger nhận diện + mở cửa
const String esp32CamOpenDoorPath = '/open_cam';

// ================= AUTH =================
const String loginByFacePath = '/auth/login-face';
