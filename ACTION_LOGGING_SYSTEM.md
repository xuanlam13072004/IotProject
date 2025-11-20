# Hệ Thống Ghi Lịch Sử (Action Logging)

## Tổng Quan

Hệ thống ghi lại **MỌI HÀNH ĐỘNG QUAN TRỌNG** vào database MongoDB để:
- Theo dõi ai đã làm gì, khi nào, ở đâu
- Phục vụ trang "Lịch Sử" trong app
- Audit trail cho bảo mật
- Phân tích hành vi người dùng

## Database Schema

### Collection: `actionlogs`

```javascript
{
  actionType: String,          // Loại hành động
  deviceId: String,            // Thiết bị nào bị tác động
  performedBy: {
    userId: ObjectId,          // ID user (nếu qua app)
    username: String,          // Tên user
    source: String             // 'app' | 'keypad' | 'system' | 'remote' | 'schedule'
  },
  details: Object,             // Chi tiết cụ thể (parameters, v.v.)
  result: {
    status: String,            // 'success' | 'failed' | 'pending'
    message: String,           // Mô tả kết quả
    errorCode: String          // Mã lỗi nếu failed
  },
  ipAddress: String,           // IP address (nếu qua app)
  metadata: Object,            // Dữ liệu bổ sung
  createdAt: Date,             // Timestamp tự động
  updatedAt: Date              // Timestamp tự động
}
```

## Các Loại Action Type

| Action Type | Mô Tả | Source |
|------------|-------|--------|
| `change_password` | Thay đổi mật khẩu cửa | app, keypad |
| `control_device` | Điều khiển thiết bị (chung) | app |
| `set_snooze` | Tạm hoãn báo động | app |
| `cancel_snooze` | Hủy tạm hoãn | app |
| `door_open` | Mở cửa | keypad, app |
| `door_close` | Đóng cửa | system |
| `alarm_trigger` | Báo động kích hoạt | system |
| `system_mode_change` | Chuyển chế độ (Online/Offline) | keypad |
| `other` | Khác | varies |

## Luồng Ghi Log

### 1. Hành Động Từ App (Remote)

```
User (App) → Backend controlController
           → Tạo PendingCommand
           → **TẠO ACTIONLOG (status: pending)**
           → ESP32 poll command
           → ESP32 thực thi
           → ESP32 gửi ACK
           → **CẬP NHẬT ACTIONLOG (status: success/failed)**
```

**Backend Code:**
```javascript
// controlController.js - controlDevice()
const actionLog = new ActionLog({
    actionType: action,
    deviceId,
    performedBy: {
        userId: req.account?.id,
        username: req.account?.username,
        source: 'app'
    },
    details: { action, parameters: body, commandId: cmd._id.toString() },
    result: { status: 'pending' },
    ipAddress: req.ip
});
await actionLog.save();
```

### 2. Hành Động Từ Keypad (Local)

```
User (Keypad) → ESP32 xử lý trực tiếp
              → ESP32 gửi log lên backend
              → **TẠO ACTIONLOG (status: success)**
```

**ESP32 Code:**
```cpp
// Gọi sau khi đổi password thành công
sendActionLog("change_password", "keypad", "Password changed via keypad", true);
```

**ESP32 Function:**
```cpp
void sendActionLog(String actionType, String source, String details, bool success) {
    HTTPClient http;
    String url = String(BASE_URL_ACCOUNT) + "/log";
    
    StaticJsonDocument<512> doc;
    doc["actionType"] = actionType;
    
    JsonObject performedBy = doc.createNestedObject("performedBy");
    performedBy["username"] = "local_user";
    performedBy["source"] = source;
    
    JsonObject detailsObj = doc.createNestedObject("details");
    detailsObj["description"] = details;
    detailsObj["timestamp"] = rtc.now().timestamp();
    
    JsonObject resultObj = doc.createNestedObject("result");
    resultObj["status"] = success ? "success" : "failed";
    
    String body;
    serializeJson(doc, body);
    String signature = hmacSha256(body, DEVICE_SECRET);
    
    http.begin(url);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("x-signature", signature);
    
    int code = http.POST(body);
    http.end();
}
```

### 3. Hành Động Từ System (Auto)

ESP32 có thể tự động ghi log cho các sự kiện:
- Báo động kích hoạt
- Cửa đóng tự động
- Chuyển đổi chế độ

## API Endpoints

### 1. Lấy Danh Sách Log

```http
GET /api/action-logs?deviceId=esp32_1&actionType=change_password&limit=50&page=1
Authorization: Bearer <token>
```

**Query Parameters:**
- `deviceId`: Lọc theo thiết bị
- `actionType`: Lọc theo loại hành động
- `userId`: Lọc theo user ID
- `username`: Tìm kiếm theo username
- `source`: Lọc theo nguồn (app, keypad, system)
- `startDate`: Từ ngày (ISO 8601)
- `endDate`: Đến ngày (ISO 8601)
- `limit`: Số record mỗi trang (mặc định 50)
- `page`: Trang số (mặc định 1)

**Response:**
```json
{
  "logs": [
    {
      "_id": "...",
      "actionType": "change_password",
      "deviceId": "esp32_1",
      "performedBy": {
        "userId": "...",
        "username": "admin",
        "source": "keypad"
      },
      "details": {
        "description": "Password changed via keypad",
        "timestamp": 1700000000
      },
      "result": {
        "status": "success",
        "message": "Action completed successfully"
      },
      "createdAt": "2025-11-19T10:30:00.000Z",
      "updatedAt": "2025-11-19T10:30:00.000Z"
    }
  ],
  "pagination": {
    "page": 1,
    "limit": 50,
    "total": 150,
    "totalPages": 3
  }
}
```

### 2. Lấy Thống Kê

```http
GET /api/action-logs/stats?deviceId=esp32_1&startDate=2025-11-01&endDate=2025-11-30
Authorization: Bearer <token>
```

**Response:**
```json
{
  "stats": {
    "byActionType": [
      { "_id": "control_device", "count": 45 },
      { "_id": "change_password", "count": 3 }
    ],
    "bySource": [
      { "_id": "app", "count": 40 },
      { "_id": "keypad", "count": 8 }
    ],
    "byStatus": [
      { "_id": "success", "count": 47 },
      { "_id": "failed", "count": 1 }
    ],
    "totalActions": [{ "total": 48 }]
  },
  "period": {
    "startDate": "2025-11-01",
    "endDate": "2025-11-30"
  }
}
```

### 3. Lấy Chi Tiết 1 Log

```http
GET /api/action-logs/:id
Authorization: Bearer <token>
```

### 4. Xóa Log Cũ (Admin Only)

```http
DELETE /api/action-logs
Authorization: Bearer <token>
Content-Type: application/json

{
  "beforeDate": "2025-01-01T00:00:00.000Z"
}
```

### 5. Log Action Từ ESP32

```http
POST /api/devices/esp32_1/log
Content-Type: application/json
x-signature: <HMAC-SHA256>

{
  "actionType": "change_password",
  "performedBy": {
    "username": "local_user",
    "source": "keypad"
  },
  "details": {
    "description": "Password changed via keypad",
    "timestamp": 1700000000
  },
  "result": {
    "status": "success",
    "message": "Action completed successfully"
  }
}
```

## Tự Động Xóa Log Cũ

Logs được tự động xóa sau **180 ngày (6 tháng)** nhờ TTL index:

```javascript
actionLogSchema.index({ createdAt: 1 }, { expireAfterSeconds: 15552000 });
```

## Ví Dụ Sử Dụng

### 1. Xem Lịch Sử Thay Đổi Password

```javascript
// Flutter App
final response = await http.get(
  Uri.parse('$baseUrl/api/action-logs?actionType=change_password&deviceId=esp32_1'),
  headers: {'Authorization': 'Bearer $token'}
);
```

### 2. Xem Tất Cả Hành Động Của 1 User

```javascript
const logs = await fetch('/api/action-logs?username=admin&limit=100');
```

### 3. Thống Kê Hành Động Trong Tháng

```javascript
const stats = await fetch('/api/action-logs/stats?startDate=2025-11-01&endDate=2025-11-30');
```

## Bảo Mật

1. **Authentication Required**: Tất cả endpoints cần JWT token (trừ ESP32 endpoint dùng HMAC)
2. **Device Signature**: ESP32 phải ký request bằng HMAC-SHA256
3. **Admin Only**: Endpoint DELETE chỉ admin mới dùng được
4. **IP Logging**: Tự động ghi IP address cho audit
5. **TTL Index**: Tự động xóa log cũ để bảo vệ privacy

## Tích Hợp Vào Flutter App

### Screen: History Page

```dart
class HistoryScreen extends StatefulWidget {
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ActionLog> logs = [];
  
  @override
  void initState() {
    super.initState();
    _loadLogs();
  }
  
  Future<void> _loadLogs() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/action-logs?limit=50'),
      headers: {'Authorization': 'Bearer $token'}
    );
    
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      setState(() {
        logs = (data['logs'] as List)
            .map((e) => ActionLog.fromJson(e))
            .toList();
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final log = logs[index];
        return ListTile(
          leading: _getIconForAction(log.actionType),
          title: Text(_getActionTitle(log.actionType)),
          subtitle: Text(
            '${log.performedBy.username} • ${_formatDate(log.createdAt)}'
          ),
          trailing: _getStatusBadge(log.result.status),
        );
      }
    );
  }
}
```

## Monitoring & Debugging

### Kiểm Tra Log Trong MongoDB

```bash
# Connect to MongoDB
mongosh mongodb://localhost:27017/iot_accounts

# Xem 10 log mới nhất
db.actionlogs.find().sort({createdAt: -1}).limit(10).pretty()

# Đếm log theo actionType
db.actionlogs.aggregate([
  { $group: { _id: "$actionType", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])

# Xem log của 1 user
db.actionlogs.find({"performedBy.username": "admin"})
```

### Log Trong Serial Monitor (ESP32)

```
[LOG] Đã ghi log: change_password - Password changed via keypad
[LOG] Lỗi gửi log. Mã: 500
```

### Log Trong Backend Console

```
Device esp32_1 logged action: change_password via keypad
Persisted control request id=... user=admin -> device=esp32_1 action= set_snooze
```

## Checklist Triển Khai

- [x] Tạo model ActionLog
- [x] Thêm logging vào controlController
- [x] Thêm endpoint logDeviceAction
- [x] Thêm hàm sendActionLog() trong ESP32
- [x] Gọi sendActionLog() khi đổi password
- [x] Tạo API endpoints để query logs
- [x] Tạo API stats endpoint
- [x] Thêm routes vào server.js
- [ ] Tạo History Screen trong Flutter app
- [ ] Test end-to-end logging flow
- [ ] Setup monitoring/alerting cho failed actions

## Mở Rộng Tương Lai

1. **Real-time Notifications**: WebSocket để push log realtime
2. **Export CSV/PDF**: Xuất báo cáo lịch sử
3. **Advanced Filters**: Tìm kiếm full-text, range filters
4. **Dashboard Charts**: Biểu đồ thống kê trực quan
5. **Anomaly Detection**: AI phát hiện hành vi bất thường
6. **Retention Policy**: Cấu hình TTL theo từng action type
