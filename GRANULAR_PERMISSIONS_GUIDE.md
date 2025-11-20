# Hướng Dẫn Hệ Thống Quyền Chi Tiết (Granular Permissions System)

## Tổng Quan

Hệ thống quyền chi tiết cho phép admin quản lý chính xác những gì mỗi user có thể làm với từng thiết bị và tính năng trong hệ thống IoT. Thay vì chỉ có vai trò admin/user/guest đơn giản, giờ đây admin có thể kiểm soát từng hành động cụ thể.

## Cấu Trúc Quyền

### 1. Thiết Bị Cửa (Door)
- **view**: Xem trạng thái cửa (mở/đóng)
- **open**: Mở cửa
- **close**: Đóng cửa

### 2. Mái Che (Awning)
- **view**: Xem trạng thái mái che
- **open**: Mở mái che
- **close**: Đóng mái che
- **setMode**: Chuyển đổi chế độ Auto/Manual

### 3. Quản Lý Báo Động (Alarm)
- **view**: Xem trạng thái báo động
- **snooze**: Quyền tổng quát tạm hoãn báo động (deprecated)
- **cancelSnooze**: Kích hoạt lại báo động sau khi tạm hoãn
- **snoozeAll**: Tạm hoãn tất cả cảm biến (lửa + gas)
- **snoozeFire**: Chỉ tạm hoãn cảm biến lửa
- **snoozeGas**: Chỉ tạm hoãn cảm biến gas

### 4. Dữ Liệu Cảm Biến (Sensors)
- **viewTemperature**: Xem nhiệt độ
- **viewHumidity**: Xem độ ẩm
- **viewGas**: Xem trạng thái khí gas
- **viewFire**: Xem cảnh báo lửa

## Kiến Trúc Backend

### Model Account (`backend_account/src/models/Account.js`)
```javascript
permissions: {
    door: { view, open, close },
    awning: { view, open, close, setMode },
    alarm: { view, snooze, cancelSnooze, snoozeAll, snoozeFire, snoozeGas },
    sensors: { viewTemperature, viewHumidity, viewGas, viewFire }
}

// Method kiểm tra quyền
hasPermission(category, action) {
    if (this.role === 'admin') return true; // Admin luôn có tất cả quyền
    return this.permissions[category]?.[action] === true;
}
```

### Middleware (`backend_account/src/middleware/checkPermission.js`)

#### checkPermission(category, action)
Middleware tĩnh kiểm tra quyền cụ thể:
```javascript
router.get('/something', authenticate, checkPermission('door', 'view'), controller);
```

#### checkActionPermission
Middleware động phân tích action từ `req.body.action` và ánh xạ tới quyền tương ứng:
```javascript
// Tự động map command → permission
'open_door' → {category: 'door', action: 'open'}
'set_snooze&sensor=fire' → {category: 'alarm', action: 'snoozeFire'}
```

#### Ánh Xạ Command → Permission
```javascript
const permissionMap = {
    'open_door': { category: 'door', action: 'open' },
    'close_door': { category: 'door', action: 'close' },
    'open_awning': { category: 'awning', action: 'open' },
    'close_awning': { category: 'awning', action: 'close' },
    'set_auto': { category: 'awning', action: 'setMode' },
    'set_manual': { category: 'awning', action: 'setMode' },
    'cancel_snooze': { category: 'alarm', action: 'cancelSnooze' }
};

// set_snooze xử lý đặc biệt theo sensor parameter
if (action.startsWith('set_snooze')) {
    const sensor = params.get('sensor') || 'all';
    return {
        category: 'alarm',
        action: sensor === 'all' ? 'snoozeAll' : 
                sensor === 'fire' ? 'snoozeFire' : 'snoozeGas'
    };
}
```

### Controller (`backend_account/src/controllers/permissionController.js`)

#### GET `/admin/users/:userId/permissions` (Admin Only)
Lấy permissions của user cụ thể để admin xem/chỉnh sửa.

#### PUT `/admin/users/:userId/permissions` (Admin Only)
Cập nhật permissions cho user:
```json
{
    "door": { "view": true, "open": true, "close": false },
    "awning": { "view": true, "open": false, "close": false, "setMode": false },
    "alarm": { "view": true, "snoozeAll": true, "snoozeFire": true, "snoozeGas": true, "cancelSnooze": false },
    "sensors": { "viewTemperature": true, "viewHumidity": true, "viewGas": true, "viewFire": true }
}
```

#### GET `/accounts/me/permissions` (User Self-Query)
User lấy permissions của chính mình để Flutter UI biết hiển thị gì.

### Routes Updated
```javascript
// controlRoutes.js
router.post(
    '/devices/:deviceId/control', 
    authenticate, 
    checkActionPermission,  // ← Thay thế requireModuleControl
    controlDevice
);
```

## Kiến Trúc Flutter

### Admin Permission Management (`screens/user_permissions_screen.dart`)

Giao diện quản lý quyền cho admin với 4 category cards:

```dart
// Mỗi category có switches cho từng action
_buildCategoryCard(
    'Thiết bị Cửa', 
    Icons.door_front_door,
    ['Xem', 'Mở', 'Đóng'],
    ['view', 'open', 'close'],
    'door'
)
```

**Workflow:**
1. Admin vào "Quản lý User"
2. Click icon khóa 🔒 bên cạnh user
3. Mở UserPermissionsScreen
4. Toggle switches cho từng quyền
5. Click "Lưu Thay Đổi" → PUT `/admin/users/:userId/permissions`

### User Dashboard Permission Loading (`screens/user_dashboard.dart`)

```dart
Map<String, dynamic> _permissions = {};
bool _permissionsLoaded = false;

Future<void> _loadPermissions() async {
    final response = await http.get(
        Uri.parse('${Config.accountBaseUrl}/accounts/me/permissions'),
        headers: {'Authorization': 'Bearer $token'}
    );
    if (response.statusCode == 200) {
        setState(() {
            _permissions = jsonDecode(response.body)['permissions'];
            _permissionsLoaded = true;
        });
    }
}

bool _hasPermission(String category, String action) {
    if (_isAdmin) return true;
    return _permissions[category]?.[action] ?? false;
}
```

### Device Dashboard Permission-Aware UI (`widgets/device_dashboard.dart`)

#### Helper Method
```dart
bool _hasPermission(String category, String action) {
    if (widget.isAdmin) return true;
    return widget.permissions[category]?[action] ?? false;
}
```

#### Door Control (Slider)
```dart
Future<void> _onGateSlideEnd() async {
    final action = doorOpen ? 'close_door' : 'open_door';
    final permissionAction = doorOpen ? 'close' : 'open';
    
    if (!_hasPermission('door', permissionAction)) {
        setState(() => _gateSlide = 0.0); // Reset slider
        return; // Không cho phép
    }
    
    // ... thực hiện action
}
```

#### Awning Controls (Buttons)
```dart
Widget _buildAwningOpenCloseButtons() {
    final canOpen = _hasPermission('awning', 'open');
    final canClose = _hasPermission('awning', 'close');
    
    return Column(
        children: [
            NeumorphicButton(
                onPressed: (widget.enabled && canOpen) 
                    ? () => widget.onAction('open_awning') 
                    : null,
                child: Text(
                    'Mở Mái Che',
                    style: TextStyle(
                        color: canOpen ? _textColor : _textColor.withOpacity(0.3)
                    )
                )
            ),
            // ... close button tương tự
        ]
    );
}
```

#### Auto Mode Toggle
```dart
Widget _buildAutoModeToggle() {
    final canSetMode = _hasPermission('awning', 'setMode');
    
    return GestureDetector(
        onTap: (widget.enabled && canSetMode) ? _toggleAutoMode : null,
        child: Opacity(
            opacity: canSetMode ? 1.0 : 0.4,
            child: /* toggle switch widget */
        )
    );
}
```

#### Alarm Sensor Dropdown
```dart
List<DropdownMenuItem<String>> _buildSensorDropdownItems() {
    final items = <DropdownMenuItem<String>>[];
    
    if (_hasPermission('alarm', 'snoozeAll')) {
        items.add(DropdownMenuItem(value: 'all', child: Text('Tất cả')));
    }
    if (_hasPermission('alarm', 'snoozeFire')) {
        items.add(DropdownMenuItem(value: 'fire', child: Text('🔥 Cảm biến Lửa')));
    }
    if (_hasPermission('alarm', 'snoozeGas')) {
        items.add(DropdownMenuItem(value: 'gas', child: Text('💨 Cảm biến Gas')));
    }
    
    if (items.isEmpty) {
        items.add(DropdownMenuItem(
            value: 'all', 
            enabled: false, 
            child: Text('Không có quyền')
        ));
    }
    
    return items;
}
```

#### Alarm Time Chips
```dart
// Chỉ hiển thị time chips nếu user có quyền cho sensor đã chọn
if (_canSnoozeSelectedSensor())
    Wrap(
        children: [
            _buildTimeChip('3 phút', 180),
            _buildTimeChip('5 phút', 300),
            // ...
        ]
    ),

// Hiển thị thông báo nếu thiếu quyền
if (!_canSnoozeSelectedSensor())
    Container(
        child: Text('Bạn không có quyền tạm hoãn ${_getSensorName(selectedSensor)}')
    ),

bool _canSnoozeSelectedSensor() {
    switch (selectedSensor) {
        case 'all': return _hasPermission('alarm', 'snoozeAll');
        case 'fire': return _hasPermission('alarm', 'snoozeFire');
        case 'gas': return _hasPermission('alarm', 'snoozeGas');
        default: return false;
    }
}
```

#### Cancel Snooze Button
```dart
if (_canCancelSnooze()) ...[
    GestureDetector(
        onTap: () => widget.onAction('cancel_snooze&sensor=$selectedSensor'),
        child: /* button UI */
    )
]

bool _canCancelSnooze() {
    return _hasPermission('alarm', 'cancelSnooze');
}
```

#### Sensor Cards
```dart
Widget _buildSensorRow() {
    final sensors = <Widget>[];
    
    if (_hasPermission('sensors', 'viewTemperature')) {
        sensors.add(_buildSensorCard(/* temperature */));
    }
    if (_hasPermission('sensors', 'viewHumidity')) {
        sensors.add(_buildSensorCard(/* humidity */));
    }
    if (_hasPermission('sensors', 'viewGas')) {
        sensors.add(_buildSensorCard(/* gas */));
    }
    
    if (sensors.isEmpty) {
        return Text('Không có quyền xem cảm biến');
    }
    
    return Row(children: sensors);
}
```

#### Control Cards Visibility
```dart
Widget _buildControlGrid() {
    return Column(
        children: [
            if (_hasPermission('door', 'view')) ...[
                _buildMainGateCard(),
                SizedBox(height: 18),
            ],
            Row(
                children: [
                    if (_hasPermission('awning', 'view'))
                        Expanded(child: _buildAutomatedRoofCard()),
                    // ...
                ]
            ),
            // ...
        ]
    );
}
```

## Use Cases Ví Dụ

### Use Case 1: User chỉ có thể mở/đóng cửa
Admin cấu hình:
```json
{
    "door": { "view": true, "open": true, "close": true },
    "awning": { "view": true, "open": false, "close": false, "setMode": false },
    "alarm": { "view": true, "snoozeAll": false, "snoozeFire": false, "snoozeGas": false, "cancelSnooze": false },
    "sensors": { "viewTemperature": true, "viewHumidity": true, "viewGas": true, "viewFire": true }
}
```

**Kết quả:**
- ✅ User thấy trạng thái cửa và slide để mở/đóng
- ✅ User thấy mái che nhưng buttons bị disable (xám mờ)
- ✅ User thấy sensor readings
- ❌ User không thấy time chips để snooze alarm
- ❌ Dropdown alarm hiển thị "Không có quyền"

### Use Case 2: User quản lý alarm nhưng không điều khiển thiết bị vật lý
```json
{
    "door": { "view": true, "open": false, "close": false },
    "awning": { "view": true, "open": false, "close": false, "setMode": false },
    "alarm": { "view": true, "snoozeAll": true, "snoozeFire": true, "snoozeGas": true, "cancelSnooze": true },
    "sensors": { "viewTemperature": true, "viewHumidity": true, "viewGas": true, "viewFire": true }
}
```

**Kết quả:**
- ✅ User thấy trạng thái cửa/mái che nhưng không thể điều khiển
- ✅ User có thể snooze alarm (all/fire/gas)
- ✅ User có thể cancel snooze
- ✅ Dropdown hiển thị đầy đủ 3 options

### Use Case 3: User chỉ tạm hoãn cảm biến lửa
```json
{
    "alarm": { "view": true, "snoozeAll": false, "snoozeFire": true, "snoozeGas": false, "cancelSnooze": false }
}
```

**Kết quả:**
- ✅ Dropdown chỉ hiển thị "🔥 Cảm biến Lửa"
- ✅ Time chips chỉ hoạt động khi chọn Fire
- ❌ Không có option "Tất cả thiết bị"
- ❌ Không có option "💨 Cảm biến Khí Gas"
- ❌ Không thấy nút Cancel (thiếu cancelSnooze permission)

## Backend Permission Enforcement

### Control Routes
```javascript
// Mọi control command đều được kiểm tra permission
POST /devices/:deviceId/control
Headers: { Authorization: Bearer <token> }
Body: { action: "open_door" }

// Middleware chain:
1. authenticate → verify JWT, attach req.user
2. checkActionPermission → parse action, check permission
3. controlDevice → execute command if allowed
```

### Response Codes
- **200**: Command executed successfully
- **403**: Permission denied
  ```json
  { "error": "Permission denied: You don't have permission to perform open on door" }
  ```
- **401**: Not authenticated
- **400**: Invalid action format

## Testing Checklist

### Backend Tests
- [x] Admin có tất cả permissions (bypass checks)
- [x] User với door.open=false bị từ chối open_door
- [x] User với alarm.snoozeFire=true có thể set_snooze&sensor=fire
- [x] User với alarm.snoozeAll=false bị từ chối set_snooze&sensor=all
- [x] Permission middleware ánh xạ đúng command → permission
- [x] PUT /admin/users/:userId/permissions cập nhật thành công
- [x] GET /accounts/me/permissions trả về đúng permissions

### Flutter Tests
- [x] Admin UI hiển thị tất cả switches
- [x] Admin có thể toggle permissions và lưu
- [x] User dashboard load permissions từ backend
- [x] Door slider disable khi thiếu quyền open/close
- [x] Awning buttons grayed out khi thiếu quyền
- [x] Auto mode toggle disable khi thiếu setMode
- [x] Alarm dropdown chỉ hiển thị sensors có quyền
- [x] Time chips ẩn khi thiếu quyền snooze
- [x] Sensor cards ẩn khi thiếu quyền view
- [x] Control cards (door/awning) ẩn khi thiếu view permission

### End-to-End Tests
1. Admin tạo user mới → mặc định có view permissions
2. Admin cấp quyền open_door → User thấy slider active
3. User slide cửa → Backend accept command
4. Admin thu hồi open_door → User thấy slider inactive
5. User slide cửa → Slider reset về 0, command không gửi
6. Admin cấp snoozeAll → Dropdown hiển thị "Tất cả"
7. User click time chip → Backend tạm hoãn thành công
8. Admin thu hồi snoozeAll → Dropdown hiển thị "Không có quyền"
9. User click time chip → Nothing happens (chips hidden)

## Migration Notes

### Breaking Changes
- ❌ `modules` array deprecated (kept for backward compatibility)
- ✅ All new code uses `permissions` object
- ✅ `requireModuleControl` middleware replaced by `checkActionPermission`

### Backward Compatibility
- Old accounts without `permissions` field → default permissions applied
- Admin role always bypasses permission checks
- Existing control endpoints unchanged (just middleware swap)

## Security Considerations

1. **Defense in Depth**: Permissions checked at both backend (authoritative) and frontend (UX)
2. **Admin Privilege**: Role='admin' bypasses all permission checks
3. **Default Deny**: Missing permission = denied (not allowed by default)
4. **Atomic Checks**: Each action checked individually, no grouped permissions
5. **Audit Trail**: Consider logging permission changes (future enhancement)

## Future Enhancements

1. **Permission Groups/Templates**: Pre-defined sets (e.g., "Security Manager", "Maintenance Staff")
2. **Time-Based Permissions**: Grant temporary access (e.g., snooze only during night shift)
3. **Device-Specific Permissions**: Permissions per device instance (not just category)
4. **Permission Inheritance**: Hierarchical permissions (e.g., control implies view)
5. **Audit Logs**: Track who changed what permission when
6. **Permission Request Workflow**: Users request permissions, admin approves

---

**Tác giả**: IoT Smart Home Development Team  
**Ngày tạo**: 2024  
**Phiên bản**: 1.0
