import 'package:flutter/material.dart';
import '../widgets/device_dashboard.dart';

class GuestDashboardScreen extends StatelessWidget {
  const GuestDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DeviceDashboard(
        enabled: false,
        onAction: _staticNoop,
      ),
    );
  }

  // Workaround for const usage of function
  static Future<void> _staticNoop(String action) async {}
}
