// Centralized app configuration

// Local network API base (replace with your laptop's static LAN IP)
const String localUrl = 'http://192.168.31.100:4000/api';

// Cloud (Ngrok) API base
const String cloudUrl = 'https://lorna-biometrical-ireland.ngrok-free.dev/api';

// Device identifier used by the app
const String deviceId = 'esp32_1';

// Common headers
const String ngrokHeaderName = 'ngrok-skip-browser-warning';
const String ngrokHeaderValue = 'true';

// Connectivity probing
const String connectivityHealthPath = '/health';
const Duration connectivityProbeTimeout =
    Duration(milliseconds: 800); // 500ms - 1s
const Duration connectivityProbeInterval = Duration(seconds: 15); // 10-20s
