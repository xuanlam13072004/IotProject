import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../services/connectivity_service.dart';

// Content-only widget (no Scaffold, no BottomBar)
class HistoryContent extends StatefulWidget {
  final bool isAdmin;

  const HistoryContent({super.key, required this.isAdmin});

  @override
  State<HistoryContent> createState() => _HistoryContentState();
}

class _HistoryContentState extends State<HistoryContent> {
  static const _bgColor = Color(0xFFDCE5F0);
  static const _textColor = Color(0xFF3E4E5E);
  static const _accentColor = Color(0xFF5D9CEC);
  static const _dangerColor = Color(0xFFE74C3C);
  static const _successColor = Color(0xFF2ECC71);

  int _selectedTab = 0;
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  String? _error;

  final List<String> _tabs = ['All Events', 'Alerts', 'User Actions'];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');

      if (token == null) {
        setState(() {
          _error = 'Not logged in';
          _loading = false;
        });
        return;
      }

      // Build URL with filters
      String endpoint = '/action-logs?limit=50&page=1';
      if (_selectedTab == 1) {
        // Alerts: snooze, cancel_snooze
        endpoint += '&actionType=set_snooze,cancel_snooze';
      } else if (_selectedTab == 2) {
        // User Actions: control_device, change_password
        endpoint += '&actionType=control_device,change_password';
      }

      final url = connectivityService.uri(endpoint);
      final response = await http.get(
        url,
        headers: connectivityService.buildHeaders(token: token),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _events =
              (data['logs'] as List<dynamic>).cast<Map<String, dynamic>>();
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Data load error: ${response.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  Widget _buildSegmentedControl() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withOpacity(0.7),
            offset: const Offset(-4, -4),
            blurRadius: 8,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            offset: const Offset(4, 4),
            blurRadius: 8,
          ),
        ],
      ),
      child: Row(
        children: List.generate(_tabs.length, (index) {
          final isSelected = _selectedTab == index;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedTab = index;
                });
                _loadHistory();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected ? _accentColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: _accentColor.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [],
                ),
                child: Text(
                  _tabs[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSelected ? Colors.white : _textColor,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final actionType = event['actionType'] ?? '';
    final performedBy = event['performedBy'] ?? {};
    final username = performedBy['username'] ?? 'Unknown';
    final source = performedBy['source'] ?? '';
    final details = event['details'] ?? {};
    final description = details['description'] ?? actionType;
    final createdAt = event['createdAt'] ?? '';
    final result = event['result'] ?? {};
    final status = result['status'] ?? 'unknown';

    // Determine icon and color based on action type
    IconData icon;
    Color iconColor;
    Color glowColor;

    if (actionType == 'set_snooze' || actionType == 'cancel_snooze') {
      icon = Icons.notifications_off;
      iconColor = _dangerColor;
      glowColor = _dangerColor.withOpacity(0.3);
    } else if (actionType == 'change_password') {
      icon = Icons.lock;
      iconColor = const Color(0xFFF39C12);
      glowColor = const Color(0xFFF39C12).withOpacity(0.3);
    } else if (source == 'system') {
      icon = Icons.settings_suggest;
      iconColor = _successColor;
      glowColor = _successColor.withOpacity(0.3);
    } else {
      icon = Icons.touch_app;
      iconColor = _accentColor;
      glowColor = _accentColor.withOpacity(0.3);
    }

    // Format datetime
    String formattedTime = '';
    try {
      final dateTime = DateTime.parse(createdAt);
      formattedTime =
          DateFormat('dd/MM/yyyy HH:mm:ss').format(dateTime.toLocal());
    } catch (e) {
      formattedTime = createdAt;
    }

    // Format username display
    String displayUsername = username;
    if (username == 'system') {
      displayUsername = '🤖 System (AUTO)';
    } else if (username == 'admin_physical') {
      displayUsername = '🔒 Admin (Physical)';
    } else if (username == 'unknown_physical') {
      displayUsername = '👤 User (Physical)';
    } else {
      displayUsername = '👤 $username (${_getSourceLabel(source)})';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withOpacity(0.7),
            offset: const Offset(-6, -6),
            blurRadius: 12,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            offset: const Offset(6, 6),
            blurRadius: 12,
          ),
        ],
      ),
      child: Row(
        children: [
          // Icon with glow effect
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _bgColor,
              boxShadow: [
                BoxShadow(
                  color: glowColor,
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.7),
                  offset: const Offset(-3, -3),
                  blurRadius: 6,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  offset: const Offset(3, 3),
                  blurRadius: 6,
                ),
              ],
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 16),
          // Event details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayUsername,
                  style: TextStyle(
                    color: _textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: _textColor.withOpacity(0.7),
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 12,
                      color: _textColor.withOpacity(0.5),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      formattedTime,
                      style: TextStyle(
                        color: _textColor.withOpacity(0.5),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _buildStatusBadge(status),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color badgeColor;
    String label;

    switch (status) {
      case 'success':
        badgeColor = _successColor;
        label = 'Success';
        break;
      case 'failed':
        badgeColor = _dangerColor;
        label = 'Failed';
        break;
      case 'pending':
        badgeColor = const Color(0xFFF39C12);
        label = 'Processing';
        break;
      default:
        badgeColor = _textColor;
        label = 'Unknown';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: badgeColor.withOpacity(0.3), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: badgeColor,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _getSourceLabel(String source) {
    switch (source) {
      case 'app':
        return 'App';
      case 'keypad':
        return 'Keypad';
      case 'button':
        return 'Button';
      case 'system':
        return 'System';
      default:
        return source;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // AppBar-like header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          color: _bgColor,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'History',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: Icon(Icons.refresh, color: _accentColor),
                onPressed: _loadHistory,
                tooltip: 'Refresh',
              ),
            ],
          ),
        ),
        _buildSegmentedControl(),
        Expanded(
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(color: _accentColor),
                )
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline,
                              size: 64, color: _dangerColor),
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            style: TextStyle(color: _textColor, fontSize: 16),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _loadHistory,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentColor,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _events.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.history,
                                  size: 64, color: _textColor.withOpacity(0.3)),
                              const SizedBox(height: 16),
                              Text(
                                'No history yet',
                                style: TextStyle(
                                  color: _textColor.withOpacity(0.5),
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _loadHistory,
                          color: _accentColor,
                          child: ListView.builder(
                            padding: const EdgeInsets.only(bottom: 16),
                            itemCount: _events.length,
                            itemBuilder: (context, index) {
                              return _buildEventCard(_events[index]);
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}
