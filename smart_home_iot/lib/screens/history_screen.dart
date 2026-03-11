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
  static const _warningColor = Color(0xFFF39C12);

  int _selectedTab = 0;
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  String? _error;

  // Tabs: All | Controls | Security
  final List<_TabInfo> _tabs = [
    _TabInfo('All', Icons.list_alt, null),
    _TabInfo('Controls', Icons.gamepad_outlined,
        'control_device,door_open,door_close,system_mode_change'),
    _TabInfo('Security', Icons.shield_outlined,
        'set_snooze,cancel_snooze,change_password,alarm_trigger'),
  ];

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

      String endpoint = '/action-logs?limit=50&page=1';
      final filter = _tabs[_selectedTab].filter;
      if (filter != null) {
        endpoint += '&actionType=$filter';
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
          _error = 'Load error: ${response.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Connection error: $e';
        _loading = false;
      });
    }
  }

  // ─── Helpers ───

  /// Group events by date label: "Today", "Yesterday", or "dd/MM/yyyy"
  Map<String, List<Map<String, dynamic>>> _groupByDate() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final event in _events) {
      final raw = event['createdAt'] ?? '';
      DateTime? dt;
      try {
        dt = DateTime.parse(raw).toLocal();
      } catch (_) {}

      String label;
      if (dt == null) {
        label = 'Unknown';
      } else {
        final day = DateTime(dt.year, dt.month, dt.day);
        if (day == today) {
          label = 'Today';
        } else if (day == yesterday) {
          label = 'Yesterday';
        } else {
          label = DateFormat('dd/MM/yyyy').format(dt);
        }
      }
      groups.putIfAbsent(label, () => []);
      groups[label]!.add(event);
    }
    return groups;
  }

  /// Relative time: "just now", "3 min ago", "2 hrs ago", or HH:mm
  String _relativeTime(String raw) {
    try {
      final dt = DateTime.parse(raw).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inSeconds < 60) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
      if (diff.inHours < 12) return '${diff.inHours} hrs ago';
      return DateFormat('HH:mm').format(dt);
    } catch (_) {
      return raw;
    }
  }

  /// Icon + color for each actionType
  _ActionStyle _styleFor(String actionType, String action) {
    switch (actionType) {
      case 'door_open':
        return _ActionStyle(Icons.door_front_door, _successColor);
      case 'door_close':
        return _ActionStyle(Icons.door_front_door_outlined, _accentColor);
      case 'control_device':
        if (action == 'open_awning') {
          return _ActionStyle(Icons.roofing, _successColor);
        } else if (action == 'close_awning') {
          return _ActionStyle(Icons.roofing_outlined, _accentColor);
        }
        return _ActionStyle(Icons.touch_app, _accentColor);
      case 'system_mode_change':
        if (action == 'set_auto') {
          return _ActionStyle(Icons.auto_mode, const Color(0xFF9B59B6));
        }
        return _ActionStyle(Icons.back_hand, const Color(0xFF9B59B6));
      case 'set_snooze':
        return _ActionStyle(Icons.notifications_off, _warningColor);
      case 'cancel_snooze':
        return _ActionStyle(Icons.notifications_active, _successColor);
      case 'change_password':
        return _ActionStyle(Icons.lock, _warningColor);
      case 'alarm_trigger':
        return _ActionStyle(Icons.warning_amber, _dangerColor);
      default:
        return _ActionStyle(Icons.info_outline, _textColor);
    }
  }

  /// Fallback description when backend doesn't provide one
  String _fallbackDescription(String actionType, String action) {
    const map = {
      'open_door': 'Open door',
      'close_door': 'Close door',
      'open_awning': 'Open awning',
      'close_awning': 'Close awning',
      'set_auto': 'Auto mode',
      'set_manual': 'Manual mode',
      'set_snooze': 'Snooze alerts',
      'cancel_snooze': 'Resume alerts',
      'change_password': 'Change password',
      'door_open': 'Door opened',
      'door_close': 'Door closed',
      'alarm_trigger': 'Alarm triggered',
    };
    return map[action] ?? map[actionType] ?? actionType;
  }

  /// Source display label
  String _sourceLabel(String source) {
    const map = {
      'app': 'App',
      'keypad': 'Keypad',
      'system': 'System',
      'remote': 'Remote',
      'schedule': 'Schedule',
    };
    return map[source] ?? source;
  }

  /// Username display — clean, no emoji
  String _displayUsername(String username, String source) {
    if (username == 'system' || username == 'voice_assistant') {
      return 'System';
    }
    if (username == 'admin_physical') return 'Admin (Physical)';
    if (username == 'unknown_physical') return 'User (Physical)';
    if (username == 'local_user') return 'Local device';
    if (username == 'unknown') return 'Unknown';
    return username;
  }

  // ─── UI Builders ───

  Widget _buildSegmentedControl() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withOpacity(0.7),
            offset: const Offset(-3, -3),
            blurRadius: 6,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            offset: const Offset(3, 3),
            blurRadius: 6,
          ),
        ],
      ),
      child: Row(
        children: List.generate(_tabs.length, (index) {
          final isSelected = _selectedTab == index;
          final tab = _tabs[index];
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (_selectedTab == index) return;
                setState(() => _selectedTab = index);
                _loadHistory();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected ? _accentColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: _accentColor.withOpacity(0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      tab.icon,
                      size: 16,
                      color: isSelected ? Colors.white : _textColor,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        tab.label,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected ? Colors.white : _textColor,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDateHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: _textColor.withOpacity(0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: _textColor.withOpacity(0.1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final actionType = event['actionType'] as String? ?? '';
    final performedBy = event['performedBy'] as Map<String, dynamic>? ?? {};
    final username = performedBy['username'] as String? ?? 'unknown';
    final source = performedBy['source'] as String? ?? '';
    final details = event['details'] as Map<String, dynamic>? ?? {};
    final action = details['action'] as String? ?? actionType;
    final description = details['description'] as String? ??
        _fallbackDescription(actionType, action);
    final createdAt = event['createdAt'] as String? ?? '';
    final result = event['result'] as Map<String, dynamic>? ?? {};
    final status = result['status'] as String? ?? 'unknown';

    final style = _styleFor(actionType, action);
    final displayUser = _displayUsername(username, source);
    final timeStr = _relativeTime(createdAt);

    return GestureDetector(
      onTap: () => _showEventDetail(event),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _bgColor,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withOpacity(0.7),
              offset: const Offset(-4, -4),
              blurRadius: 8,
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              offset: const Offset(4, 4),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(
          children: [
            // Icon circle
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: style.color.withOpacity(0.12),
              ),
              child: Icon(style.icon, color: style.color, size: 22),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Description (main line)
                  Text(
                    description,
                    style: const TextStyle(
                      color: _textColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  // Username + source
                  Row(
                    children: [
                      Icon(
                        _sourceIcon(source),
                        size: 12,
                        color: _textColor.withOpacity(0.45),
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          '$displayUser · ${_sourceLabel(source)}',
                          style: TextStyle(
                            color: _textColor.withOpacity(0.55),
                            fontSize: 11.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Right: time + status
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    color: _textColor.withOpacity(0.45),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                _buildStatusDot(status),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _sourceIcon(String source) {
    switch (source) {
      case 'app':
        return Icons.phone_android;
      case 'keypad':
        return Icons.dialpad;
      case 'system':
        return Icons.smart_toy_outlined;
      case 'schedule':
        return Icons.schedule;
      default:
        return Icons.devices;
    }
  }

  Widget _buildStatusDot(String status) {
    Color dotColor;
    String label;
    switch (status) {
      case 'success':
        dotColor = _successColor;
        label = 'OK';
        break;
      case 'failed':
        dotColor = _dangerColor;
        label = 'Fail';
        break;
      case 'pending':
        dotColor = _warningColor;
        label = 'Wait';
        break;
      default:
        dotColor = _textColor.withOpacity(0.3);
        label = '?';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: dotColor,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Show detail bottom sheet when tapping an event card
  void _showEventDetail(Map<String, dynamic> event) {
    final actionType = event['actionType'] as String? ?? '';
    final performedBy = event['performedBy'] as Map<String, dynamic>? ?? {};
    final username = performedBy['username'] as String? ?? 'unknown';
    final source = performedBy['source'] as String? ?? '';
    final details = event['details'] as Map<String, dynamic>? ?? {};
    final action = details['action'] as String? ?? actionType;
    final description = details['description'] as String? ??
        _fallbackDescription(actionType, action);
    final parameters = details['parameters'] as Map<String, dynamic>?;
    final createdAt = event['createdAt'] as String? ?? '';
    final result = event['result'] as Map<String, dynamic>? ?? {};
    final status = result['status'] as String? ?? 'unknown';
    final resultMsg = result['message'] as String? ?? '';
    final deviceId = event['deviceId'] as String? ?? '';

    final style = _styleFor(actionType, action);

    String fullTime = '';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      fullTime = DateFormat('HH:mm:ss · dd/MM/yyyy').format(dt);
    } catch (_) {
      fullTime = createdAt;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _bgColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _textColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              // Icon + title
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: style.color.withOpacity(0.12),
                ),
                child: Icon(style.icon, color: style.color, size: 28),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                style: const TextStyle(
                  color: _textColor,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Info rows
              _detailRow('Status', _statusLabel(status), _statusColor(status)),
              if (resultMsg.isNotEmpty) _detailRow('Result', resultMsg, null),
              _detailRow(
                  'Performed by', _displayUsername(username, source), null),
              _detailRow('Source', _sourceLabel(source), null),
              if (deviceId.isNotEmpty) _detailRow('Device', deviceId, null),
              _detailRow('Time', fullTime, null),
              if (parameters != null && parameters.isNotEmpty)
                _detailRow(
                    'Parameters',
                    parameters.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join(', '),
                    null),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value, Color? valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: _textColor.withOpacity(0.5),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? _textColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'success':
        return 'Success';
      case 'failed':
        return 'Failed';
      case 'pending':
        return 'Pending';
      default:
        return 'Unknown';
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'success':
        return _successColor;
      case 'failed':
        return _dangerColor;
      case 'pending':
        return _warningColor;
      default:
        return _textColor;
    }
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(20, 48, 16, 12),
          color: _bgColor,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'History',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _bgColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withOpacity(0.7),
                      offset: const Offset(-2, -2),
                      blurRadius: 4,
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      offset: const Offset(2, 2),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: _accentColor),
                  onPressed: _loadHistory,
                  tooltip: 'Refresh',
                  iconSize: 22,
                ),
              ),
            ],
          ),
        ),
        _buildSegmentedControl(),
        // Content
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: _accentColor),
                )
              : _error != null
                  ? _buildErrorView()
                  : _events.isEmpty
                      ? _buildEmptyView()
                      : _buildEventList(),
        ),
      ],
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 56, color: _dangerColor.withOpacity(0.6)),
            const SizedBox(height: 16),
            Text(
              _error!,
              style:
                  TextStyle(color: _textColor.withOpacity(0.7), fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _loadHistory,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: TextButton.styleFrom(foregroundColor: _accentColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined,
              size: 56, color: _textColor.withOpacity(0.25)),
          const SizedBox(height: 12),
          Text(
            'No history yet',
            style: TextStyle(
              color: _textColor.withOpacity(0.45),
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList() {
    final groups = _groupByDate();
    return RefreshIndicator(
      onRefresh: _loadHistory,
      color: _accentColor,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 20),
        itemCount:
            groups.entries.fold<int>(0, (sum, e) => sum + 1 + e.value.length),
        itemBuilder: (context, index) {
          // Flatten groups into a single list with headers
          int cursor = 0;
          for (final entry in groups.entries) {
            if (index == cursor) {
              return _buildDateHeader(entry.key);
            }
            cursor++;
            if (index < cursor + entry.value.length) {
              return _buildEventCard(entry.value[index - cursor]);
            }
            cursor += entry.value.length;
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

// ─── Helper classes ───

class _TabInfo {
  final String label;
  final IconData icon;
  final String? filter;
  const _TabInfo(this.label, this.icon, this.filter);
}

class _ActionStyle {
  final IconData icon;
  final Color color;
  const _ActionStyle(this.icon, this.color);
}
