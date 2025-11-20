#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include "RTClib.h"
#include "DHT.h"
#include <Keypad_I2C.h>
#include <Keypad.h>
#include <ESP32Servo.h>

#include <WiFi.h>
#include <HTTPClient.h>
#include "mbedtls/md.h"

#include <AccelStepper.h>
#include <SD.h>
#include <SPI.h>
#include <ArduinoJson.h>
#include <Preferences.h>

// ================= KHAI BÁO CẤU HÌNH (CONFIG) =================
const char *WIFI_SSID = "Aces of Spades";
const char *WIFI_PASS = "1234567899";

// Mật khẩu Admin cố định (dùng để cấp quyền đổi pass cửa)
const String ADMIN_PASSWORD = "1307";
Preferences preferences;

// --- CẤU HÌNH LOCAL (MẠNG LAN) ---
const char *BASE_URL_ACCOUNT = "http://192.168.31.100:4000/api/devices/esp32_1";
const char *SERVER_URL = "http://192.168.31.100:5000/api/devices/esp32_1/data";

const char *DEVICE_SECRET = "my_secret_key_123";
#define DEVICE_ID "esp32_1"

unsigned long lastSend = 0;
// Gửi tối đa 15 phút/lần (nếu không có thay đổi đáng kể)
const unsigned long sendInterval = 900000; // 15 phút = 900,000ms

// Ngưỡng để coi như "có thay đổi đáng kể"
#define TEMP_CHANGE_THRESHOLD 1.0 // Thay đổi 1°C trở lên
#define HUM_CHANGE_THRESHOLD 5.0  // Thay đổi 5% trở lên
#define GAS_CHANGE_THRESHOLD 50   // Thay đổi 50 đơn vị trở lên

#define POLL_INTERVAL 3000
unsigned long lastPollTime = 0;

// ================= HÀM BĂM BẢO MẬT (HMAC SHA256) =================
String hmacSha256(const String &data, const String &key)
{
    byte hmacResult[32];
    mbedtls_md_context_t ctx;
    mbedtls_md_type_t md_type = MBEDTLS_MD_SHA256;
    mbedtls_md_init(&ctx);
    mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(md_type), 1);
    mbedtls_md_hmac_starts(&ctx, (const unsigned char *)key.c_str(), key.length());
    mbedtls_md_hmac_update(&ctx, (const unsigned char *)data.c_str(), data.length());
    mbedtls_md_hmac_finish(&ctx, hmacResult);
    mbedtls_md_free(&ctx);

    String signature = "";
    for (int i = 0; i < 32; i++)
    {
        char str[3];
        sprintf(str, "%02x", (int)hmacResult[i]);
        signature += str;
    }
    return signature;
}

// ================= KHAI BÁO CHÂN (PINS) =================
#define DHTPIN 13
#define DHTTYPE DHT11
#define MQ2_PIN 34
#define FLAME_PIN 35
#define BUZZER_PIN 26
#define BUTTON_PIN 14

#define WATER_SENSOR_PIN 32
#define STEPPER_IN1 16
#define STEPPER_IN2 17
#define STEPPER_IN3 18
#define STEPPER_IN4 19
#define AWNING_BUTTON_PIN 15

#define SD_CS_PIN 5
#define SD_MOSI 23
#define SD_MISO 25
#define SD_SCK 33
#define SD_BACKUP_DIR "/data"
#define SD_MAX_USAGE_MB 7000UL

#define I2CADDR 0x20
#define SERVO_PIN 27

// ================= KHAI BÁO HẰNG SỐ KHÁC =================
const int stepsPerRevolution = 2048;
const int gasThreshold = 1000;

// ================= KHỞI TẠO ĐỐI TƯỢNG PHẦN CỨNG =================
LiquidCrystal_I2C lcd(0x27, 20, 4);
RTC_DS3231 rtc;
DHT dht(DHTPIN, DHTTYPE);
Servo doorServo;
AccelStepper awningStepper(AccelStepper::FULL4WIRE, STEPPER_IN1, STEPPER_IN3, STEPPER_IN2, STEPPER_IN4);

// Cấu hình Keypad
const byte ROWS = 4, COLS = 4;
char keys[ROWS][COLS] = {
    {'1', '2', '3', 'A'},
    {'4', '5', '6', 'B'},
    {'7', '8', '9', 'C'},
    {'*', '0', '#', 'D'}};
byte rowPins[ROWS] = {0, 1, 2, 3};
byte colPins[COLS] = {4, 5, 6, 7};
Keypad_I2C keypad(makeKeymap(keys), rowPins, colPins, ROWS, COLS, I2CADDR, 1, &Wire);

// ================= BIẾN TRẠNG THÁI TOÀN CỤC (GLOBALS) =================
volatile float currentTemp = NAN;
volatile float currentHum = NAN;
volatile int currentGasValue = 0;
volatile int currentFlameValue = HIGH;
volatile int currentRainValue = HIGH;
volatile bool isRaining = false;

volatile bool gasAlert = false;
volatile bool fireAlert = false;
volatile bool buzzerMuted = false;
unsigned long lastBeep = 0;
unsigned long lastBlink = 0;
volatile bool blinkState = false;

volatile bool awningOpen = false;
volatile bool awningMoving = false;
volatile int awningDirection = 1;
volatile bool doorOpen = false;
volatile bool awningAutoMode = true;

// --- LOGIC MUTE V4.9 ---
volatile bool muteAll = false;
volatile bool muteFire = false;
volatile bool muteGas = false;
volatile unsigned long muteEndTime = 0;

// --- LOGIC OFFLINE MODE (MỚI V5.0) ---
bool isOfflineMode = false;       // Trạng thái Offline (mặc định False - Có mạng)
bool isInputtingPassword = false; // Cờ báo đang nhập pass (để LCD ko vẽ đè)
bool justSwitchedMode = false;    // Cờ báo vừa chuyển mode (trigger reconnect)
String offlinePassword = "1307";  // Mật khẩu khẩn cấp

// Biến kiểm tra logic gửi
float lastSentTemp = -999.0;
float lastSentHum = -999.0;
int lastSentGas = 0;
bool lastSentAwningOpen = false;
bool lastSentFireAlert = false;
bool lastSentGasAlert = false;
bool lastSentDoorOpen = false;
bool lastSentRaining = false;
bool lastSentAwningAutoMode = true;

// Mật khẩu cửa động (đọc từ Preferences)
String doorPassword = "1234"; // Giá trị mặc định
String enteredPassword = "";
bool isUnlockMode = false;
bool passwordCorrect = false;

// Handles Tasks
TaskHandle_t hTaskSensorLCD = NULL;
TaskHandle_t hTaskKeypadDoor = NULL;
TaskHandle_t hTaskAwning = NULL;
TaskHandle_t hTaskSendServer = NULL;

static bool sdReady = false;
volatile bool coDuLieuMoiCanGui = false;

// ================= LOGIC GỬI LOG (ĐƯA LÊN TRƯỚC ĐỂ TRÁNH LỖI) =================
// Hàm gửi log hành động lên server
// username: "admin_physical" (admin thao tác trực tiếp), "unknown_physical" (người dùng vật lý)
void sendActionLog(String actionType, String source, String details, bool success, String username = "unknown_physical")
{
    // SỬA LỖI: Dùng WiFi.status() thay vì biến wifiConnected không tồn tại
    if (WiFi.status() != WL_CONNECTED)
    {
        Serial.println("[LOG] Offline - không gửi log");
        return;
    }

    HTTPClient http;
    String url = String(BASE_URL_ACCOUNT) + "/log";

    // Tạo JSON payload
    StaticJsonDocument<512> doc;
    doc["actionType"] = actionType;

    JsonObject performedBy = doc.createNestedObject("performedBy");
    performedBy["username"] = username;
    performedBy["source"] = source;

    JsonObject detailsObj = doc.createNestedObject("details");
    detailsObj["description"] = details;
    detailsObj["timestamp"] = rtc.now().timestamp();

    JsonObject resultObj = doc.createNestedObject("result");
    resultObj["status"] = success ? "success" : "failed";
    resultObj["message"] = success ? "Action completed successfully" : "Action failed";

    String body;
    serializeJson(doc, body);

    // Tạo signature
    String signature = hmacSha256(body, DEVICE_SECRET);

    http.begin(url);
    http.setTimeout(5000);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("x-signature", signature);

    int code = http.POST(body);
    if (code >= 200 && code < 300)
    {
        Serial.println("[LOG] Đã ghi log: " + actionType + " - " + details);
    }
    else
    {
        Serial.println("[LOG] Lỗi gửi log. Mã: " + String(code));
    }
    http.end();
}

// ================= QUẢN LÝ MẬT KHẨU ĐỘNG (PREFERENCES) =================
void loadDoorPassword()
{
    preferences.begin("door-config", false);
    doorPassword = preferences.getString("password", "1234");
    preferences.end();
    Serial.println("[PASS] Đã load mật khẩu cửa từ NVS: ****");
}

void saveDoorPassword(String newPassword)
{
    preferences.begin("door-config", false);
    preferences.putString("password", newPassword);
    preferences.end();
    doorPassword = newPassword;
    Serial.println("[PASS] Đã lưu mật khẩu cửa mới vào NVS: ****");

    // Gửi log lên server - chỉ admin có ADMIN_PASSWORD nên ghi admin_physical
    sendActionLog("change_password", "keypad", "Password changed via keypad (requires ADMIN_PASSWORD)", true, "admin_physical");
}

// ================= HỆ THỐNG QUẢN LÝ THẺ SD =================
String pointerFile = "/sync_pointer.txt";
String currentSyncFile = "";
long currentSyncPos = 0;

void ensureSDReady()
{
    if (sdReady)
        return;
    if (SD.begin(SD_CS_PIN, SPI, 8000000, "/sd", 5))
    {
        sdReady = true;
        if (!SD.exists(SD_BACKUP_DIR))
            SD.mkdir(SD_BACKUP_DIR);
        Serial.println("✅ (Core 0) SD đã sẵn sàng");
    }
    else
    {
        Serial.println("⚠️ (Core 0) Khởi tạo SD thất bại");
    }
}

uint64_t getUsedSpaceMB()
{
    if (!sdReady)
        return 0;
    uint64_t used = SD.usedBytes();
    return used / (1024 * 1024);
}

void deleteOldestBackup()
{
    ensureSDReady();
    File dir = SD.open(SD_BACKUP_DIR);
    if (!dir)
        return;
    String oldestName = "";
    time_t oldestTime = UINT32_MAX;
    while (true)
    {
        File f = dir.openNextFile();
        if (!f)
            break;
        if (f.isDirectory())
        {
            f.close();
            continue;
        }
        if (pointerFile.equals(f.name()))
        {
            f.close();
            continue;
        }
        time_t t = f.getLastWrite();
        if (t < oldestTime)
        {
            oldestTime = t;
            oldestName = String(f.name());
        }
        f.close();
    }
    dir.close();
    if (oldestName.length())
    {
        Serial.println("🗑️ Đang xóa file cũ nhất: " + oldestName);
        SD.remove(oldestName.c_str());
    }
}

void readSyncPointer()
{
    ensureSDReady();
    currentSyncFile = "";
    currentSyncPos = 0;
    if (!SD.exists(pointerFile))
    {
        Serial.println("Không tìm thấy file pointer. Sẽ đồng bộ từ đầu.");
        return;
    }
    File f = SD.open(pointerFile, FILE_READ);
    if (f)
    {
        String line = f.readStringUntil('\n');
        f.close();
        int comma = line.indexOf(',');
        if (comma > 0)
        {
            currentSyncFile = line.substring(0, comma);
            currentSyncPos = line.substring(comma + 1).toInt();
        }
    }
    Serial.printf("Đã đọc Pointer: File=%s, Vị trí=%ld\n", currentSyncFile.c_str(), currentSyncPos);
}

void updateSyncPointer(String filename, long newPosition)
{
    ensureSDReady();
    File f = SD.open(pointerFile, FILE_WRITE);
    if (f)
    {
        String line = filename + "," + String(newPosition);
        f.println(line);
        f.close();
        currentSyncFile = filename;
        currentSyncPos = newPosition;
    }
    else
    {
        Serial.println("⚠️ Cập nhật file pointer thất bại!");
    }
}

void logDataToSD(const String &payload)
{
    ensureSDReady();
    if (!sdReady)
        return;
    DateTime now = rtc.now();
    char fname[48];
    snprintf(fname, sizeof(fname), SD_BACKUP_DIR "/%04d-%02d-%02d.jsonl", now.year(), now.month(), now.day());
    File f = SD.open(fname, FILE_APPEND);
    if (!f)
    {
        Serial.println("⚠️ Mở file SD để ghi tiếp thất bại");
        return;
    }
    f.println(payload);
    f.close();
    Serial.println("💾 Đã ghi log vào SD: " + String(fname));
    coDuLieuMoiCanGui = true;
    if (getUsedSpaceMB() > SD_MAX_USAGE_MB)
    {
        Serial.println("⚠️ SD gần đầy. Đang xóa file cũ nhất...");
        deleteOldestBackup();
    }
}

void resendUnsyncedFromSD()
{
    ensureSDReady();
    if (!sdReady)
        return;
    File dir = SD.open(SD_BACKUP_DIR);
    if (!dir)
        return;
    bool allFilesSynced = true;
    while (true)
    {
        File file = dir.openNextFile();
        if (!file)
            break;
        if (file.isDirectory())
        {
            file.close();
            continue;
        }
        String path = file.name();
        if (!path.endsWith(".jsonl"))
        {
            file.close();
            continue;
        }
        if (path < currentSyncFile)
        {
            file.close();
            continue;
        }
        long startPos = 0;
        if (path == currentSyncFile)
        {
            if (file.size() <= currentSyncPos)
            {
                file.close();
                continue;
            }
            startPos = currentSyncPos;
            Serial.println("Tiếp tục file: " + path + " từ vị trí " + String(startPos));
        }
        else
        {
            startPos = 0;
            Serial.println("Bắt đầu file mới: " + path);
        }
        allFilesSynced = false;
        if (!file.seek(startPos))
        {
            Serial.println("⚠️ Không thể nhảy tới vị trí " + String(startPos));
            file.close();
            continue;
        }
        bool failed = false;
        bool dataSent = false;
        while (file.available())
        {
            String payload = file.readStringUntil('\n');
            payload.trim();
            if (payload.length() == 0)
                continue;
            String sig = hmacSha256(payload, DEVICE_SECRET);
            HTTPClient http;
            http.begin(SERVER_URL);
            http.setTimeout(3000);
            http.addHeader("Content-Type", "application/json");
            http.addHeader("X-Signature", sig);
            int code = http.POST(payload);
            http.end();
            if (code < 200 || code >= 300)
            {
                Serial.printf("⚠️ Gửi lại thất bại, mã lỗi=%d, dừng lại.\n", code);
                updateSyncPointer(path, startPos);
                failed = true;
                break;
            }
            startPos = file.position();
            dataSent = true;
        }
        file.close();
        if (dataSent)
        {
            updateSyncPointer(path, startPos);
        }
        if (failed)
        {
            allFilesSynced = false;
            break;
        }
    }
    dir.close();
    if (allFilesSynced)
    {
        coDuLieuMoiCanGui = false;
    }
}

// ================= CÁC HÀM XỬ LÝ LỆNH =================
void handleCommand(String rawAction, const String &param)
{
    String cmd = rawAction;
    String sensor = "all";
    long durationSeconds = 0;

    // Logic parse mới (V4.9)
    if (rawAction.startsWith("{"))
    {
        DynamicJsonDocument doc(256);
        DeserializationError error = deserializeJson(doc, rawAction);
        if (!error)
        {
            cmd = doc["name"].as<String>();
            if (doc.containsKey("seconds"))
                durationSeconds = doc["seconds"].as<long>();
            if (doc.containsKey("sensor"))
                sensor = doc["sensor"].as<String>();
        }
    }
    else
    {
        cmd = rawAction;
        if (cmd == "set_snooze")
            durationSeconds = param.toInt();
    }

    Serial.println("[CMD] Lệnh thực thi: " + cmd);

    if (cmd == "open_door")
    {
        if (!doorOpen)
        {
            doorServo.write(90);
            doorOpen = true;
            Serial.println("[EXEC] -> Đã mở cửa");
            sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Opened door", true);
        }
    }
    else if (cmd == "close_door")
    {
        if (doorOpen)
        {
            doorServo.write(0);
            doorOpen = false;
            Serial.println("[EXEC] -> Đã đóng cửa");
            sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Closed door", true);
        }
    }
    else if (cmd == "open_awning")
    {
        if (!awningOpen && !awningMoving)
        {
            awningDirection = 1;
            long target = awningStepper.currentPosition() + (long)awningDirection * stepsPerRevolution;
            awningStepper.moveTo(target);
            awningMoving = true;
            Serial.println("[EXEC] -> Đang mở mái che...");
            sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Opening awning", true);
        }
    }
    else if (cmd == "close_awning")
    {
        if (awningOpen && !awningMoving)
        {
            awningDirection = -1;
            long target = awningStepper.currentPosition() + (long)awningDirection * stepsPerRevolution;
            awningStepper.moveTo(target);
            awningMoving = true;
            Serial.println("[EXEC] -> Đang đóng mái che...");
            sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Closing awning", true);
        }
    }
    else if (cmd == "set_auto")
    {
        awningAutoMode = true;
        Serial.println("[EXEC] -> Đã chuyển sang chế độ AUTO");
        sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Set awning to AUTO mode", true);
    }
    else if (cmd == "set_manual")
    {
        awningAutoMode = false;
        Serial.println("[EXEC] -> Đã chuyển sang chế độ MANUAL");
        sendActionLog("control_device", param.isEmpty() ? "app" : "keypad", "Set awning to MANUAL mode", true);
    }
    // --- LOGIC SNOOZE V4.9 ---
    else if (cmd == "set_snooze")
    {
        if (durationSeconds > 0)
        {
            muteEndTime = millis() + (durationSeconds * 1000);
            if (sensor == "all")
            {
                muteAll = true;
                muteFire = false;
                muteGas = false;
                buzzerMuted = true;
                Serial.printf("[EXEC] -> Đã tạm hoãn TẤT CẢ báo động %ld s.\n", durationSeconds);
                sendActionLog("set_snooze", param.isEmpty() ? "app" : "keypad", "Snoozed ALL alarms for " + String(durationSeconds) + "s", true);
            }
            else if (sensor == "fire")
            {
                muteFire = true;
                muteAll = false;
                Serial.printf("[EXEC] -> Đã tạm hoãn báo động LỬA %ld s.\n", durationSeconds);
                sendActionLog("set_snooze", param.isEmpty() ? "app" : "keypad", "Snoozed FIRE alarm for " + String(durationSeconds) + "s", true);
            }
            else if (sensor == "gas")
            {
                muteGas = true;
                muteAll = false;
                Serial.printf("[EXEC] -> Đã tạm hoãn báo động GAS %ld s.\n", durationSeconds);
                sendActionLog("set_snooze", param.isEmpty() ? "app" : "keypad", "Snoozed GAS alarm for " + String(durationSeconds) + "s", true);
            }
        }
        else
        {
            Serial.println("[ERR] -> set_snooze: Tham số không hợp lệ");
        }
    }
    else if (cmd == "cancel_snooze")
    {
        if (sensor == "all")
        {
            muteAll = false;
            muteFire = false;
            muteGas = false;
            muteEndTime = 0;
            buzzerMuted = false;
            Serial.println("[EXEC] -> Kích hoạt lại TẤT CẢ báo động!");
            sendActionLog("cancel_snooze", param.isEmpty() ? "app" : "keypad", "Reactivated ALL alarms", true);
        }
        else if (sensor == "fire")
        {
            muteFire = false;
            Serial.println("[EXEC] -> Kích hoạt lại báo động LỬA!");
            sendActionLog("cancel_snooze", param.isEmpty() ? "app" : "keypad", "Reactivated FIRE alarm", true);
        }
        else if (sensor == "gas")
        {
            muteGas = false;
            Serial.println("[EXEC] -> Kích hoạt lại báo động GAS!");
            sendActionLog("cancel_snooze", param.isEmpty() ? "app" : "keypad", "Reactivated GAS alarm", true);
        }
        if (!muteAll && !muteFire && !muteGas)
        {
            muteEndTime = 0;
            buzzerMuted = false;
        }
        digitalWrite(BUZZER_PIN, LOW);
    }
    else if (cmd == "change_password")
    {
        if (rawAction.startsWith("{"))
        {
            DynamicJsonDocument doc(256);
            DeserializationError error = deserializeJson(doc, rawAction);
            if (!error && doc.containsKey("new_password"))
            {
                String newPass = doc["new_password"].as<String>();
                if (newPass.length() >= 4 && newPass.length() <= 8)
                {
                    saveDoorPassword(newPass);
                    Serial.println("[EXEC] -> Đã đổi mật khẩu cửa từ xa!");
                    sendActionLog("change_password", "app", "Password changed remotely", true);
                }
                else
                {
                    Serial.println("[ERR] -> Mật khẩu phải từ 4-8 ký tự!");
                }
            }
            else
            {
                Serial.println("[ERR] -> Thiếu tham số new_password!");
            }
        }
        else
        {
            Serial.println("[ERR] -> change_password cần JSON format!");
        }
    }
    else if (cmd == "reboot")
    {
        Serial.println("[EXEC] -> Khởi động lại...");
        delay(1000);
        ESP.restart();
    }
    else
    {
        Serial.println("[ERR] -> Lệnh không xác định: " + cmd);
    }
}

void sendAck(String commandId, bool success)
{
    HTTPClient http;
    String url = String(BASE_URL_ACCOUNT) + "/commands/" + commandId + "/ack";
    StaticJsonDocument<128> doc;
    doc["status"] = success ? "done" : "failed";
    String body;
    serializeJson(doc, body);
    String signature = hmacSha256(body, DEVICE_SECRET);
    http.begin(url);
    http.setTimeout(3000);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("x-signature", signature);
    int code = http.POST(body);
    if (code >= 200 && code < 300)
    {
        Serial.println("[ACK] Đã xác nhận lệnh " + commandId);
    }
    else
    {
        Serial.println("[ACK] Lỗi gửi xác nhận. Mã: " + String(code));
    }
    http.end();
}

void pollCommands()
{
    HTTPClient http;
    String url = String(BASE_URL_ACCOUNT) + "/commands";
    String payload = "{}";
    String signature = hmacSha256(payload, DEVICE_SECRET);
    http.begin(url);
    http.setTimeout(3000);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("x-signature", signature);
    int code = http.GET();
    if (code == 200)
    {
        String response = http.getString();
        DynamicJsonDocument doc(2048);
        DeserializationError error = deserializeJson(doc, response);
        if (!error)
        {
            JsonArray arr = doc["commands"];
            if (arr.size() > 0)
            {
                Serial.println("[POLL] Phát hiện " + String(arr.size()) + " lệnh mới!");
                for (JsonObject cmd : arr)
                {
                    String cmdId = "";
                    if (cmd.containsKey("commandId") && !cmd["commandId"].isNull())
                        cmdId = cmd["commandId"].as<String>();
                    else if (cmd.containsKey("_id") && !cmd["_id"].isNull())
                        cmdId = cmd["_id"].as<String>();
                    else if (cmd.containsKey("id") && !cmd["id"].isNull())
                        cmdId = cmd["id"].as<String>();

                    if (cmdId == "" || cmdId == "null")
                    {
                        Serial.println("[ERR] ID không hợp lệ.");
                        continue;
                    }

                    String action = "";
                    String param = "";
                    if (cmd["action"].is<String>())
                    {
                        action = cmd["action"].as<String>();
                        handleCommand(action, "");
                    }
                    else if (cmd["action"].is<JsonObject>())
                    {
                        String actionJson;
                        serializeJson(cmd["action"], actionJson);
                        handleCommand(actionJson, "");
                    }
                    sendAck(cmdId, true);
                }
            }
        }
        else
        {
            Serial.println("[POLL] Lỗi cấu trúc JSON");
        }
    }
    else
    {
        if (code != 200)
            Serial.printf("[POLL] Mã lỗi HTTP: %d\n", code);
    }
    http.end();
}

// ================= KHỞI TẠO PHẦN CỨNG =================
void setupHardwareBase()
{
    Serial.begin(115200);
    Wire.begin(21, 22);

    lcd.init();
    lcd.noCursor();
    lcd.noBlink();
    lcd.backlight();

    dht.begin();
    keypad.begin();

    doorServo.attach(SERVO_PIN);
    doorServo.write(0);

    pinMode(BUZZER_PIN, OUTPUT);
    digitalWrite(BUZZER_PIN, LOW);
    pinMode(FLAME_PIN, INPUT);
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    pinMode(WATER_SENSOR_PIN, INPUT);
    pinMode(AWNING_BUTTON_PIN, INPUT_PULLUP);

    awningStepper.setAcceleration(400.0);
    awningStepper.setMaxSpeed(800.0);

    SPI.begin(SD_SCK, SD_MISO, SD_MOSI);
    Serial.println("Đã khởi động SPI bus.");
}

void readSensorsOnce()
{
    float h = dht.readHumidity();
    float t = dht.readTemperature();
    int gas = analogRead(MQ2_PIN);
    int flame = digitalRead(FLAME_PIN);
    int rain = digitalRead(WATER_SENSOR_PIN);

    if (!isnan(t))
        currentTemp = t;
    if (!isnan(h))
        currentHum = h;
    currentGasValue = gas;
    currentFlameValue = flame;
    currentRainValue = rain;
    isRaining = (rain == LOW);
    gasAlert = (gas > gasThreshold);
    fireAlert = (flame == LOW);
}

// ================= TASKS =================
void TaskSensorLCD(void *pvParameters)
{
    (void)pvParameters;
    const TickType_t delayMs = pdMS_TO_TICKS(500);
    for (;;)
    {
        // --- LOGIC TẠM DỪNG LCD KHI NHẬP PASS (V5.0) ---
        if (isInputtingPassword)
        {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }

        float h = dht.readHumidity();
        float t = dht.readTemperature();
        int gasValue = analogRead(MQ2_PIN);
        int flameValue = digitalRead(FLAME_PIN);
        int rainValue = digitalRead(WATER_SENSOR_PIN);

        if (!isnan(t))
            currentTemp = t;
        if (!isnan(h))
            currentHum = h;
        currentGasValue = gasValue;
        currentFlameValue = flameValue;
        currentRainValue = rainValue;
        isRaining = (rainValue == LOW);
        gasAlert = (gasValue > gasThreshold);
        fireAlert = (flameValue == LOW);

        // --- LOGIC MUTE V4.9 + Nút Vật Lý ---
        if (digitalRead(BUTTON_PIN) == LOW)
        {
            vTaskDelay(pdMS_TO_TICKS(50));
            if (digitalRead(BUTTON_PIN) == LOW)
            {
                muteAll = true;
                muteFire = false;
                muteGas = false;
                muteEndTime = millis() + 30000;
                digitalWrite(BUZZER_PIN, LOW);
                Serial.println("Nút nhấn: Tắt TẤT CẢ báo động 30s");
                while (digitalRead(BUTTON_PIN) == LOW)
                    vTaskDelay(pdMS_TO_TICKS(10));
            }
        }
        if ((muteAll || muteFire || muteGas) && millis() > muteEndTime)
        {
            muteAll = false;
            muteFire = false;
            muteGas = false;
            buzzerMuted = false;
            Serial.println("Hết giờ tạm hoãn, kích hoạt lại còi.");
        }

        if (!isUnlockMode)
        {
            bool anyAlert = gasAlert || fireAlert;
            if (anyAlert)
            {
                if (millis() - lastBlink > 500)
                {
                    blinkState = !blinkState;
                    lastBlink = millis();
                }
                lcd.setCursor(0, 0);
                if (blinkState)
                {
                    if (gasAlert && fireAlert)
                        lcd.print("!!! LUA & GAS !!!   ");
                    else if (fireAlert)
                        lcd.print("!!! PHAT HIEN LUA !!!");
                    else
                        lcd.print("!!! CANH BAO GAS !!! ");
                }
                else
                {
                    lcd.setCursor(0, 0);
                    lcd.print("                     ");
                }
            }
            else
            {
                DateTime now = rtc.now();
                char buf0[21];
                snprintf(buf0, sizeof(buf0), "%02d:%02d:%02d %02d/%02d/%04d",
                         now.hour(), now.minute(), now.second(),
                         now.day(), now.month(), now.year());
                lcd.setCursor(0, 0);
                lcd.print(buf0);
            }

            lcd.setCursor(0, 1);
            if (isnan(currentTemp))
                lcd.print("Loi nhiet do        ");
            else
            {
                char buf1[21];
                snprintf(buf1, sizeof(buf1), "Nhiet do: %.1f C    ", currentTemp);
                lcd.print(buf1);
            }

            lcd.setCursor(0, 2);
            if (isnan(currentHum))
                lcd.print("Loi do am           ");
            else
            {
                char buf2[21];
                snprintf(buf2, sizeof(buf2), "Do am: %.0f %%         ", currentHum);
                lcd.print(buf2);
            }

            // --- LOGIC HIỂN THỊ TRẠNG THÁI MỚI ---
            lcd.setCursor(0, 3);
            char buf3[21];
            // Hiển thị trạng thái rõ ràng: OFFLINE/ONLINE + AUTO/MANUAL
            snprintf(buf3, sizeof(buf3), "Gas:%d %s %s",
                     currentGasValue,
                     isOfflineMode ? "OFFL" : (WiFi.status() == WL_CONNECTED ? "ONLN" : "WAIT"),
                     awningAutoMode ? "AUTO" : "MANU");
            lcd.print(buf3);
        }

        // --- LOGIC CÒI V4.9 ---
        bool shouldMuteFire = muteAll || muteFire;
        bool shouldMuteGas = muteAll || muteGas;
        unsigned long nowMs = millis();

        if (gasAlert && fireAlert)
        {
            if (!shouldMuteFire || !shouldMuteGas)
                digitalWrite(BUZZER_PIN, HIGH);
            else
                digitalWrite(BUZZER_PIN, LOW);
        }
        else if (fireAlert && !shouldMuteFire)
        {
            if (nowMs - lastBeep > 200)
            {
                lastBeep = nowMs;
                digitalWrite(BUZZER_PIN, !digitalRead(BUZZER_PIN));
            }
        }
        else if (gasAlert && !shouldMuteGas)
        {
            if (nowMs - lastBeep > 500)
            {
                lastBeep = nowMs;
                digitalWrite(BUZZER_PIN, !digitalRead(BUZZER_PIN));
            }
        }
        else
        {
            digitalWrite(BUZZER_PIN, LOW);
        }
        vTaskDelay(delayMs);
    }
}

void TaskKeypadDoor(void *pvParameters)
{
    (void)pvParameters;
    const TickType_t delayMs = pdMS_TO_TICKS(30);
    for (;;)
    {
        char key = keypad.getKey();
        if (key)
        {

            if (key == 'A')
            {
                isInputtingPassword = true;
                lcd.clear();
                lcd.print("CHE DO HIEN TAI:");
                lcd.setCursor(0, 1);
                if (isOfflineMode)
                    lcd.print(">> OFFLINE <<");
                else
                    lcd.print(">> ONLINE <<");
                lcd.setCursor(0, 2);
                lcd.print("Nhan # de chuyen");
                lcd.setCursor(0, 3);
                lcd.print("Nhan * de huy");
                vTaskDelay(pdMS_TO_TICKS(3000));

                lcd.clear();
                lcd.print("NHAP PASS:");
                lcd.setCursor(0, 1);

                String tempPass = "";
                while (true)
                {
                    char k = keypad.getKey();
                    if (k)
                    {
                        if (k == '#')
                        {
                            if (tempPass == offlinePassword)
                            {
                                // Xác nhận lần 2 trước khi chuyển
                                lcd.clear();
                                lcd.print("XAC NHAN CHUYEN?");
                                lcd.setCursor(0, 1);
                                if (!isOfflineMode)
                                    lcd.print("-> OFFLINE MODE");
                                else
                                    lcd.print("-> ONLINE MODE");
                                lcd.setCursor(0, 2);
                                lcd.print("Nhan # de OK");
                                lcd.setCursor(0, 3);
                                lcd.print("Nhan * de huy");

                                // Đợi xác nhận
                                unsigned long confirmStart = millis();
                                bool confirmed = false;
                                while (millis() - confirmStart < 10000)
                                {
                                    char ck = keypad.getKey();
                                    if (ck == '#')
                                    {
                                        confirmed = true;
                                        break;
                                    }
                                    else if (ck == '*')
                                    {
                                        lcd.clear();
                                        lcd.print("DA HUY BO!");
                                        vTaskDelay(pdMS_TO_TICKS(1500));
                                        break;
                                    }
                                    vTaskDelay(pdMS_TO_TICKS(50));
                                }

                                if (confirmed)
                                {
                                    isOfflineMode = !isOfflineMode;
                                    justSwitchedMode = true; // Trigger reconnect
                                    lcd.clear();
                                    lcd.print("THANH CONG!");
                                    lcd.setCursor(0, 1);
                                    if (isOfflineMode)
                                    {
                                        lcd.print("-> DA CHUYEN OFFLINE");
                                        lcd.setCursor(0, 2);
                                        lcd.print("WiFi se NGAT");
                                    }
                                    else
                                    {
                                        lcd.print("-> DA CHUYEN ONLINE");
                                        lcd.setCursor(0, 2);
                                        lcd.print("Dang ket noi WiFi..");
                                    }
                                    Serial.println(isOfflineMode ? "[MODE] Chuyển sang OFFLINE" : "[MODE] Chuyển sang ONLINE");
                                    vTaskDelay(pdMS_TO_TICKS(3000));
                                }
                                else if (millis() - confirmStart >= 10000)
                                {
                                    lcd.clear();
                                    lcd.print("HET THOI GIAN!");
                                    vTaskDelay(pdMS_TO_TICKS(1500));
                                }
                            }
                            else
                            {
                                lcd.clear();
                                lcd.print("SAI MAT KHAU!");
                                lcd.setCursor(0, 1);
                                lcd.print("Vui long thu lai");
                            }
                            vTaskDelay(pdMS_TO_TICKS(2000));
                            break;
                        }
                        else if (k == 'D')
                        {
                            if (tempPass.length() > 0)
                            {
                                tempPass.remove(tempPass.length() - 1);
                                lcd.setCursor(0, 1);
                                lcd.print("                    ");
                                lcd.setCursor(0, 1);
                                for (int i = 0; i < tempPass.length(); i++)
                                    lcd.print("*");
                            }
                        }
                        else if (k == 'A' || k == 'B' || k == 'C' || k == '*')
                        {
                            lcd.clear();
                            lcd.print("DA HUY BO");
                            vTaskDelay(pdMS_TO_TICKS(1000));
                            break;
                        }
                        else
                        {
                            tempPass += k;
                            lcd.print("*");
                        }
                    }
                    vTaskDelay(pdMS_TO_TICKS(50));
                }
                lcd.clear();
                isInputtingPassword = false;
            }
            // --- HẾT LOGIC OFFLINE ---

            // --- LOGIC ĐỔI MẬT KHẨU CỬA (PHÍM 'B') ---
            else if (key == 'B')
            {
                isInputtingPassword = true;
                lcd.clear();
                lcd.print("DOI MAT KHAU CUA");
                lcd.setCursor(0, 1);
                lcd.print("Nhap pass Admin:");
                lcd.setCursor(0, 2);

                String adminPass = "";
                bool adminAuthorized = false;

                // Bước 1: Nhập Admin Password
                while (true)
                {
                    char k = keypad.getKey();
                    if (k)
                    {
                        if (k == '#')
                        {
                            if (adminPass == ADMIN_PASSWORD)
                            {
                                adminAuthorized = true;
                                lcd.clear();
                                lcd.print("XAC THUC THANH CONG");
                                vTaskDelay(pdMS_TO_TICKS(1000));
                            }
                            else
                            {
                                lcd.clear();
                                lcd.print("SAI PASS ADMIN!");
                                vTaskDelay(pdMS_TO_TICKS(2000));
                            }
                            break;
                        }
                        else if (k == '*' || k == 'A' || k == 'C' || k == 'D')
                        {
                            lcd.clear();
                            lcd.print("DA HUY BO");
                            vTaskDelay(pdMS_TO_TICKS(1500));
                            break;
                        }
                        else if (k >= '0' && k <= '9')
                        {
                            adminPass += k;
                            lcd.print("*");
                        }
                    }
                    vTaskDelay(pdMS_TO_TICKS(50));
                }

                // Bước 2: Nhập mật khẩu cửa mới (nếu Admin pass đúng)
                if (adminAuthorized)
                {
                    lcd.clear();
                    lcd.print("NHAP PASS CUA MOI:");
                    lcd.setCursor(0, 1);
                    lcd.print("(4-8 ky tu)");
                    lcd.setCursor(0, 2);

                    String newDoorPass = "";
                    while (true)
                    {
                        char k = keypad.getKey();
                        if (k)
                        {
                            if (k == '#')
                            {
                                if (newDoorPass.length() >= 4 && newDoorPass.length() <= 8)
                                {
                                    saveDoorPassword(newDoorPass);
                                    lcd.clear();
                                    lcd.print("THAY DOI THANH CONG!");
                                    lcd.setCursor(0, 1);
                                    lcd.print("Pass moi: ");
                                    for (int i = 0; i < newDoorPass.length(); i++)
                                        lcd.print("*");
                                    vTaskDelay(pdMS_TO_TICKS(3000));
                                }
                                else
                                {
                                    lcd.clear();
                                    lcd.print("PASS 4-8 KY TU!");
                                    vTaskDelay(pdMS_TO_TICKS(2000));
                                }
                                break;
                            }
                            else if (k == 'D')
                            {
                                if (newDoorPass.length() > 0)
                                {
                                    newDoorPass.remove(newDoorPass.length() - 1);
                                    lcd.setCursor(0, 2);
                                    lcd.print("                    ");
                                    lcd.setCursor(0, 2);
                                    for (int i = 0; i < newDoorPass.length(); i++)
                                        lcd.print("*");
                                }
                            }
                            else if (k == '*' || k == 'A' || k == 'B' || k == 'C')
                            {
                                lcd.clear();
                                lcd.print("DA HUY BO");
                                vTaskDelay(pdMS_TO_TICKS(1500));
                                break;
                            }
                            else if ((k >= '0' && k <= '9') || (k >= 'A' && k <= 'D'))
                            {
                                if (newDoorPass.length() < 8)
                                {
                                    newDoorPass += k;
                                    lcd.print("*");
                                }
                            }
                        }
                        vTaskDelay(pdMS_TO_TICKS(50));
                    }
                }

                lcd.clear();
                isInputtingPassword = false;
            }
            // --- HẾT LOGIC ĐỔI MẬT KHẨU ---

            else if (!isUnlockMode)
            {
                if (key == '*')
                {
                    isUnlockMode = true;
                    passwordCorrect = false;
                    enteredPassword = "";
                    lcd.clear();
                    lcd.print("Nhap mat khau:");
                    lcd.setCursor(0, 1);
                }
                else if (doorOpen && key == 'C')
                {
                    doorServo.write(0);
                    doorOpen = false;
                    lcd.clear();
                    lcd.print("Cua da dong!");
                    vTaskDelay(pdMS_TO_TICKS(1500));
                    lcd.clear();
                }
            }
            else
            {
                if (key == '#')
                {
                    if (enteredPassword == doorPassword)
                    {
                        passwordCorrect = true;
                        lcd.clear();
                        lcd.print("Mat khau dung!");
                        lcd.setCursor(0, 1);
                        lcd.print("Nhan C de mo cua");
                    }
                    else
                    {
                        lcd.clear();
                        lcd.print("Sai mat khau!");
                        vTaskDelay(pdMS_TO_TICKS(1500));
                        lcd.clear();
                        lcd.print("Nhap mat khau:");
                        lcd.setCursor(0, 1);
                        enteredPassword = "";
                        passwordCorrect = false;
                    }
                }
                else if (key == 'D')
                {
                    if (enteredPassword.length() > 0)
                    {
                        enteredPassword.remove(enteredPassword.length() - 1);
                        lcd.setCursor(0, 1);
                        lcd.print("                     ");
                        lcd.setCursor(0, 1);
                        for (int i = 0; i < enteredPassword.length(); i++)
                            lcd.print('*');
                    }
                }
                else if (key == 'C')
                {
                    if (passwordCorrect)
                    {
                        if (!doorOpen)
                        {
                            doorServo.write(90);
                            doorOpen = true;
                            lcd.clear();
                            lcd.print("Cua da mo!");
                            // Ghi log khi mở cửa bằng keypad
                            sendActionLog("control_device", "keypad", "Opened door via keypad", true, "unknown_physical");
                        }
                        else
                        {
                            doorServo.write(0);
                            doorOpen = false;
                            lcd.clear();
                            lcd.print("Cua da dong!");
                            // Ghi log khi đóng cửa bằng keypad
                            sendActionLog("control_device", "keypad", "Closed door via keypad", true, "unknown_physical");
                        }
                        vTaskDelay(pdMS_TO_TICKS(1500));
                        lcd.clear();
                        isUnlockMode = false;
                    }
                }
                else if (key == '*')
                {
                    enteredPassword = "";
                    lcd.setCursor(0, 1);
                    lcd.print("                     ");
                    lcd.setCursor(0, 1);
                }
                else if (key >= '0' && key <= '9')
                {
                    enteredPassword += key;
                    lcd.print('*');
                }
            }
        }
        vTaskDelay(delayMs);
    }
}

void TaskAwning(void *pvParameters)
{
    (void)pvParameters;
    static unsigned long pressStartTime = 0;
    static bool isPressed = false;
    static bool longPressHandled = false;
    const unsigned long LONG_PRESS_DURATION = 3000;

    for (;;)
    {
        if (awningAutoMode && isRaining && awningOpen && !awningMoving)
        {
            awningDirection = -1;
            long target = awningStepper.currentPosition() + (long)awningDirection * stepsPerRevolution;
            awningStepper.moveTo(target);
            awningMoving = true;
            // Ghi log khi AUTO mode tự động đóng mái che do mưa
            sendActionLog("control_device", "system", "AUTO: Closing awning due to rain", true, "system");
        }

        int btnState = digitalRead(AWNING_BUTTON_PIN);

        if (btnState == LOW)
        {
            if (!isPressed)
            {
                isPressed = true;
                pressStartTime = millis();
                longPressHandled = false;
            }
            if (!longPressHandled && (millis() - pressStartTime > LONG_PRESS_DURATION))
            {
                awningAutoMode = !awningAutoMode;
                longPressHandled = true;
                Serial.println(awningAutoMode ? "[MODE] -> AUTO" : "[MODE] -> MANUAL");
                coDuLieuMoiCanGui = true;
                // Ghi log khi chuyển chế độ từ nút vật lý
                sendActionLog("control_device", "button",
                              awningAutoMode ? "Set awning to AUTO mode" : "Set awning to MANUAL mode",
                              true, "unknown_physical");
                if (!isUnlockMode)
                {
                    lcd.setCursor(0, 0);
                    lcd.print(awningAutoMode ? "Che do: AUTO       " : "Che do: MANUAL     ");
                }
            }
        }
        else
        {
            if (isPressed)
            {
                if (!longPressHandled)
                {
                    if (awningOpen)
                    {
                        if (!isUnlockMode)
                        {
                            lcd.setCursor(0, 0);
                            lcd.print("Dang dong mai che...");
                        }
                        awningDirection = -1;
                        // Ghi log khi đóng mái che từ nút vật lý
                        sendActionLog("control_device", "button", "Closing awning via button", true, "unknown_physical");
                    }
                    else
                    {
                        if (!isUnlockMode)
                        {
                            lcd.setCursor(0, 0);
                            lcd.print("Dang mo mai che...  ");
                        }
                        awningDirection = 1;
                        // Ghi log khi mở mái che từ nút vật lý
                        sendActionLog("control_device", "button", "Opening awning via button", true, "unknown_physical");
                    }
                    long target = awningStepper.currentPosition() + (long)awningDirection * stepsPerRevolution;
                    awningStepper.moveTo(target);
                    awningMoving = true;
                }
                isPressed = false;
            }
        }

        if (awningMoving)
        {
            awningStepper.run();
            if (awningStepper.distanceToGo() == 0)
            {
                awningMoving = false;
                awningOpen = (awningDirection == 1);
                Serial.println("Mái che hoàn tất.");
                if (!isUnlockMode)
                {
                    lcd.setCursor(0, 0);
                    lcd.print("                     ");
                }
            }
            vTaskDelay(pdMS_TO_TICKS(1));
        }
        else
        {
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    }
}

void TaskSendServer(void *pvParameters)
{
    (void)pvParameters;

    ensureSDReady();
    readSyncPointer();

    {
        float t = currentTemp;
        float h = currentHum;
        int gas = currentGasValue;
        bool fire = fireAlert;
        bool awning = awningOpen;
        bool door = doorOpen;
        bool raining = isRaining;
        bool autoMode = awningAutoMode;
        String payload = "{";
        payload += "\"temperature\":" + String(isnan(t) ? 0.0 : t, 1) + ",";
        payload += "\"humidity\":" + String(isnan(h) ? 0.0 : h, 1) + ",";
        payload += "\"gasValue\":" + String(gas) + ",";
        payload += "\"fireAlert\":" + String(fire ? "true" : "false") + ",";
        payload += "\"awningOpen\":" + String(awning ? "true" : "false") + ",";
        payload += "\"doorOpen\":" + String(door ? "true" : "false") + ",";
        payload += "\"raining\":" + String(raining ? "true" : "false") + ",";
        payload += "\"awningAutoMode\":" + String(autoMode ? "true" : "false");
        payload += "}";
        logDataToSD(payload);
        Serial.println("Đã ghi log khởi động vào SD (từ Core 0).");
    }

    if (WiFi.status() != WL_CONNECTED)
    {
        Serial.println("TaskSend: Bắt đầu WiFi...");
        btStop();
        Serial.println("Đã tắt Bluetooth Radio.");
        WiFi.begin(WIFI_SSID, WIFI_PASS);
    }

    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 10000)
    {
        vTaskDelay(pdMS_TO_TICKS(500));
        Serial.print(".");
    }

    if (WiFi.status() == WL_CONNECTED)
    {
        Serial.println("\nWiFi đã kết nối sớm.");
        coDuLieuMoiCanGui = true;
    }
    else
    {
        Serial.println("\nWiFi chưa kết nối; sẽ thử lại trong vòng lặp.");
    }

    for (;;)
    {
        // --- LOGIC OFFLINE MODE V5.0 ---
        if (isOfflineMode)
        {
            // Ngắt WiFi nếu đang bật
            if (WiFi.status() == WL_CONNECTED || WiFi.getMode() != WIFI_OFF)
            {
                Serial.println("[OFFLINE] Đang ngắt kết nối WiFi...");
                WiFi.disconnect(true);
                WiFi.mode(WIFI_OFF);
                Serial.println("[OFFLINE] ✓ Đã ngắt WiFi hoàn toàn. Chỉ ghi log SD.");
            }
            // Vẫn ghi log SD (Hộp đen)
            float t = currentTemp;
            float h = currentHum;
            int gas = currentGasValue;
            bool fire = fireAlert;
            bool awning = awningOpen;
            bool door = doorOpen;
            bool raining = isRaining;
            bool autoMode = awningAutoMode;
            String payload = "{";
            payload += "\"temperature\":" + String(isnan(t) ? 0.0 : t, 1) + ",";
            payload += "\"humidity\":" + String(isnan(h) ? 0.0 : h, 1) + ",";
            payload += "\"gasValue\":" + String(gas) + ",";
            payload += "\"fireAlert\":" + String(fire ? "true" : "false") + ",";
            payload += "\"awningOpen\":" + String(awning ? "true" : "false") + ",";
            payload += "\"doorOpen\":" + String(door ? "true" : "false") + ",";
            payload += "\"raining\":" + String(raining ? "true" : "false") + ",";
            payload += "\"awningAutoMode\":" + String(autoMode ? "true" : "false");
            payload += "}";
            logDataToSD(payload);

            vTaskDelay(pdMS_TO_TICKS(1000));
            continue; // Bỏ qua logic Online
        }
        // --- HẾT LOGIC OFFLINE ---

        bool justReconnected = false;

        // Nếu vừa chuyển từ Offline → Online, force reconnect
        if (justSwitchedMode)
        {
            justSwitchedMode = false;
            Serial.println("[ONLINE] Vừa chuyển sang Online. Đang kết nối WiFi...");
            WiFi.mode(WIFI_STA);
            WiFi.begin(WIFI_SSID, WIFI_PASS);
            unsigned long startAttempt = millis();
            while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 15000)
            {
                vTaskDelay(pdMS_TO_TICKS(500));
                Serial.print(".");
            }
            if (WiFi.status() == WL_CONNECTED)
            {
                Serial.println("\n[ONLINE] ✓ Đã kết nối WiFi thành công!");
                justReconnected = true;
                coDuLieuMoiCanGui = true;
            }
            else
            {
                Serial.println("\n[ONLINE] ✗ Kết nối WiFi thất bại. Sẽ thử lại.");
            }
        }
        // Logic reconnect bình thường khi mất kết nối
        else if (WiFi.status() != WL_CONNECTED)
        {
            Serial.println("[WiFi] Mất kết nối. Đang kết nối lại...");
            WiFi.disconnect();
            btStop();
            Serial.println("Đã tắt Bluetooth Radio (reconnect).");
            WiFi.begin(WIFI_SSID, WIFI_PASS);
            unsigned long startAttempt = millis();
            while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 15000)
            {
                vTaskDelay(pdMS_TO_TICKS(500));
                Serial.print(".");
            }
            if (WiFi.status() == WL_CONNECTED)
            {
                Serial.println("\n[WiFi] ✓ Đã kết nối lại WiFi!");
                justReconnected = true;
            }
            else
            {
                Serial.println("\n[WiFi] ✗ Kết nối thất bại. Sẽ thử lại sau.");
            }
        }

        float t = currentTemp;
        float h = currentHum;
        int gas = currentGasValue;
        bool fire = fireAlert;
        bool awning = awningOpen;
        bool door = doorOpen;
        bool raining = isRaining;
        bool autoMode = awningAutoMode;

        // Kiểm tra các sự kiện quan trọng (ưu tiên cao)
        bool criticalEvent = false;
        if (fire != lastSentFireAlert)
            criticalEvent = true; // Báo cháy
        if ((gas > gasThreshold) != lastSentGasAlert)
            criticalEvent = true; // Gas vượt ngưỡng
        if (door != lastSentDoorOpen)
            criticalEvent = true; // Cửa mở/đóng
        if (raining != lastSentRaining)
            criticalEvent = true; // Mưa bắt đầu/kết thúc
        if (awning != lastSentAwningOpen)
            criticalEvent = true; // Mái che thay đổi
        if (autoMode != lastSentAwningAutoMode)
            criticalEvent = true; // Auto mode thay đổi

        // Kiểm tra thay đổi đáng kể của cảm biến (ưu tiên trung bình)
        bool significantChange = false;
        if (!isnan(t) && !isnan(lastSentTemp) && fabs(t - lastSentTemp) >= TEMP_CHANGE_THRESHOLD)
            significantChange = true; // Nhiệt độ thay đổi >= 1°C
        if (!isnan(h) && !isnan(lastSentHum) && fabs(h - lastSentHum) >= HUM_CHANGE_THRESHOLD)
            significantChange = true; // Độ ẩm thay đổi >= 5%
        if (abs(gas - lastSentGas) >= GAS_CHANGE_THRESHOLD)
            significantChange = true; // Gas thay đổi >= 50

        unsigned long now = millis();
        // Gửi ngay nếu có critical event, hoặc gửi theo lịch nếu đủ thời gian
        bool shouldSendNow = criticalEvent ||                                    // Sự kiện khẩn cấp → gửi ngay
                             (significantChange && (now - lastSend >= 60000)) || // Thay đổi + đã qua 1 phút
                             (now - lastSend >= sendInterval);                   // Hoặc đã qua 15 phút (định kỳ)

        if (shouldSendNow)
        {
            // Log reason để debug
            if (criticalEvent)
                Serial.println("[DATA] Gửi do sự kiện khẩn cấp");
            else if (significantChange)
                Serial.println("[DATA] Gửi do thay đổi đáng kể");
            else
                Serial.println("[DATA] Gửi định kỳ (15 phút)");

            lastSend = now;
            lastSentTemp = isnan(t) ? lastSentTemp : t;
            lastSentHum = isnan(h) ? lastSentHum : h;
            lastSentGas = gas;
            lastSentAwningOpen = awning;
            lastSentFireAlert = fire;
            lastSentGasAlert = (gas > gasThreshold);
            lastSentDoorOpen = door;
            lastSentRaining = raining;
            lastSentAwningAutoMode = autoMode;

            String payload = "{";
            payload += "\"temperature\":" + String(isnan(t) ? 0.0 : t, 1) + ",";
            payload += "\"humidity\":" + String(isnan(h) ? 0.0 : h, 1) + ",";
            payload += "\"gasValue\":" + String(gas) + ",";
            payload += "\"fireAlert\":" + String(fire ? "true" : "false") + ",";
            payload += "\"awningOpen\":" + String(awning ? "true" : "false") + ",";
            payload += "\"doorOpen\":" + String(door ? "true" : "false") + ",";
            payload += "\"raining\":" + String(raining ? "true" : "false") + ",";
            payload += "\"awningAutoMode\":" + String(autoMode ? "true" : "false");
            payload += "}";
            logDataToSD(payload);

            if (WiFi.status() == WL_CONNECTED)
            {
                String sig = hmacSha256(payload, DEVICE_SECRET);
                HTTPClient http;
                http.begin(SERVER_URL);
                http.setTimeout(3000);
                http.addHeader("Content-Type", "application/json");
                http.addHeader("X-Signature", sig);
                int code = http.POST(payload);
                http.end();
                if (code >= 200 && code < 300)
                    Serial.println("✅ Đã gửi data: " + String(code));
                else
                    Serial.printf("⚠️ Gửi data thất bại: %d\n", code);
            }
        }

        if (WiFi.status() == WL_CONNECTED && (justReconnected || coDuLieuMoiCanGui))
        {
            resendUnsyncedFromSD();
        }
        unsigned long nowPoll = millis();
        if (WiFi.status() == WL_CONNECTED && nowPoll - lastPollTime >= POLL_INTERVAL)
        {
            lastPollTime = nowPoll;
            pollCommands();
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

// ================= HÀM SETUP CHÍNH =================
void setup()
{
    setupHardwareBase();
    bool rtcReady = false;
    for (int i = 0; i < 5; i++)
    {
        if (rtc.begin())
        {
            rtcReady = true;
            break;
        }
        delay(100);
    }
    if (!rtcReady)
        lcd.print("RTC Error");
    else if (rtc.lostPower())
        rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));

    readSensorsOnce();

    // Load mật khẩu cửa từ Preferences
    loadDoorPassword();

    lcd.clear();
    lcd.print("Dang khoi tao Task...");
    delay(500);

    xTaskCreatePinnedToCore(TaskSensorLCD, "TaskSensorLCD", 3072, NULL, 1, &hTaskSensorLCD, 1);
    delay(100);
    xTaskCreatePinnedToCore(TaskKeypadDoor, "TaskKeypadDoor", 3072, NULL, 1, &hTaskKeypadDoor, 1);
    delay(100);
    xTaskCreatePinnedToCore(TaskAwning, "TaskAwning", 3072, NULL, 1, &hTaskAwning, 1);
    delay(100);

    Serial.println("-> WiFi/SD Task Dang Khoi Dong (Core 0)...");
    lcd.clear();
    lcd.print("Khoi dong WiFi/SD...");
    xTaskCreatePinnedToCore(TaskSendServer, "TaskSendServer", 12288, NULL, 1, &hTaskSendServer, 0);

    lcd.clear();
    lcd.print("He thong san sang");
    delay(500);
    lcd.setCursor(0, 1);
    lcd.print("Dang ket noi WiFi...");
}

void loop()
{
    vTaskDelay(pdMS_TO_TICKS(1000));
}