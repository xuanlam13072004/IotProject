#include <WiFi.h>
#include <WebServer.h>
#include "esp_camera.h"
#include "ArduinoJson.h"
#include "mbedtls/md.h"

// ================== CẤU HÌNH MẠNG ==================
const char *WIFI_SSID = "XuanLamPC";      // ĐỔI THÀNH WIFI CỦA BẠN
const char *WIFI_PASS = "xuanlamdeptrai"; // ĐỔI THÀNH MẬT KHẨU WIFI

// ================== CẤU HÌNH FACE AI ==================
// PC chạy FastAPI face_server trên hotspot (192.168.137.1)
const char *FACE_API_HOST = "192.168.137.1";
const uint16_t FACE_API_PORT = 8888;
const char *FACE_API_PATH = "/recognize_jpeg";

// ================== CẤU HÌNH BACKEND ACCOUNT ==================
const char *ACCOUNT_API_HOST = "192.168.137.1";
const uint16_t ACCOUNT_API_PORT = 4000;
const char *ACCOUNT_API_PATH =
    "/api/devices/esp32_1/commands/from-camera";

// Secret HMAC phải trùng secretKey của device esp32_1 trong MongoDB
const char *DEVICE_SECRET = "my_secret_key_123"; // GIỐNG ESP32 CHÍNH

// Identity mà bạn train cho admin (trùng role trong DB)
const char *ADMIN_IDENTITY = "admin";

// ================== CHÂN BOARD ESP32-CAM AI THINKER ==================
#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22

// LED flash là GPIO 4
#define FLASH_LED_PIN 4

WebServer server(80);

// ================== HMAC SHA256 ==================
String hmacSha256(const String &data, const String &key)
{
    byte hmacResult[32];
    mbedtls_md_context_t ctx;
    mbedtls_md_type_t md_type = MBEDTLS_MD_SHA256;

    mbedtls_md_init(&ctx);
    mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(md_type), 1);
    mbedtls_md_hmac_starts(&ctx,
                           (const unsigned char *)key.c_str(),
                           key.length());
    mbedtls_md_hmac_update(&ctx,
                           (const unsigned char *)data.c_str(),
                           data.length());
    mbedtls_md_hmac_finish(&ctx, hmacResult);
    mbedtls_md_free(&ctx);

    String sig;
    char buf[3];
    for (int i = 0; i < 32; i++)
    {
        sprintf(buf, "%02x", (int)hmacResult[i]);
        sig += buf;
    }
    return sig;
}

// ================== WIFI ==================
void connectWiFi()
{
    WiFi.mode(WIFI_STA);

    // Static IP for ESP32-CAM so the app always knows the address
    IPAddress staticIP(192, 168, 137, 100);
    IPAddress gateway(192, 168, 137, 1);
    IPAddress subnet(255, 255, 255, 0);
    WiFi.config(staticIP, gateway, subnet);

    WiFi.begin(WIFI_SSID, WIFI_PASS);
    Serial.printf("Connecting to WiFi %s", WIFI_SSID);
    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 15000)
    {
        delay(500);
        Serial.print(".");
    }
    if (WiFi.status() == WL_CONNECTED)
    {
        Serial.printf("\nWiFi connected, IP: %s\n",
                      WiFi.localIP().toString().c_str());
    }
    else
    {
        Serial.println("\nWiFi connect failed");
    }
}

// ================== CAMERA INIT ==================
bool initCamera()
{
    camera_config_t config;
    config.ledc_channel = LEDC_CHANNEL_0;
    config.ledc_timer = LEDC_TIMER_0;

    config.pin_d0 = Y2_GPIO_NUM;
    config.pin_d1 = Y3_GPIO_NUM;
    config.pin_d2 = Y4_GPIO_NUM;
    config.pin_d3 = Y5_GPIO_NUM;
    config.pin_d4 = Y6_GPIO_NUM;
    config.pin_d5 = Y7_GPIO_NUM;
    config.pin_d6 = Y8_GPIO_NUM;
    config.pin_d7 = Y9_GPIO_NUM;

    config.pin_xclk = XCLK_GPIO_NUM;
    config.pin_pclk = PCLK_GPIO_NUM;
    config.pin_vsync = VSYNC_GPIO_NUM;
    config.pin_href = HREF_GPIO_NUM;
    config.pin_sccb_sda = SIOD_GPIO_NUM;
    config.pin_sccb_scl = SIOC_GPIO_NUM;
    config.pin_pwdn = PWDN_GPIO_NUM;
    config.pin_reset = RESET_GPIO_NUM;

    config.xclk_freq_hz = 20000000;
    config.pixel_format = PIXFORMAT_JPEG;

    // chất lượng đủ cao cho nhận diện, vẫn an toàn RAM
    config.frame_size = FRAMESIZE_VGA; // 640x480
    config.jpeg_quality = 12;
    config.fb_count = 1;

    esp_err_t err = esp_camera_init(&config);
    if (err != ESP_OK)
    {
        Serial.printf("esp_camera_init failed 0x%x\n", err);
        return false;
    }

    // chỉnh hướng ảnh nếu cần
    sensor_t *s = esp_camera_sensor_get();
    s->set_vflip(s, 1);
    s->set_hmirror(s, 1);

    Serial.println("Camera init done");
    return true;
}

// ================== HTTP HELPER ==================
bool httpPostRaw(const char *host,
                 uint16_t port,
                 const String &path,
                 const String &contentType,
                 const uint8_t *body,
                 size_t bodyLen,
                 const String &extraHeaders,
                 String &outBody)
{
    WiFiClient client;
    if (!client.connect(host, port))
    {
        return false;
    }

    String req;
    req += "POST " + path + " HTTP/1.1\r\n";
    req += "Host: " + String(host) + ":" + String(port) + "\r\n";
    req += "Content-Type: " + contentType + "\r\n";
    req += "Content-Length: " + String(bodyLen) + "\r\n";
    if (extraHeaders.length())
        req += extraHeaders;
    req += "Connection: close\r\n\r\n";

    client.print(req);
    client.write(body, bodyLen);

    String resp;
    unsigned long start = millis();
    while (client.connected() && millis() - start < 15000)
    {
        while (client.available())
        {
            resp += (char)client.read();
        }
        delay(1);
    }
    client.stop();

    int idx = resp.indexOf("\r\n\r\n");
    if (idx < 0)
        return false;
    outBody = resp.substring(idx + 4);
    return true;
}

// ================== RECOGNIZE FACE ==================
bool recognizeOnce(String &identity, String &debugMsg)
{
    identity = "";
    debugMsg = "";

    if (WiFi.status() != WL_CONNECTED)
    {
        connectWiFi();
    }
    if (WiFi.status() != WL_CONNECTED)
    {
        debugMsg = "wifi_not_connected";
        return false;
    }

    // Chụp liên tục trong 5 giây để tăng độ ổn định nhận diện.
    const unsigned long captureWindowMs = 5000;
    const unsigned long captureIntervalMs = 250;
    unsigned long startedAt = millis();

    int totalRecognized = 0;
    int adminHits = 0;
    String lastIdentity = "";
    String lastMsg = "";

    while (millis() - startedAt < captureWindowMs)
    {
        digitalWrite(FLASH_LED_PIN, HIGH);
        delay(60);
        camera_fb_t *fb = esp_camera_fb_get();
        digitalWrite(FLASH_LED_PIN, LOW);

        if (!fb)
        {
            lastMsg = "capture_failed";
            delay(captureIntervalMs);
            continue;
        }

        String body;
        bool ok = httpPostRaw(
            FACE_API_HOST,
            FACE_API_PORT,
            String(FACE_API_PATH),
            "image/jpeg",
            fb->buf,
            fb->len,
            "",
            body);

        esp_camera_fb_return(fb);

        if (!ok)
        {
            lastMsg = "face_api_http_failed";
            delay(captureIntervalMs);
            continue;
        }

        StaticJsonDocument<256> doc;
        auto err = deserializeJson(doc, body);
        if (err)
        {
            lastMsg = "face_api_json_error";
            delay(captureIntervalMs);
            continue;
        }

        if (doc.containsKey("identity") && !doc["identity"].isNull())
        {
            String detected = String((const char *)doc["identity"]);
            lastIdentity = detected;
            lastMsg = doc["message"] | "";
            totalRecognized++;
            if (detected.equalsIgnoreCase(ADMIN_IDENTITY))
            {
                adminHits++;
            }
        }
        else
        {
            lastMsg = doc["message"] | "no_identity";
        }

        delay(captureIntervalMs);
    }

    if (totalRecognized == 0)
    {
        debugMsg = lastMsg.length() ? lastMsg : "no_identity_5s";
        return false;
    }

    if (adminHits > 0)
    {
        identity = ADMIN_IDENTITY;
        debugMsg = "admin_hits_" + String(adminHits) + "_of_" + String(totalRecognized);
        return true;
    }

    identity = lastIdentity;
    debugMsg = "not_admin_after_5s";
    return true;
}

// ================== SEND OPEN_DOOR COMMAND ==================
bool sendOpenDoorCommand(String &respBody)
{
    if (WiFi.status() != WL_CONNECTED)
    {
        connectWiFi();
    }
    if (WiFi.status() != WL_CONNECTED)
    {
        return false;
    }

    String payload = "{\"action\":\"open_door\"}";
    String sig = hmacSha256(payload, DEVICE_SECRET);
    String headers = "x-signature: " + sig + "\r\n";

    return httpPostRaw(
        ACCOUNT_API_HOST,
        ACCOUNT_API_PORT,
        String(ACCOUNT_API_PATH),
        "application/json",
        (const uint8_t *)payload.c_str(),
        payload.length(),
        headers,
        respBody);
}

// ================== FLOW: FACE → OPEN DOOR ==================
String runFaceDoorFlow()
{
    String id, msg;
    if (!recognizeOnce(id, msg))
    {
        String s = "{\"ok\":false,\"step\":\"recognize\",\"message\":\"";
        s += msg;
        s += "\"}";
        return s;
    }

    if (!id.equalsIgnoreCase(ADMIN_IDENTITY))
    {
        String s = "{\"ok\":false,\"step\":\"authorize\",\"identity\":\"";
        s += id;
        s += "\"}";
        return s;
    }

    String backendResp;
    if (!sendOpenDoorCommand(backendResp))
    {
        return "{\"ok\":false,\"step\":\"send_command\",\"message\":\"backend_failed\"}";
    }

    String s = "{\"ok\":true,\"step\":\"done\",\"identity\":\"";
    s += id;
    s += "\"}";
    return s;
}

// ================== HTTP HANDLERS ==================
void handleRoot()
{
    String ip = WiFi.localIP().toString();
    String json = "{\"ok\":true,\"ip\":\"" + ip +
                  "\",\"endpoints\":[\"GET /open_cam\",\"GET /snapshot.jpg\"]}";
    server.send(200, "application/json", json);
}

void handleOpenCam()
{
    String result = runFaceDoorFlow();
    server.send(200, "application/json", result);
}

// trả về ảnh JPEG mới chụp để app hiển thị
void handleSnapshot()
{
    if (WiFi.status() != WL_CONNECTED)
    {
        server.send(503, "text/plain", "WiFi not connected");
        return;
    }

    digitalWrite(FLASH_LED_PIN, HIGH);
    delay(80);
    camera_fb_t *fb = esp_camera_fb_get();
    digitalWrite(FLASH_LED_PIN, LOW);

    if (!fb)
    {
        server.send(500, "text/plain", "Camera capture failed");
        return;
    }

    WiFiClient client = server.client();
    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: image/jpeg");
    client.print("Content-Length: ");
    client.println(fb->len);
    client.println("Connection: close");
    client.println();
    client.write(fb->buf, fb->len);

    esp_camera_fb_return(fb);
}

// ================== SETUP & LOOP ==================
void setup()
{
    Serial.begin(115200);
    delay(500);

    pinMode(FLASH_LED_PIN, OUTPUT);
    digitalWrite(FLASH_LED_PIN, LOW);

    if (!initCamera())
    {
        delay(4000);
        ESP.restart();
    }

    connectWiFi();

    server.on("/", HTTP_GET, handleRoot);
    server.on("/open_cam", HTTP_GET, handleOpenCam);
    server.on("/snapshot.jpg", HTTP_GET, handleSnapshot);
    server.begin();

    Serial.println("ESP32-CAM ready. Open http://<IP>/ in browser.");
}

void loop()
{
    server.handleClient();
}