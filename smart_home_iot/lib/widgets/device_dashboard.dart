import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/connectivity_service.dart';
import 'neumorphic_container.dart';

class DeviceDashboard extends StatefulWidget {
  final bool enabled;
  final Future<void> Function(String action) onAction;
  final bool isAdmin;
  final Map<String, dynamic> permissions;
  final VoidCallback? onEsp32FaceAuth;

  const DeviceDashboard({
    super.key,
    required this.enabled,
    required this.onAction,
    this.isAdmin = false,
    this.permissions = const {},
    this.onEsp32FaceAuth,
  });

  @override
  State<DeviceDashboard> createState() => _DeviceDashboardState();
}

class _DeviceDashboardState extends State<DeviceDashboard> {
  Timer? _pollTimer;
  Timer? _countdownTimer;
  late final VoidCallback _modeListener;

  // Real-time sensor data from API
  double temperature = 0;
  double humidity = 0;
  int gasValue = 0;
  double voltage = 0.0;
  double current = 0.0;
  double power = 0.0;
  bool fireAlert = false;
  bool awningOpen = false;
  bool doorOpen = false;
  bool raining = false;
  bool awningAutoMode = false;

  // Alarm mute state from API
  List<String> mutedSensors =
      []; // ['all'], ['fire'], ['gas'], or ['fire', 'gas']
  DateTime? muteEndsAt;
  String selectedSensor = 'all'; // UI dropdown selection

  bool wifiConnected = false; // API call success (not used for mode icons)
  double _gateSlide = 0.0;
  bool _showDoorCamInCard = false;
  int _doorCamTs = DateTime.now().millisecondsSinceEpoch;
  Timer? _doorCamRefreshTimer;
  String? _camAuthToken;

  // Door password change state
  final _newPasswordController = TextEditingController();
  bool _changingPassword = false;

  static const _bgColor = Color(0xFFDCE5F0);
  static const _textColor = Color(0xFF3E4E5E);

  TextStyle get _titleStyle => const TextStyle(
        color: _textColor,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      );

  TextStyle get _labelStyle => const TextStyle(
        color: _textColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      );

  TextStyle get _valueStyle => const TextStyle(
        color: _textColor,
        fontSize: 16,
        fontWeight: FontWeight.w800,
      );

  @override
  void initState() {
    super.initState();
    // React to connectivity mode changes (Local/Cloud) by refetching immediately
    _modeListener = () {
      _fetchLatestData();
    };
    connectivityService.modeNotifier.addListener(_modeListener);

    _fetchLatestData(); // Immediate fetch
    _pollTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _fetchLatestData());

    // Load auth token for cloud cam proxy
    SharedPreferences.getInstance().then((prefs) {
      _camAuthToken = prefs.getString('user_token');
    });

    // Countdown timer for alarm UI updates
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && mutedSensors.isNotEmpty) setState(() {});
    });
  }

  // Permission helper - admin has all permissions
  bool _hasPermission(String category, String action) {
    if (widget.isAdmin) return true;
    try {
      final categoryPerms = widget.permissions[category];
      if (categoryPerms == null) return false;
      if (categoryPerms is! Map) return false;
      return categoryPerms[action] == true;
    } catch (e) {
      return false;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _doorCamRefreshTimer?.cancel();
    _newPasswordController.dispose();
    connectivityService.modeNotifier.removeListener(_modeListener);
    super.dispose();
  }

  Future<void> _fetchLatestData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('user_token');
      if (token == null) return;

      final url = connectivityService.uri('/devices/$deviceId/data/latest');
      final headers = connectivityService.buildHeaders(token: token);
      final response = await http.get(url, headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            temperature = (data['temperature'] ?? 0).toDouble();
            humidity = (data['humidity'] ?? 0).toDouble();
            gasValue = (data['gasValue'] ?? 0).toInt();
            voltage = (data['voltage'] ?? 0).toDouble();
            current = (data['current'] ?? 0).toDouble();
            power = (data['power'] ?? 0).toDouble();
            fireAlert = data['fireAlert'] ?? false;
            awningOpen = data['awningOpen'] ?? false;
            doorOpen = data['doorOpen'] ?? false;
            raining = data['raining'] ?? false;
            awningAutoMode = data['awningAutoMode'] ?? false;
            mutedSensors = List<String>.from(data['mutedSensors'] ?? []);
            muteEndsAt = data['muteEndsAt'] != null
                ? DateTime.parse(data['muteEndsAt'])
                : null;
            wifiConnected = true;
          });
        }
      } else {
        if (mounted) setState(() => wifiConnected = false);
      }
    } catch (e) {
      if (mounted) setState(() => wifiConnected = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bgColor,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              _buildStatusBar(),
              const SizedBox(height: 24),
              _buildSensorRow(),
              const SizedBox(height: 24),
              _buildControlGrid(),
              const SizedBox(height: 24),
              if (_hasPermission('alarm', 'view')) _buildAlarmManagement(),
              if (_hasPermission('alarm', 'view')) const SizedBox(height: 24),
              if (widget.isAdmin) _buildDoorSecurityCard(),
              if (widget.isAdmin) const SizedBox(height: 24),
              // Đã xóa _buildBottomNavigation() ở đây để tránh trùng lặp giao diện
            ],
          ),
        ),
      ),
    );
  }

  // 1) Status Bar
  Widget _buildStatusBar() {
    return ValueListenableBuilder<ConnectivityMode>(
      valueListenable: connectivityService.modeNotifier,
      builder: (context, mode, _) {
        final bool localActive = mode == ConnectivityMode.local;
        final bool cloudActive = mode == ConnectivityMode.cloud;
        final bool offline = mode == ConnectivityMode.offline;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildStatusIcon(Icons.cloud_outlined, cloudActive),
            const SizedBox(width: 16),
            _buildStatusIcon(Icons.wifi, localActive),
          ],
        );
      },
    );
  }

  Widget _buildStatusIcon(IconData icon, bool isActive) {
    return NeumorphicContainer(
      width: 50,
      height: 50,
      isActive: isActive,
      borderRadius: BorderRadius.circular(25),
      padding: EdgeInsets.zero,
      child: Center(
        child: Icon(
          icon,
          color: isActive ? Colors.blue : _textColor.withValues(alpha: 0.55),
          size: 22,
        ),
      ),
    );
  }

  // 2) Sensor Row
  Widget _buildSensorRow() {
    final canTemp = _hasPermission('sensors', 'viewTemperature');
    final canHum = _hasPermission('sensors', 'viewHumidity');
    final canGas = _hasPermission('sensors', 'viewGas');
    final canFire = _hasPermission('sensors', 'viewFire');

    final anySensor = canTemp || canHum || canGas || canFire;

    if (!anySensor) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No permission to view sensors',
          style: _labelStyle.copyWith(
            color: _textColor.withValues(alpha: 0.5),
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    final sensors = <Widget>[];

    if (canTemp) {
      sensors.add(Expanded(
        child: _buildSensorCard('assets/icon/Thermometer.json',
            '${temperature.toStringAsFixed(1)}°C', Colors.orange),
      ));
    }
    if (canHum) {
      if (sensors.isNotEmpty) sensors.add(const SizedBox(width: 14));
      sensors.add(Expanded(
        child: _buildSensorCard('assets/icon/humidity.json',
            '${humidity.toStringAsFixed(0)}%', Colors.blue),
      ));
    }
    if (canGas) {
      if (sensors.isNotEmpty) sensors.add(const SizedBox(width: 14));
      sensors.add(Expanded(
        child: _buildSensorCard(
            'assets/icon/GAS Cylinder.json',
            gasValue > 1000 ? 'Danger' : 'Safe',
            gasValue > 1000 ? Colors.red : Colors.green),
      ));
    }
    if (canFire) {
      if (sensors.isNotEmpty) sensors.add(const SizedBox(width: 14));
      sensors.add(Expanded(
        child: _buildSensorCard(
            'assets/icon/Fire.json',
            fireAlert ? 'Danger' : 'Safe',
            fireAlert ? Colors.redAccent : Colors.deepOrange),
      ));
    }

    final powerSensors = <Widget>[];
    if (anySensor) {
      powerSensors.add(Expanded(
        child: _buildSensorCard('assets/icon/charging.json',
            '${voltage.toStringAsFixed(1)}V', Colors.purple),
      ));
      powerSensors.add(const SizedBox(width: 14));
      powerSensors.add(Expanded(
        child: _buildSensorCard('assets/icon/lightning.json',
            '${current.toStringAsFixed(2)}A', Colors.cyan),
      ));
      powerSensors.add(const SizedBox(width: 14));
      powerSensors.add(Expanded(
        child: _buildSensorCard('assets/icon/electric.json',
            '${power.toStringAsFixed(1)}W', Colors.amber),
      ));
    }

    return Column(
      children: [
        Row(children: sensors),
        if (powerSensors.isNotEmpty) const SizedBox(height: 14),
        if (powerSensors.isNotEmpty) Row(children: powerSensors),
      ],
    );
  }

  Widget _buildSensorCard(String lottieAsset, String value, Color iconColor) {
    return NeumorphicContainer(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: Lottie.asset(
              lottieAsset,
              fit: BoxFit.contain,
              repeat: true,
              errorBuilder: (context, error, stackTrace) {
                return Icon(Icons.sensors, size: 36, color: iconColor);
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(value, style: _valueStyle),
        ],
      ),
    );
  }

  // 3) Control Grid
  Widget _buildControlGrid() {
    return Column(
      children: [
        if (_hasPermission('door', 'view')) ...[
          _buildMainGateCard(),
          const SizedBox(height: 18),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_hasPermission('awning', 'view'))
              Expanded(
                child: SizedBox(
                  height: 290,
                  child: _buildAutomatedRoofCard(),
                ),
              ),
            if (_hasPermission('awning', 'view')) const SizedBox(width: 18),
            Expanded(
              child: SizedBox(
                height: 290,
                child: _buildEsp32CamCard(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildFanCard(),
      ],
    );
  }

  Widget _buildMainGateCard() {
    return NeumorphicContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Main Gate', style: _titleStyle),
          const SizedBox(height: 14),
          _buildCompactGateSlider(),
        ],
      ),
    );
  }

  Widget _buildCompactGateSlider() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double trackWidth = 260;
        final double handleSize = 48;
        final double maxTravel = trackWidth - handleSize - 8;
        final double leftPos = 4 + _gateSlide * maxTravel;
        final double openProgress = doorOpen ? (1 - _gateSlide) : _gateSlide;
        final Color trackColor = Color.lerp(
          Colors.blue.shade500,
          Colors.red.shade400,
          openProgress,
        )!;

        final String label = doorOpen ? 'Slide to Close' : 'Slide to Open';
        final IconData icon = doorOpen ? Icons.lock_open : Icons.lock_outline;

        return Center(
          child: Container(
            width: trackWidth,
            height: 56,
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(30),
              boxShadow: const [
                BoxShadow(
                    color: Colors.white, offset: Offset(-3, -3), blurRadius: 6),
                BoxShadow(
                    color: Color(0xFFA6BCCF),
                    offset: Offset(3, 3),
                    blurRadius: 6),
              ],
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Center(
                  child: Text(
                    label,
                    style: _labelStyle.copyWith(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.95),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  left: leftPos,
                  top: 4,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      if (!widget.enabled) return;
                      setState(() {
                        _gateSlide = (_gateSlide + details.delta.dx / maxTravel)
                            .clamp(0.0, 1.0);
                      });
                    },
                    onHorizontalDragEnd: (_) => _onGateSlideEnd(),
                    child: Container(
                      width: handleSize,
                      height: handleSize,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.white,
                              offset: Offset(-3, -3),
                              blurRadius: 6),
                          BoxShadow(
                              color: Color(0xFFA6BCCF),
                              offset: Offset(3, 3),
                              blurRadius: 6),
                        ],
                      ),
                      child: Icon(
                        icon,
                        color: doorOpen
                            ? Colors.red.shade400
                            : Colors.blue.shade600,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onGateSlideEnd() async {
    if (!widget.enabled) return;

    // Check permission before allowing action
    final action = doorOpen ? 'close_door' : 'open_door';
    final permissionAction = doorOpen ? 'close' : 'open';
    if (!_hasPermission('door', permissionAction)) {
      setState(() => _gateSlide = 0.0);
      return;
    }

    if (_gateSlide >= 0.9) {
      // Update UI optimistically before sending command
      setState(() {
        doorOpen = !doorOpen;
        _gateSlide = 0.0;
      });

      // Send command (don't await to keep UI responsive)
      widget.onAction(action);
      // Timer will sync real state in next 3s poll
    } else {
      setState(() => _gateSlide = 0.0);
    }
  }

  Widget _buildAutomatedRoofCard() {
    return NeumorphicContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Automated Roof', style: _titleStyle.copyWith(fontSize: 14)),
          const SizedBox(height: 14),
          _buildAwningOpenCloseButtons(),
          const SizedBox(height: 14),
          _buildAutoModeToggle(),
        ],
      ),
    );
  }

  Widget _buildAwningOpenCloseButtons() {
    final canOpen = _hasPermission('awning', 'open');
    final canClose = _hasPermission('awning', 'close');

    return Column(
      children: [
        NeumorphicButton(
          width: double.infinity,
          height: 50,
          borderRadius: BorderRadius.circular(16),
          onPressed: (widget.enabled && canOpen)
              ? () => widget.onAction('open_awning')
              : null,
          child: Center(
            child: Text(
              'Open Awning',
              style: _labelStyle.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: canOpen ? _textColor : _textColor.withValues(alpha: 0.3),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        NeumorphicButton(
          width: double.infinity,
          height: 50,
          borderRadius: BorderRadius.circular(16),
          onPressed: (widget.enabled && canClose)
              ? () => widget.onAction('close_awning')
              : null,
          child: Center(
            child: Text(
              'Close Awning',
              style: _labelStyle.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color:
                    canClose ? _textColor : _textColor.withValues(alpha: 0.3),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAutoModeToggle() {
    final canSetMode = _hasPermission('awning', 'setMode');

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Auto Mode', style: _labelStyle.copyWith(fontSize: 12)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: (widget.enabled && canSetMode) ? _toggleAutoMode : null,
          child: Opacity(
            opacity: canSetMode ? 1.0 : 0.4,
            child: Container(
              width: 50,
              height: 28,
              decoration: BoxDecoration(
                color: awningAutoMode ? Colors.green : const Color(0xFFCCD6E0),
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.white,
                      offset: Offset(-2, -2),
                      blurRadius: 4),
                  BoxShadow(
                      color: Color(0xFFA6BCCF),
                      offset: Offset(2, 2),
                      blurRadius: 4),
                ],
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment: awningAutoMode
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.all(3),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _bgColor,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.white,
                          offset: Offset(-1, -1),
                          blurRadius: 2),
                      BoxShadow(
                          color: Color(0xFFA6BCCF),
                          offset: Offset(1, 1),
                          blurRadius: 2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleAutoMode() async {
    final newMode = !awningAutoMode;
    final action = newMode ? 'set_auto' : 'set_manual';

    // Update UI optimistically
    setState(() {
      awningAutoMode = newMode;
    });

    // Send command (don't await to keep UI responsive)
    widget.onAction(action);
  }

  void _toggleDoorCamInCard() {
    if (_showDoorCamInCard) {
      _doorCamRefreshTimer?.cancel();
      _doorCamRefreshTimer = null;
      setState(() {
        _showDoorCamInCard = false;
      });
      return;
    }

    setState(() {
      _showDoorCamInCard = true;
      _doorCamTs = DateTime.now().millisecondsSinceEpoch;
    });

    _doorCamRefreshTimer?.cancel();
    _doorCamRefreshTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted || !_showDoorCamInCard) return;
      setState(() {
        _doorCamTs = DateTime.now().millisecondsSinceEpoch;
      });
    });
  }

  Widget _buildEsp32CamCard() {
    final canUseCamera = _hasPermission('camera', 'use');
    final imageUrl = connectivityService.camSnapshotUrl(ts: _doorCamTs);
    final isCloud = !connectivityService.isLocalMode;
    final headers = <String, String>{
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
    if (isCloud && _camAuthToken != null) {
      headers['Authorization'] = 'Bearer $_camAuthToken';
    }
    final card = NeumorphicContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Door Camera', style: _titleStyle.copyWith(fontSize: 14)),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: double.infinity,
                color: const Color(0xFFCCD6E0),
                child: _showDoorCamInCard
                    ? Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        headers: headers,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return const Center(
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) {
                          return Center(
                            child: Text(
                              'Unable to download camera image',
                              style: _labelStyle.copyWith(
                                color: _textColor.withValues(alpha: 0.7),
                              ),
                            ),
                          );
                        },
                      )
                    : Center(
                        child: Text(
                          'Press to open the door camera to view.',
                          style: _labelStyle.copyWith(
                            color: _textColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: NeumorphicButton(
              width: 74,
              height: 74,
              borderRadius: BorderRadius.circular(37),
              onPressed: (widget.enabled && canUseCamera)
                  ? _toggleDoorCamInCard
                  : null,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    _showDoorCamInCard ? Icons.videocam_off : Icons.videocam,
                    color: (widget.enabled && canUseCamera)
                        ? (_showDoorCamInCard ? Colors.red : Colors.blue)
                        : _textColor.withValues(alpha: 0.35),
                    size: 36,
                  ),
                  if (!canUseCamera)
                    Transform.rotate(
                      angle: -0.75,
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              !canUseCamera
                  ? 'Camera disabled by admin'
                  : (_showDoorCamInCard
                      ? 'Turn off door camera'
                      : 'Open door camera'),
              style: _labelStyle.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
    return card;
  }

  Widget _buildFanCard() {
    final card = NeumorphicContainer(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Smart Fan', style: _titleStyle),
                const SizedBox(height: 6),
                Text(
                  'Stopped',
                  style: TextStyle(
                    color: _textColor.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          NeumorphicButton(
            width: 70,
            height: 70,
            borderRadius: BorderRadius.circular(35),
            onPressed: null,
            child: Icon(
              Icons.mode_fan_off_outlined,
              color: _textColor.withValues(alpha: 0.35),
              size: 36,
            ),
          ),
        ],
      ),
    );

    return _dimUnavailable(card, 'Coming Soon');
  }

  Widget _dimUnavailable(Widget child, String message) {
    return Stack(
      children: [
        Opacity(opacity: 0.6, child: child),
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Center(
              child: Text(
                message,
                style: _labelStyle.copyWith(
                  fontSize: 13,
                  color: _textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlarmManagement() {
    final bool hasMutedSensors = mutedSensors.isNotEmpty;

    return NeumorphicContainer(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notifications_paused, color: _textColor, size: 24),
              const SizedBox(width: 12),
              Text('Alarm Management', style: _titleStyle),
            ],
          ),
          const SizedBox(height: 16),

          // Dropdown chọn thiết bị (only show sensors user has permission for)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _bgColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.9),
                  offset: const Offset(-3, -3),
                  blurRadius: 6,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  offset: const Offset(3, 3),
                  blurRadius: 6,
                ),
              ],
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedSensor,
                isExpanded: true,
                dropdownColor: _bgColor,
                style: _labelStyle.copyWith(fontSize: 14),
                items: _buildSensorDropdownItems(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => selectedSensor = value);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Show countdown and status if muted
          if (hasMutedSensors && muteEndsAt != null) ...[
            _buildMutedSensorsStatus(),
            const SizedBox(height: 12),
            _buildCountdownTimer(),
            const SizedBox(height: 16),
            // Admin/authorized cancel button
            if (_canCancelSnooze()) ...[
              GestureDetector(
                onTap: () =>
                    widget.onAction('cancel_snooze&sensor=$selectedSensor'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_active,
                          color: Colors.red[700], size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Reactivate ${_getSensorName(selectedSensor)}${widget.isAdmin ? " (Admin)" : ""}',
                        style: _labelStyle.copyWith(
                          color: Colors.red[700],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],

          // Time chip buttons (only show if user has permission for selected sensor)
          if (_canSnoozeSelectedSensor())
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildTimeChip('3 min', 180),
                _buildTimeChip('5 min', 300),
                _buildTimeChip('10 min', 600),
                _buildTimeChip('30 min', 1800),
                _buildTimeChip('60 min', 3600),
              ],
            ),

          // Show message if user lacks permission
          if (!_canSnoozeSelectedSensor())
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock, color: Colors.orange[700], size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'No permission to snooze ${_getSensorName(selectedSensor)}',
                    style: _labelStyle.copyWith(
                      color: Colors.orange[700],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _canCancelSnooze() {
    return _hasPermission('alarm', 'cancelSnooze');
  }

  bool _canSnoozeSelectedSensor() {
    switch (selectedSensor) {
      case 'all':
        return _hasPermission('alarm', 'snoozeAll');
      case 'fire':
        return _hasPermission('alarm', 'snoozeFire');
      case 'gas':
        return _hasPermission('alarm', 'snoozeGas');
      default:
        return false;
    }
  }

  List<DropdownMenuItem<String>> _buildSensorDropdownItems() {
    final items = <DropdownMenuItem<String>>[];

    if (_hasPermission('alarm', 'snoozeAll')) {
      items.add(
          const DropdownMenuItem(value: 'all', child: Text('All Devices')));
    }

    if (_hasPermission('alarm', 'snoozeFire')) {
      items.add(
          const DropdownMenuItem(value: 'fire', child: Text('🔥 Fire Sensor')));
    }

    if (_hasPermission('alarm', 'snoozeGas')) {
      items.add(
          const DropdownMenuItem(value: 'gas', child: Text('💨 Gas Sensor')));
    }

    // If no permissions, show disabled all option
    if (items.isEmpty) {
      items.add(const DropdownMenuItem(
          value: 'all', enabled: false, child: Text('No Permission')));
    }

    return items;
  }

  String _getSensorName(String sensor) {
    switch (sensor) {
      case 'fire':
        return 'Fire Sensor';
      case 'gas':
        return 'Gas Sensor';
      default:
        return 'All';
    }
  }

  Widget _buildMutedSensorsStatus() {
    final List<String> mutedNames = mutedSensors.map((s) {
      if (s == 'all') return 'All';
      if (s == 'fire') return 'Fire';
      if (s == 'gas') return 'Gas';
      return s;
    }).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_off, color: Colors.blue[700], size: 20),
          const SizedBox(width: 8),
          Text(
            'Muted: ${mutedNames.join(", ")}',
            style: _labelStyle.copyWith(
              color: Colors.blue[700],
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeChip(String label, int seconds) {
    return GestureDetector(
      onTap: widget.enabled
          ? () => widget
              .onAction('set_snooze&seconds=$seconds&sensor=$selectedSensor')
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _bgColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.9),
              offset: const Offset(-4, -4),
              blurRadius: 8,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              offset: const Offset(4, 4),
              blurRadius: 8,
            ),
          ],
        ),
        child: Text(
          label,
          style: _labelStyle.copyWith(fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildCountdownTimer() {
    if (muteEndsAt == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final remaining = muteEndsAt!.difference(now);

    if (remaining.isNegative) {
      return Text(
        'Alarm reactivated',
        style: _labelStyle.copyWith(color: Colors.green, fontSize: 14),
      );
    }

    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer, color: Colors.orange[700], size: 20),
          const SizedBox(width: 8),
          Text(
            'Snoozed: ${minutes}m ${seconds}s',
            style: _labelStyle.copyWith(
              color: Colors.orange[700],
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDoorSecurityCard() {
    return NeumorphicContainer(
      padding: const EdgeInsets.all(24),
      borderRadius: BorderRadius.circular(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, color: _textColor, size: 28),
              const SizedBox(width: 12),
              Text(
                'Door Security',
                style: _labelStyle.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Change main door password',
            style: _labelStyle.copyWith(
              fontSize: 14,
              color: _textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _newPasswordController,
            maxLength: 8,
            obscureText: true,
            style: TextStyle(color: _textColor, fontSize: 16),
            decoration: InputDecoration(
              labelText: 'New Password (4-8 chars)',
              labelStyle: TextStyle(
                color: _textColor.withValues(alpha: 0.6),
                fontSize: 14,
              ),
              prefixIcon:
                  Icon(Icons.key, color: _textColor.withValues(alpha: 0.7)),
              filled: true,
              fillColor: Colors.grey.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide:
                    BorderSide(color: _textColor.withValues(alpha: 0.2)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide:
                    BorderSide(color: _textColor.withValues(alpha: 0.2)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                    color: Colors.blue.withValues(alpha: 0.5), width: 2),
              ),
              counterStyle: TextStyle(color: _textColor.withValues(alpha: 0.5)),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter password';
              }
              if (value.length < 4 || value.length > 8) {
                return 'Password must be 4-8 characters';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _changingPassword ? null : _changePassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                disabledBackgroundColor: Colors.grey.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 4,
              ),
              child: _changingPassword
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.sync_lock, color: Colors.white),
                        const SizedBox(width: 8),
                        const Text(
                          'Update Password',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changePassword() async {
    // Validate input
    final newPassword = _newPasswordController.text.trim();
    if (newPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter new password'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    if (newPassword.length < 4 || newPassword.length > 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Password must be 4-8 characters'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() {
      _changingPassword = true;
    });

    try {
      // Send command to ESP32 via backend
      await widget.onAction('change_password&new_password=$newPassword');

      if (mounted) {
        setState(() {
          _changingPassword = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Door password updated successfully'),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 3),
          ),
        );

        // Clear input field
        _newPasswordController.clear();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _changingPassword = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Error: ${e.toString()}'),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }
}
