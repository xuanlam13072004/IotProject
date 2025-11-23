import 'package:flutter/material.dart';
import 'admin_manage_users.dart';
import 'user_dashboard.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  int _currentIndex = 0;

  final _pages = const [
    UserDashboardScreen(),
    AdminManageUsersScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFDCE5F0),
          boxShadow: [
            BoxShadow(
              color: Colors.white,
              offset: Offset(0, -3),
              blurRadius: 8,
            ),
            BoxShadow(
              color: Color(0xFFA6BCCF),
              offset: Offset(0, 3),
              blurRadius: 8,
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF3E4E5E),
          unselectedItemColor: const Color(0xFF3E4E5E).withOpacity(0.5),
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.tune), label: 'Control'),
            BottomNavigationBarItem(
                icon: Icon(Icons.manage_accounts), label: 'Manage'),
          ],
        ),
      ),
    );
  }
}
