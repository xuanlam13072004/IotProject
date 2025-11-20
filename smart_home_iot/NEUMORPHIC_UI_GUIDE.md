# Hướng dẫn Giao diện Neumorphism Smart Home

## 🎨 Tổng quan thiết kế

Giao diện mới được thiết kế theo phong cách **Neumorphism (Soft UI)** với các đặc điểm:

### Màu sắc chính
- **Background**: `#DCE5F0` (Xanh nhạt)
- **Text**: `#3E4E5E` (Xanh đen đậm)
- **Shadow Light**: `#FFFFFF` (Trắng)
- **Shadow Dark**: `#A6BCCF` (Xanh tối)

### Hiệu ứng Neumorphism
- **Nổi (Normal)**: Bóng trắng góc trên-trái, bóng tối góc dưới-phải
- **Lõm (Active)**: Đảo ngược bóng khi nhấn nút

## 📱 Cấu trúc màn hình

### 1. Status Bar (Trên cùng)
- **Cloud Icon**: Trạng thái kết nối cloud
- **WiFi Icon**: Trạng thái WiFi (sáng khi kết nối)

### 2. Sensor Row (Hàng cảm biến)
3 card hiển thị:
- **Temperature**: Nhiệt độ hiện tại (°C)
- **Humidity**: Độ ẩm (%)
- **Gas Alert**: Cảnh báo khí gas (Safe/Danger)

### 3. Control Grid (Điều khiển chính)

#### Main Gate Card
- Slider "Slide to Unlock" để mở cửa
- Kéo slider sang phải hoàn toàn để kích hoạt
- Tự động reset về vị trí ban đầu sau khi gửi lệnh

#### Automated Roof Card
3 nút điều khiển:
- **↑ Open**: Mở mái che (`open_awning`)
- **⏸ Stop**: Dừng (`stop_awning`)
- **↓ Close**: Đóng (`close_awning`)

#### Living Room Lights Card
- Nút bóng đèn lớn
- Icon sáng màu vàng khi bật
- Toggle on/off: `light_on` / `light_off`

#### Smart Fan Card
- Hiển thị trạng thái: Running/Stopped
- Nút quạt lớn
- Toggle on/off: `fan_on` / `fan_off`

### 4. Bottom Navigation
Thanh điều hướng hình viên thuốc:
- Icon Home
- Text "History"
- Icon Settings
- Text "Admin"

## 🔧 Component tái sử dụng

### NeumorphicContainer
Widget chính để tạo hiệu ứng Neumorphism:

```dart
NeumorphicContainer(
  width: 100,
  height: 100,
  isActive: false, // true = lõm, false = nổi
  borderRadius: BorderRadius.circular(20),
  padding: EdgeInsets.all(16),
  child: YourWidget(),
)
```

### NeumorphicButton
Nút bấm với hiệu ứng Neumorphism tự động:

```dart
NeumorphicButton(
  width: 70,
  height: 70,
  borderRadius: BorderRadius.circular(35),
  onPressed: () => doSomething(),
  child: Icon(Icons.lightbulb),
)
```

## 🚀 Chạy ứng dụng

```bash
cd C:\IoT_System_Project\smart_home_iot
flutter run
```

## 🎭 Vai trò người dùng

### Admin
- Tab "Điều khiển": Giao diện Neumorphism đầy đủ
- Tab "Quản lý": Quản lý tài khoản người dùng

### User
- Giao diện Neumorphism đầy đủ
- Tất cả nút và slider hoạt động

### Guest
- Giao diện Neumorphism (chế độ xem)
- Tất cả nút và slider bị vô hiệu hóa
- Vẫn hiển thị dữ liệu cảm biến

## 📡 API Actions

Các lệnh gửi đến backend:
- `open_door` - Mở cửa chính
- `open_awning` - Mở mái che
- `stop_awning` - Dừng mái che
- `close_awning` - Đóng mái che
- `light_on` - Bật đèn
- `light_off` - Tắt đèn
- `fan_on` - Bật quạt
- `fan_off` - Tắt quạt

## 🎨 Tùy chỉnh

### Thay đổi màu sắc
Chỉnh sửa trong `device_dashboard.dart`:
```dart
static const _bgColor = Color(0xFFDCE5F0);
static const _textColor = Color(0xFF3E4E5E);
```

### Thêm thiết bị mới
1. Thêm biến trạng thái trong `_DeviceDashboardState`
2. Tạo widget card mới
3. Thêm vào `_buildControlGrid()`
4. Kết nối với `widget.onAction(action)`

## 📝 Ghi chú

- Slider "Main Gate" yêu cầu kéo ít nhất 90% để kích hoạt
- Tất cả animations có duration 200ms
- Sensor data hiện đang dùng giá trị giả lập (có thể kết nối API sau)
- Bottom navigation chỉ là UI, chưa có chức năng điều hướng
