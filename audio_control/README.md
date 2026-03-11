# Mobile Voice Auth Server (2 lớp)

Server này nhận audio từ app mobile và chạy xác thực giọng nói 2 lớp:
- Lớp 1: Anti-spoof (phát lại/TTS vs giọng thật)
- Lớp 2: Speaker verification (đúng chủ nhà hay không)

## Cấu trúc chính

- `mobile_audio_server.py`: API server FastAPI (entrypoint cho mobile app)
- `main_voice_auth.py`: Orchestrator enroll/verify/calibrate
- `anti_spoof_layer.py`: Lớp chống giả mạo
- `speaker_identity_layer.py`: Lớp xác minh danh tính
- `enrollment_features.py`: Preprocess audio, embedding, voiceprint gallery
- `voiceprints/`: Dữ liệu owner đã enroll

## Yêu cầu môi trường

Trong `voice_env` cần có các package:
- `numpy`, `torch`, `speechbrain`, `soundfile`
- `fastapi`, `uvicorn`, `python-multipart`
- `transformers` (Whisper)
- `google-generativeai`, `python-dotenv` (Gemini)

Tạo file `.env` từ `.env.example`:

```powershell
cd C:\IoT_System_Project\audio_control
copy .env.example .env
```

Sau đó điền API key:

```env
GEMINI_API_KEY=your_real_key_here
BACKEND_ACCOUNT_URL=http://127.0.0.1:4000
VOICE_BRIDGE_SECRET=change_me_voice_bridge_secret
WHISPER_MODEL=vinai/phowhisper-small
IOT_INITIAL_PROMPT_PATH=./initial_prompt_vi.txt
```

- `BACKEND_ACCOUNT_URL`: URL của `backend_account`.
- `VOICE_BRIDGE_SECRET`: shared secret để `mobile_audio_server` gửi lệnh nội bộ sang `backend_account`.
- `WHISPER_MODEL`: model Whisper dùng cho ASR tiếng Việt (mặc định `vinai/phowhisper-small`).
- `IOT_INITIAL_PROMPT_PATH`: file từ điển lệnh IoT tiếng Việt để Gemini tự sửa lỗi chính tả transcript.

## Chạy server

PowerShell (Windows):

```powershell
cd C:\IoT_System_Project\audio_control
.\voice_env\Scripts\Activate.ps1
python -m uvicorn mobile_audio_server:app --host 0.0.0.0 --port 8080
```

Kiểm tra:

```powershell
Invoke-RestMethod -Uri http://127.0.0.1:8000/health -Method Get
```

## API cho mobile app

### 1) `POST /api/noise-floor`
Calibrate noise floor từ audio môi trường.

- Form-data:
  - `ambient_audio` (file, wav/m4a/ogg/...)

Ví dụ:

```powershell
curl.exe -X POST http://127.0.0.1:8000/api/noise-floor ^
  -F "ambient_audio=@ambient.wav"
```

### 2) `POST /api/enroll`
Đăng ký owner từ nhiều mẫu audio.

- Form-data:
  - `owner_id` (text)
  - `audio_samples` (>=3 file)

Ví dụ:

```powershell
curl.exe -X POST http://127.0.0.1:8000/api/enroll ^
  -F "owner_id=home_owner" ^
  -F "audio_samples=@take1.wav" ^
  -F "audio_samples=@take2.wav" ^
  -F "audio_samples=@take3.wav"
```

### 3) `POST /api/verify`
Xác thực 1 mẫu audio mới.

- Form-data:
  - `owner_id` (text)
  - `audio_sample` (1 file)

Ví dụ:

```powershell
curl.exe -X POST http://127.0.0.1:8000/api/verify ^
  -F "owner_id=home_owner" ^
  -F "audio_sample=@probe.wav"
```

`/api/verify` sẽ chạy 2 giai đoạn:
- Stage 1: xác thực 2 lớp (anti-spoof + speaker verification).
- Stage 2: Whisper (`WHISPER_MODEL`, mặc định `vinai/phowhisper-small`) chuyển audio -> text tiếng Việt, rồi gửi sang Gemini (`gemini-1.5-flash`) để tự sửa lỗi chính tả dựa trên `initial_prompt_vi.txt` trước khi map thành JSON hành động theo danh sách `device_id` hardcode trong backend.
- Nếu `action_json.ready_for_backend=true`, server sẽ tự gọi `backend_account` (`POST /api/voice/commands`) để queue command cho ESP32, tương tự luồng lệnh từ app.

### 4) `POST /api/calibrate`
Calibrate threshold/fusion cho 1 owner từ nhiều mẫu audio.

- Form-data:
  - `owner_id` (text)
  - `audio_samples` (>=3 file)

## Lưu ý tích hợp mobile

- App nên gửi file mono hoặc stereo đều được; server tự chuyển mono và resample về 16k.
- Mỗi mẫu enroll nên dài khoảng 4–6 giây, nói rõ ràng, phòng ít ồn.
- Nên gọi `/api/noise-floor` 1 lần khi bắt đầu phiên hoặc khi đổi môi trường.

## Lỗi thường gặp

- `400 Cần ít nhất 3 file audio để enroll/calibrate`: thiếu số lượng file.
- `400 Không phát hiện giọng nói vượt ngưỡng Noise Floor`: audio quá nhỏ hoặc nhiễu nền quá cao.
- `404 Không tìm thấy voiceprint...`: owner chưa enroll.

## Ghi chú

Luồng sử dụng chính là app mobile upload audio vào `mobile_audio_server.py`.
