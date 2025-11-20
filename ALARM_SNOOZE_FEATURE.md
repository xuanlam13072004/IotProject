# Tính năng Quản lý Tạm hoãn Báo động (Alarm Snooze) - NÂNG CẤP V2

## Tổng quan
Hệ thống quản lý tạm hoãn báo động **CHI TIẾT THEO TỪNG CẢM BIẾN**, cho phép người dùng:
- ✅ Tắt báo động **TẤT CẢ** thiết bị (Lửa + Gas)
- ✅ Tắt **CHỈ** cảm biến Lửa (Gas vẫn báo động)
- ✅ Tắt **CHỈ** cảm biến Khí Gas (Lửa vẫn báo động)
- ✅ Tắt **TỪNG** cảm biến riêng lẻ hoặc kết hợp

Trạng thái tạm hoãn được quản lý bởi server (MongoDB) và đồng bộ với ESP32 thông qua lệnh điều khiển.

## Kiến trúc V2 (Nâng cấp)

### 1. Database Schema (MongoDB - Device Model)
```javascript
{
  deviceId: String,
  name: String,
  secretKey: String,
  isActive: Boolean,
  mutedSensors: [String],  // NEW V2: ['all'], ['fire'], ['gas'], hoặc ['fire', 'gas']
  muteEndsAt: Date         // Thời điểm kết thúc tạm hoãn
}
```

**Thay đổi từ V1:**
- ❌ `isMuted: Boolean` (chỉ on/off toàn bộ)
- ✅ `mutedSensors: [String]` (chi tiết từng sensor)

### 2. Backend API (backend_account)

#### Endpoint: POST /api/devices/:deviceId/control
**Xử lý lệnh set_snooze với sensor parameter:**
```javascript
// Request body:
{
  "action": "set_snooze",
  "seconds": 300,   // Số giây tạm hoãn
  "sensor": "fire"  // NEW V2: 'all', 'fire', hoặc 'gas'
}

// Backend logic:
1. Parse sensor parameter
2. Build mutedSensors array:
   - sensor='all' → ['all']
   - sensor='fire' → add 'fire' vào array hiện tại
   - sensor='gas' → add 'gas' vào array hiện tại
3. Tính muteEndsAt = now + seconds
4. Cập nhật Device: { mutedSensors, muteEndsAt }
5. Tạo PendingCommand với action object { name, seconds, sensor }
6. Trả về 202 Accepted
```

**Xử lý lệnh cancel_snooze với sensor parameter:**
```javascript
// Request body:
{
  "action": "cancel_snooze",
  "sensor": "fire"  // Sensor cần kích hoạt lại
}

// Backend logic:
1. Parse sensor parameter
2. Xóa sensor khỏi mutedSensors array:
   - sensor='all' → mutedSensors = []
   - sensor='fire' → remove 'fire' và 'all' khỏi array
   - sensor='gas' → remove 'gas' và 'all' khỏi array
3. Update muteEndsAt = null nếu array rỗng
4. Tạo PendingCommand
5. Trả về 202 Accepted
```

#### Endpoint: GET /api/devices/:deviceId/data/latest
**Response mở rộng V2:**
```json
{
  "temperature": 25.6,
  "humidity": 70,
  "gasValue": 150,
  "fireAlert": false,
  "awningOpen": false,
  "doorOpen": false,
  "raining": false,
  "awningAutoMode": true,
  "mutedSensors": ["fire"],  // NEW V2: Array thay vì isMuted boolean
  "muteEndsAt": "2024-01-15T10:35:00Z",
  "timestamp": "2024-01-15T10:30:00Z"
}
```

### 3. Flutter App

#### UI Components V2
**Card: "Quản lý Báo động"** (trong device_dashboard.dart)

- **Dropdown Chọn Thiết bị:** ⭐ NEW V2
  - "Tất cả thiết bị" (sensor='all')
  - "🔥 Cảm biến Lửa" (sensor='fire')
  - "💨 Cảm biến Khí Gas" (sensor='gas')

- **Muted Sensors Status Badge:** ⭐ NEW V2
  - Hiển thị khi có sensor bị mute: "Đang tắt: Lửa, Gas"
  - Màu xanh dương với icon volume_off

- **Time Chips:** 5 nút để chọn thời gian tạm hoãn
  - Click → Gửi `set_snooze&seconds=X&sensor=<selectedSensor>`
  - 3 phút, 5 phút, 10 phút, 30 phút, 60 phút

- **Countdown Timer:** Hiển thị khi `mutedSensors.isNotEmpty`
  - Format: "Tạm hoãn: Xm Ys"
  - Tự động cập nhật mỗi giây

- **Admin Cancel Button:** Chỉ hiển thị khi `isAdmin = true` và có sensor bị mute
  - Text: "Kích hoạt lại <sensor_name> (Admin)"
  - Gửi `cancel_snooze&sensor=<selectedSensor>`

#### State Management
```dart
List<String> mutedSensors = [];  // ['all'], ['fire'], ['gas'], or ['fire', 'gas']
DateTime? muteEndsAt;
String selectedSensor = 'all';   // Dropdown selection
```

### 4. ESP32 Firmware V2

#### Global Variables
```cpp
volatile bool muteAll = false;   // true nếu tắt tất cả
volatile bool muteFire = false;  // true nếu tắt cảm biến lửa
volatile bool muteGas = false;   // true nếu tắt cảm biến gas
volatile unsigned long muteEndTime = 0;
```

#### Command Handler - set_snooze
```cpp
void handleCommand(String rawAction, const String &param) {
  // Parse JSON action object
  DynamicJsonDocument doc(256);
  deserializeJson(doc, rawAction);
  
  String cmd = doc["name"].as<String>();
  long seconds = doc["seconds"].as<long>();
  String sensor = doc["sensor"].as<String>();
  
  if (cmd == "set_snooze") {
    muteEndTime = millis() + (seconds * 1000);
    
    if (sensor == "all") {
      muteAll = true;
      muteFire = false;
      muteGas = false;
    }
    else if (sensor == "fire") {
      muteFire = true;
      muteAll = false;
    }
    else if (sensor == "gas") {
      muteGas = true;
      muteAll = false;
    }
  }
}
```

#### Buzzer Logic V2
```cpp
bool shouldMuteFire = muteAll || muteFire;
bool shouldMuteGas = muteAll || muteGas;

if (gasAlert && fireAlert) {
  // Cả 2 cảnh báo - chỉ kêu nếu ít nhất 1 không bị mute
  if (!shouldMuteFire || !shouldMuteGas) {
    digitalWrite(BUZZER_PIN, HIGH);
  }
}
else if (fireAlert && !shouldMuteFire) {
  // Chỉ Lửa và không bị mute - kêu nhanh
  // Blink 200ms
}
else if (gasAlert && !shouldMuteGas) {
  // Chỉ Gas và không bị mute - kêu chậm
  // Blink 500ms
}
else {
  digitalWrite(BUZZER_PIN, LOW);
}
```

## Luồng hoạt động chi tiết

### Set Snooze (User)
```
User clicks "5 phút" 
  → Flutter: onAction('set_snooze&seconds=300')
  → _sendCommand() parse → { action: "set_snooze", seconds: "300" }
  → POST /devices/esp32_1/control
  → Backend: Device.update({ isMuted: true, muteEndsAt: Date.now()+300000 })
  → PendingCommand.create({ action: "set_snooze", ... })
  → 202 Accepted
  → Notification: "Đã tạm hoãn báo động"
  → ESP32 poll /commands → nhận "set_snooze" → log + tắt buzzer
  → ESP32 sendAck(commandId, true)
  → Flutter poll /data/latest → nhận { isMuted: true, muteEndsAt: "..." }
  → UI hiển thị countdown "Tạm hoãn: 4m 59s"
```

### Cancel Snooze (Admin)
```
Admin clicks "Kích hoạt lại Báo động"
  → Flutter: onAction('cancel_snooze')
  → POST /devices/esp32_1/control { action: "cancel_snooze" }
  → Backend: Device.update({ isMuted: false, muteEndsAt: null })
  → PendingCommand.create({ action: "cancel_snooze", ... })
  → 202 Accepted
  → Notification: "Đã kích hoạt lại báo động"
  → ESP32 poll /commands → nhận "cancel_snooze" → log + bật lại buzzer
  → ESP32 sendAck(commandId, true)
  → Flutter poll /data/latest → nhận { isMuted: false, muteEndsAt: null }
  → UI ẩn countdown, hiển thị time chips
```

## Cấu hình

### Backend Environment
```env
# backend_account/.env
MONGODB_URI=mongodb+srv://...
JWT_SECRET=your_jwt_secret
PORT=4000
ADMIN_USERNAME=xuanlam123
ADMIN_PASSWORD=admin12345
```

### Flutter Dependencies
```yaml
dependencies:
  http: ^1.1.0
  shared_preferences: ^2.2.2
  jwt_decode: ^0.3.1
  another_flushbar: ^1.12.30
```

### ESP32 Configuration
```cpp
#define BASE_URL_ACCOUNT "http://192.168.31.100:4000/api/devices/esp32_1"
#define DEVICE_SECRET "my_secret_key_123"
```

## Testing Checklist

### Backend
- [ ] Device.save() với isMuted/muteEndsAt
- [ ] POST /control với action=set_snooze&seconds=300
- [ ] POST /control với action=cancel_snooze
- [ ] GET /data/latest trả về isMuted và muteEndsAt
- [ ] PendingCommand được tạo cho cả 2 lệnh

### Flutter
- [ ] Time chips hiển thị đúng (3m, 5m, 10m, 30m, 60m)
- [ ] Click chip → gửi đúng seconds parameter
- [ ] Countdown timer hiển thị khi isMuted=true
- [ ] Countdown cập nhật mỗi giây
- [ ] Admin button chỉ hiển thị với role=admin
- [ ] Admin button chỉ hiển thị khi isMuted=true
- [ ] Notification hiển thị message thân thiện

### ESP32
- [ ] pollCommands nhận được set_snooze
- [ ] pollCommands nhận được cancel_snooze
- [ ] handleCommand xử lý 2 lệnh mới
- [ ] sendAck gửi thành công

## Mở rộng tương lai

### 1. Auto-expire trên Backend
Thêm cron job/scheduled task để tự động clear `isMuted` khi `muteEndsAt` đã qua:
```javascript
setInterval(async () => {
  await Device.updateMany(
    { isMuted: true, muteEndsAt: { $lt: new Date() } },
    { isMuted: false, muteEndsAt: null }
  );
}, 60000); // Check mỗi phút
```

### 2. Persistent Mute State trên ESP32
Lưu `isMuted` vào EEPROM/SPIFFS để giữ trạng thái sau khi reboot:
```cpp
bool alarmMuted = false;
DateTime muteEndTime;

void setup() {
  // Load from SPIFFS
  alarmMuted = loadMuteState();
}

void handleCommand(String cmd) {
  if (cmd == "set_snooze") {
    alarmMuted = true;
    muteEndTime = rtc.now() + TimeSpan(seconds);
    saveMuteState(alarmMuted, muteEndTime);
  }
}
```

### 3. History/Audit Log
Lưu lịch sử tạm hoãn báo động:
```javascript
// Model: AlarmMuteLog
{
  deviceId: String,
  action: String, // 'set_snooze' | 'cancel_snooze'
  duration: Number, // seconds (nếu set_snooze)
  requestedBy: ObjectId,
  requestedByUsername: String,
  timestamp: Date
}
```

### 4. Custom Snooze Duration
Thêm input field để user nhập số phút tùy chỉnh:
```dart
TextFormField(
  decoration: InputDecoration(labelText: 'Số phút tùy chỉnh'),
  onFieldSubmitted: (value) {
    int minutes = int.tryParse(value) ?? 5;
    onAction('set_snooze&seconds=${minutes * 60}');
  },
)
```

## Troubleshooting

### Backend không cập nhật isMuted
- Kiểm tra Device.findOneAndUpdate có `{ new: true }`
- Verify MongoDB connection string
- Check server logs cho errors

### Flutter không hiển thị countdown
- Kiểm tra muteEndsAt parse từ JSON (DateTime.parse)
- Verify _countdownTimer đang chạy
- Check mounted state trước setState

### ESP32 không nhận lệnh
- Verify pollCommands interval (3s)
- Check HMAC signature trong headers
- Monitor Serial output cho errors

### Countdown không cập nhật
- Kiểm tra Timer.periodic 1s trong initState
- Verify dispose() cancel timer
- Check if (mounted && isMuted) trong timer callback

## File Changes Summary

### Backend
- `backend_account/src/models/Device.js` - Added isMuted, muteEndsAt fields
- `backend_account/src/controllers/controlController.js` - Handle set_snooze, cancel_snooze
- `backend_account/src/controllers/deviceController.js` - Include isMuted, muteEndsAt in /data/latest

### Flutter
- `smart_home_iot/lib/widgets/device_dashboard.dart` - Alarm management card, countdown timer
- `smart_home_iot/lib/screens/user_dashboard.dart` - Parse action parameters, isAdmin state

### ESP32
- `ESP32/ESP32/ESP32.ino` - Handle set_snooze, cancel_snooze commands

---

**Version:** 1.0  
**Date:** 2024-01-15  
**Author:** GitHub Copilot  
**Status:** ✅ Implemented
