from fastapi import FastAPI, UploadFile, File, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import cv2
import numpy as np
import tempfile
import pickle
import os
import traceback
import uvicorn
from insightface.app import FaceAnalysis

app = FastAPI()

# ================= CORS =================
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ================= LOAD MODELS =================
print("🔹 Loading ArcFace 512D (buffalo_l)...")
try:
    arcface_app = FaceAnalysis(
        name="buffalo_l",
        providers=["CPUExecutionProvider"]
    )
except TypeError:
    arcface_app = FaceAnalysis(name="buffalo_l")
arcface_app.prepare(ctx_id=-1, det_size=(640, 640))

print("🔹 Loading SVM & LabelEncoder...")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(BASE_DIR, "face_models_arcface_512")

svm_path = os.path.join(MODEL_DIR, "svm_arcface_512.pkl")
label_path = os.path.join(MODEL_DIR, "label_encoder_arcface.pkl")

if not os.path.exists(svm_path):
    raise FileNotFoundError(f"Missing SVM model file: {svm_path}")
if not os.path.exists(label_path):
    raise FileNotFoundError(f"Missing label encoder file: {label_path}")

with open(svm_path, "rb") as f:
    svm_model = pickle.load(f)
with open(label_path, "rb") as f:
    label_encoder = pickle.load(f)

print("✅ face_server models loaded successfully")

# ================= HEALTH CHECK =================
@app.get("/health")
async def health():
    return {"status": "ok"}

# ================= API NHẬN VIDEO =================
@app.post("/recognize")
async def recognize_video(file: UploadFile = File(...)):
    video_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mp4") as tmp:
            tmp.write(await file.read())
            video_path = tmp.name

        cap = cv2.VideoCapture(video_path)
        results = {}
        frame_count = 0

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break

            frame_count += 1
            if frame_count % 10 != 0:
                continue

            faces = arcface_app.get(frame)
            if len(faces) == 0:
                continue

            emb = faces[0].embedding.reshape(1, -1)
            probs = svm_model.predict_proba(emb)[0]
            idx = np.argmax(probs)
            name = label_encoder.inverse_transform([idx])[0]

            results[name] = results.get(name, 0) + 1

        cap.release()

        if not results:
            return {"message": "No face recognized"}

        final_identity = max(results, key=results.get)
        return {"identity": final_identity, "frames": results}

    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={
            "identity": None, "message": f"Server error: {e}"
        })
    finally:
        if video_path and os.path.exists(video_path):
            os.unlink(video_path)


# ================= API NHẬN ẢNH JPEG (CHO ESP32-CAM) =================
@app.post("/recognize_jpeg")
async def recognize_jpeg(request: Request):
    """
    Endpoint đơn giản cho ESP32-CAM:
    - ESP32-CAM gửi ảnh JPEG (Content-Type: image/jpeg) qua HTTP POST
    - Server decode ảnh, chạy ArcFace, trả về { identity: <name>|null }
    """
    try:
        data = await request.body()
        nparr = np.frombuffer(data, np.uint8)
        frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

        if frame is None:
            return {"identity": None, "message": "Invalid image"}

        faces = arcface_app.get(frame)
        if len(faces) == 0:
            return {"identity": None, "message": "No face detected"}

        emb = faces[0].embedding.reshape(1, -1)
        probs = svm_model.predict_proba(emb)[0]
        idx = np.argmax(probs)
        name = label_encoder.inverse_transform([idx])[0]

        return {"identity": name}

    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={
            "identity": None, "message": f"Server error: {e}"
        })

# ================= API mở webcam xác thực =================
# @app.post("/recognize_cam")
# def recognize_cam():
#     cap = cv2.VideoCapture(0)
#     results = {}
#     frame_count = 0
#     max_frames = 50 

#     while cap.isOpened() and frame_count < max_frames:
#         ret, frame = cap.read()
#         if not ret:
#             break
#         frame_count += 1
#         if frame_count % 10 != 0:
#             continue
#         faces = arcface_app.get(frame)
#         if len(faces) == 0:
#             continue
#         emb = faces[0].embedding.reshape(1, -1)
#         probs = svm_model.predict_proba(emb)[0]
#         idx = np.argmax(probs)
#         name = label_encoder.inverse_transform([idx])[0]
#         results[name] = results.get(name, 0) + 1
#     cap.release()
#     if not results:
#         return {"message": "No face recognized"}
#     final_identity = max(results, key=results.get)
#     return {
#         "identity": final_identity,
#         "frames": results
#     }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8888)
