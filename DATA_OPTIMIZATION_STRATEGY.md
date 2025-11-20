# Tối Ưu Lưu Trữ Dữ Liệu IoT - Data Storage Optimization

## ❌ VẤN ĐỀ TRƯỚC KHI TỐI ƯU

### **Hệ Thống Cũ (Lãng phí cực độ)**

```cpp
const unsigned long sendInterval = 1000;  // Gửi mỗi 1 GIÂY!
```

**Hậu quả:**
- 📊 **86,400 records/ngày** cho 1 thiết bị
- 💾 **2.6 triệu records/tháng**
- 🗄️ **31 triệu records/năm**
- 💰 MongoDB phình to → Query chậm → Chi phí cao
- 🔥 Phần lớn data **TRÙNG LẶP HOÀN TOÀN**

**Ví dụ:**
```
10:00:00 → temp: 25.5°C, hum: 60%
10:00:01 → temp: 25.5°C, hum: 60%  ← TRÙNG!
10:00:02 → temp: 25.5°C, hum: 60%  ← TRÙNG!
10:00:03 → temp: 25.5°C, hum: 60%  ← TRÙNG!
...
10:00:59 → temp: 25.5°C, hum: 60%  ← TRÙNG!
```

---

## ✅ GIẢI PHÁP TỐI ƯU: CHIẾN LƯỢC LAI (HYBRID)

### **1. Event-Driven + Scheduled + Significant Change**

```cpp
// Cấu hình mới
const unsigned long sendInterval = 900000;  // 15 phút = 900,000ms

#define TEMP_CHANGE_THRESHOLD 1.0    // 1°C
#define HUM_CHANGE_THRESHOLD 5.0     // 5%
#define GAS_CHANGE_THRESHOLD 50      // 50 đơn vị
```

### **3 Trigger để Gửi Data:**

#### **A. Critical Events (Gửi NGAY LẬP TỨC)**

Các sự kiện quan trọng:
- 🔥 **Báo cháy kích hoạt/tắt** → Gửi ngay (0ms delay)
- ⚠️ **Gas vượt ngưỡng** → Gửi ngay
- 🚪 **Cửa mở/đóng** → Gửi ngay
- 🌧️ **Mưa bắt đầu/kết thúc** → Gửi ngay
- 🏠 **Mái che đóng/mở** → Gửi ngay
- ⚙️ **Auto mode thay đổi** → Gửi ngay

```cpp
bool criticalEvent = false;
if (fire != lastSentFireAlert)           criticalEvent = true;
if ((gas > gasThreshold) != lastSentGasAlert) criticalEvent = true;
if (door != lastSentDoorOpen)            criticalEvent = true;
if (raining != lastSentRaining)          criticalEvent = true;
if (awning != lastSentAwningOpen)        criticalEvent = true;
if (autoMode != lastSentAwningAutoMode)  criticalEvent = true;
```

#### **B. Significant Changes (Gửi sau 1 PHÚT)**

Thay đổi đáng kể của cảm biến:
- 🌡️ **Nhiệt độ thay đổi ≥ 1°C**
- 💧 **Độ ẩm thay đổi ≥ 5%**
- 💨 **Gas thay đổi ≥ 50 đơn vị**

```cpp
bool significantChange = false;
if (fabs(temp - lastSentTemp) >= 1.0)   significantChange = true;
if (fabs(hum - lastSentHum) >= 5.0)     significantChange = true;
if (abs(gas - lastSentGas) >= 50)       significantChange = true;

// Gửi sau 1 phút để tránh spam
if (significantChange && (now - lastSend >= 60000))
    sendData();
```

#### **C. Scheduled (Gửi ĐỊNH KỲ 15 PHÚT)**

Nếu không có gì thay đổi:
- ⏰ Vẫn gửi **1 lần/15 phút** để đảm bảo có data
- 📊 Đủ để vẽ biểu đồ xu hướng (4 điểm/giờ)
- 🔍 Giúp phát hiện lỗi kết nối

```cpp
if (now - lastSend >= 900000)  // 15 phút
    sendData();
```

---

## 📊 SO SÁNH TRƯỚC/SAU

### **Scenario 1: Ngày Bình Thường (Không có sự cố)**

| Thời gian | Hệ Thống Cũ | Hệ Thống Mới | Lý do |
|-----------|-------------|--------------|-------|
| 08:00 | ✅ Gửi | ✅ Gửi | Định kỳ |
| 08:01-08:14 | ✅ 840 records | ❌ Không gửi | Không thay đổi |
| 08:15 | ✅ Gửi | ✅ Gửi | Định kỳ 15 phút |
| 08:16-08:29 | ✅ 840 records | ❌ Không gửi | Không thay đổi |
| 08:30 | ✅ Gửi | ✅ Gửi | Định kỳ 15 phút |
| **Tổng 1h** | **3,600 records** | **4 records** | **Giảm 99.9%** |

### **Scenario 2: Có Sự Kiện Quan Trọng**

| Thời gian | Sự kiện | Hệ Thống Cũ | Hệ Thống Mới |
|-----------|---------|-------------|--------------|
| 10:00:00 | Cửa mở | ✅ Gửi (may mắn đúng lúc) | ✅ Gửi ngay lập tức |
| 10:00:01-10:00:05 | - | ✅ 5 records trùng | ❌ Không gửi |
| 10:00:06 | Cửa đóng | ✅ Gửi (may mắn) | ✅ Gửi ngay lập tức |
| 10:00:07-10:00:10 | - | ✅ 4 records trùng | ❌ Không gửi |
| **Hiệu quả** | 10 records (9 thừa) | **2 records (đúng)** | **Chính xác 100%** |

### **Scenario 3: Nhiệt Độ Tăng Dần**

| Thời gian | Nhiệt độ | Hệ Thống Cũ | Hệ Thống Mới | Lý do |
|-----------|----------|-------------|--------------|-------|
| 14:00 | 28.0°C | ✅ Gửi | ✅ Gửi | Định kỳ |
| 14:05 | 28.3°C | ✅ 300 records | ❌ Không gửi | Thay đổi < 1°C |
| 14:10 | 28.6°C | ✅ 300 records | ❌ Không gửi | Thay đổi < 1°C |
| 14:15 | 28.9°C | ✅ 300 records | ❌ Không gửi | Thay đổi < 1°C |
| 14:20 | 29.2°C | ✅ 300 records | ✅ Gửi (sau 1 phút) | Thay đổi ≥ 1°C |
| **Tổng** | **1,200 records** | **2 records** | **Giảm 99.8%** |

---

## 📈 HIỆU QUẢ TỐI ƯU

### **Giảm Lượng Data Lưu Trữ**

| Thời gian | Hệ Thống Cũ | Hệ Thống Mới | Tiết kiệm |
|-----------|-------------|--------------|-----------|
| **1 giờ** | 3,600 records | ~4-10 records | **99.7%** |
| **1 ngày** | 86,400 records | ~96-240 records | **99.7%** |
| **1 tháng** | 2.6M records | ~2,880-7,200 records | **99.7%** |
| **1 năm** | 31M records | ~35K-88K records | **99.7%** |

### **Tiết Kiệm Chi Phí**

Giả sử mỗi record = 500 bytes:

| Thời gian | Dung lượng Cũ | Dung lượng Mới | Tiết kiệm |
|-----------|---------------|----------------|-----------|
| 1 tháng | **1.3 GB** | **3.6 MB** | 99.7% |
| 1 năm | **15.5 GB** | **44 MB** | 99.7% |

**Chi phí MongoDB Atlas (ước tính):**
- Cũ: $50-100/tháng (M10 cluster)
- Mới: $0-10/tháng (M0 free tier đủ)

---

## 🔧 CẤU HÌNH BACKEND TỐI ƯU

### **1. Sử Dụng 2 Collections**

#### **Collection A: `devicestates` (Chỉ trạng thái mới nhất)**

```javascript
// Model: DeviceState.js (1 record/device)
{
  deviceId: "esp32_1",
  state: {
    temperature: 25.5,
    humidity: 60,
    gas: 100,
    fireAlert: false,
    doorOpen: false
  },
  updatedAt: "2025-11-19T10:30:00Z"
}
```

**Khi ESP32 gửi data:**
```javascript
// Upsert (update hoặc insert)
await DeviceState.findOneAndUpdate(
  { deviceId: 'esp32_1' },
  { 
    state: req.body,
    updatedAt: new Date()
  },
  { upsert: true, new: true }
);
```

→ **Luôn chỉ có 1 record** cho mỗi thiết bị (App đọc realtime)

#### **Collection B: `devicedatahistory` (Lịch sử với TTL)**

```javascript
// Model: DeviceDataHistory.js
{
  deviceId: "esp32_1",
  data: {...},
  eventType: "critical" | "significant" | "scheduled",
  createdAt: "2025-11-19T10:30:00Z"
}

// TTL Index - tự động xóa sau 30 ngày
deviceDataHistorySchema.index(
  { createdAt: 1 }, 
  { expireAfterSeconds: 2592000 }  // 30 ngày
);
```

→ Lưu lịch sử để vẽ chart, tự động cleanup

### **2. API Endpoints**

```javascript
// GET /api/devices/:id/state - Lấy trạng thái mới nhất (fast)
app.get('/api/devices/:id/state', async (req, res) => {
  const state = await DeviceState.findOne({ deviceId: req.params.id });
  res.json(state);
});

// GET /api/devices/:id/history?from=...&to=... - Lấy lịch sử
app.get('/api/devices/:id/history', async (req, res) => {
  const { from, to } = req.query;
  const history = await DeviceDataHistory.find({
    deviceId: req.params.id,
    createdAt: { $gte: new Date(from), $lte: new Date(to) }
  }).sort({ createdAt: -1 }).limit(1000);
  res.json(history);
});
```

---

## 📱 TÍCH HỢP VỚI FLUTTER APP

### **Realtime Dashboard**

```dart
// Chỉ fetch latest state (1 record)
final response = await http.get('$baseUrl/api/devices/esp32_1/state');
final state = json.decode(response.body);

// Hiển thị trên dashboard
Temperature: ${state['state']['temperature']}°C
Humidity: ${state['state']['humidity']}%
```

### **History Chart (24h)**

```dart
// Fetch history với range
final now = DateTime.now();
final yesterday = now.subtract(Duration(days: 1));
final response = await http.get(
  '$baseUrl/api/devices/esp32_1/history?from=${yesterday.toIso8601String()}&to=${now.toIso8601String()}'
);

// Khoảng 96-240 điểm data cho 24h → Đủ để vẽ line chart mượt
```

---

## 🎯 KẾT QUẢ CUỐI CÙNG

### **Trước Tối Ưu:**
- ❌ 86,400 records/ngày
- ❌ 99% data trùng lặp
- ❌ MongoDB phình to
- ❌ Query chậm
- ❌ Chi phí cao

### **Sau Tối Ưu:**
- ✅ ~100-200 records/ngày
- ✅ Mọi data đều có ý nghĩa
- ✅ Database nhỏ gọn
- ✅ Query cực nhanh
- ✅ Tiết kiệm 99.7% chi phí

### **Vẫn Đảm Bảo:**
- ✅ Realtime response cho critical events
- ✅ Đủ data points để vẽ charts
- ✅ Không miss bất kỳ sự kiện nào
- ✅ App UX không thay đổi

---

## 🚀 CÁCH TRIỂN KHAI

### **Bước 1: Update ESP32 Firmware**

Đã làm xong:
- ✅ Tăng sendInterval lên 15 phút
- ✅ Thêm ngưỡng thay đổi
- ✅ Logic detect critical events
- ✅ Logic detect significant changes

### **Bước 2: Tạo Models Mới (Backend)**

```javascript
// 1. DeviceState.js (latest state only)
// 2. DeviceDataHistory.js (history with TTL)
```

### **Bước 3: Update Controller**

```javascript
// Khi nhận data từ ESP32:
// - Upsert vào DeviceState
// - Insert vào DeviceDataHistory
// - Trả về success
```

### **Bước 4: Migrate Data Cũ (Optional)**

```javascript
// Script chuyển data cũ sang history (giữ 30 ngày gần nhất)
// Xóa data cũ hơn 30 ngày
```

### **Bước 5: Update Flutter App**

```dart
// Đổi endpoint từ /data sang /state cho realtime
// Endpoint /history cho charts
```

---

## 📊 MONITORING

### **Metrics Cần Theo Dõi:**

1. **Data Rate:**
   - Records/ngày: Mục tiêu ~100-200
   - Critical events/ngày: Nên < 50
   - Significant changes/ngày: Nên < 100

2. **Database Size:**
   - DeviceState: ~1-10 KB (fixed)
   - DeviceDataHistory: ~50-100 MB/năm

3. **Response Time:**
   - GET /state: < 50ms
   - GET /history: < 200ms

### **Alerts:**

```javascript
// Cảnh báo nếu data rate quá cao
if (recordsPerHour > 20) {
  alert("Data rate cao bất thường - kiểm tra logic ESP32");
}

// Cảnh báo nếu lâu không nhận data
if (now - lastDataTime > 20 * 60 * 1000) {
  alert("Không nhận data từ ESP32 > 20 phút");
}
```

---

## 🎓 TÓM TẮT

**Strategy:**
1. Critical events → Gửi NGAY
2. Significant changes → Gửi sau 1 PHÚT
3. Scheduled → Gửi mỗi 15 PHÚT

**Result:**
- Giảm 99.7% dung lượng
- Vẫn đảm bảo realtime
- Không mất data quan trọng
- Chi phí gần như bằng 0

**Trade-off:**
- ❌ Mất chi tiết giây-đến-giây (không cần thiết)
- ✅ Giữ tất cả events quan trọng
- ✅ Đủ resolution cho charts
- ✅ Database maintainable

**Recommendation:**
- Implement ngay! ROI cực cao
- Monitor trong 1 tuần
- Điều chỉnh thresholds nếu cần
