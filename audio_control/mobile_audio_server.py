from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import time
from datetime import datetime
from pathlib import Path
from typing import List
from urllib import error as urllib_error
from urllib import request as urllib_request

import shutil
import numpy as np
import soundfile as sf
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from main_voice_auth import TwoLayerVoiceAuthenticator
from processing_stage import DEVICE_CATALOG, ProcessingStage


BASE_DIR = Path(__file__).resolve().parent
VOICEPRINT_DIR = BASE_DIR / "voiceprints"
load_dotenv(BASE_DIR / ".env")


app = FastAPI(title="Mobile Voice Auth Server", version="1.0.0")
auth = TwoLayerVoiceAuthenticator(
    voiceprint_dir=str(VOICEPRINT_DIR),
    speaker_threshold=0.68,
    anti_spoof_threshold=0.62,
    voiceprint_ext=".npz",
    fusion_threshold=0.64,
)
processing_stage = ProcessingStage(sample_rate=16000)


def _dispatch_voice_command_to_backend(
    owner_id: str,
    transcript_text: str,
    action_json: dict,
    is_valid: bool,
    fusion_score: float,
) -> dict:
    ready = bool(action_json.get("ready_for_backend", False))
    backend_command = action_json.get("backend_command")
    device_id = str(action_json.get("device_id", "")).strip()

    if not ready or not isinstance(backend_command, dict) or not device_id:
        return {
            "status": "skipped",
            "reason": "Command is not ready for backend dispatch",
        }

    bridge_secret = os.getenv("VOICE_BRIDGE_SECRET", "").strip()
    if not bridge_secret:
        return {
            "status": "skipped",
            "reason": "VOICE_BRIDGE_SECRET is missing",
        }

    backend_base = os.getenv("BACKEND_ACCOUNT_URL", "http://127.0.0.1:4000").strip().rstrip("/")
    endpoint = f"{backend_base}/api/voice/commands"
    payload = {
        "deviceId": device_id,
        "command": backend_command,
        "meta": {
            "owner_id": owner_id,
            "transcript_text": transcript_text,
            "is_valid": bool(is_valid),
            "fusion_score": float(fusion_score),
        },
    }

    payload_bytes = json.dumps(payload).encode("utf-8")
    timestamp = str(int(time.time()))
    message = timestamp.encode("utf-8") + b"." + payload_bytes
    signature = hmac.new(
        bridge_secret.encode("utf-8"), message, hashlib.sha256
    ).hexdigest()

    req = urllib_request.Request(
        endpoint,
        data=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "X-Signature": signature,
            "X-Timestamp": timestamp,
        },
        method="POST",
    )

    try:
        with urllib_request.urlopen(req, timeout=8) as response:
            raw = response.read().decode("utf-8")
            body = json.loads(raw) if raw else {}
            return {
                "status": "accepted",
                "endpoint": endpoint,
                "http_status": response.status,
                "response": body,
            }
    except urllib_error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore") if exc.fp is not None else str(exc)
        return {
            "status": "error",
            "endpoint": endpoint,
            "http_status": int(exc.code),
            "detail": detail,
        }
    except Exception as exc:
        return {
            "status": "error",
            "endpoint": endpoint,
            "detail": str(exc),
        }


def _to_http_exception(exc: Exception) -> HTTPException:
    if isinstance(exc, FileNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, ValueError | RuntimeError):
        return HTTPException(status_code=400, detail=str(exc))
    return HTTPException(status_code=500, detail=f"Lỗi nội bộ server: {exc}")


def _resample_linear(audio: np.ndarray, src_sr: int, dst_sr: int = 16000) -> np.ndarray:
    if src_sr == dst_sr:
        return audio.astype(np.float32)
    if len(audio) < 2:
        return audio.astype(np.float32)

    duration = len(audio) / float(src_sr)
    dst_len = max(1, int(duration * dst_sr))
    src_t = np.linspace(0.0, duration, num=len(audio), endpoint=False)
    dst_t = np.linspace(0.0, duration, num=dst_len, endpoint=False)
    out = np.interp(dst_t, src_t, audio).astype(np.float32)
    return out


def _decode_upload_to_mono_16k(upload: UploadFile) -> np.ndarray:
    data = upload.file.read()
    if not data:
        raise HTTPException(status_code=400, detail=f"File rỗng: {upload.filename}")

    try:
        audio, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=False)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Không đọc được file audio {upload.filename}: {exc}")

    arr = np.asarray(audio, dtype=np.float32)
    if arr.ndim == 2:
        arr = np.mean(arr, axis=1)
    arr = np.squeeze(arr)
    if arr.ndim != 1 or len(arr) == 0:
        raise HTTPException(status_code=400, detail=f"Audio không hợp lệ: {upload.filename}")

    arr = _resample_linear(arr, src_sr=int(sr), dst_sr=16000)
    arr = np.clip(arr, -1.0, 1.0)
    return arr.astype(np.float32)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "service": "mobile-audio-server"}


@app.post("/api/noise-floor")
def set_noise_floor(ambient_audio: UploadFile = File(...)) -> dict:
    try:
        audio = _decode_upload_to_mono_16k(ambient_audio)
        noise = auth.enrollment.calibrate_noise_floor_from_audio(audio, ambient_sec=max(1.0, len(audio) / 16000.0))
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)
    return {
        "status": "ok",
        "noise_floor_rms": noise,
    }


@app.get("/api/voice-profiles")
def list_voice_profiles() -> dict:
    profiles = []
    base = VOICEPRINT_DIR
    if not base.exists():
        return {"profiles": profiles}

    for owner_dir in base.iterdir():
        if not owner_dir.is_dir():
            continue
        if owner_dir.name == "anti_spoof_profiles":
            # Bỏ qua thư mục chứa profile anti-spoof, chỉ trả về hồ sơ người dùng
            continue
        owner_id = owner_dir.name
        sample_files = list(owner_dir.glob("sample_*.npy"))
        calibration_file = base / f"{owner_id}_calibration.json"
        meta_file = owner_dir / "metadata.json"
        updated_ts = owner_dir.stat().st_mtime
        try:
            if meta_file.exists():
                updated_ts = max(updated_ts, meta_file.stat().st_mtime)
        except Exception:
            pass

        profiles.append(
            {
                "owner_id": owner_id,
                "sample_count": len(sample_files),
                "calibrated": calibration_file.exists(),
                "updated_at": datetime.fromtimestamp(updated_ts).isoformat(),
            }
        )

    profiles.sort(key=lambda x: x.get("owner_id", ""))
    return {"profiles": profiles}


@app.post("/api/enroll")
def enroll_from_mobile(
    owner_id: str = Form(...),
    audio_samples: List[UploadFile] = File(...),
) -> dict:
    try:
        if len(audio_samples) < 3:
            raise HTTPException(status_code=400, detail="Cần ít nhất 3 file audio để enroll.")

        decoded = [_decode_upload_to_mono_16k(f) for f in audio_samples]

        if auth.enrollment.preprocessor.calibrated_noise_floor_rms is None:
            ambient = decoded[0][: min(len(decoded[0]), 16000 * 2)]
            auth.enrollment.calibrate_noise_floor_from_audio(ambient, ambient_sec=max(1.0, len(ambient) / 16000.0))

        auth.enroll_from_audios(owner_id=owner_id, raw_audios=decoded)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    return {
        "status": "ok",
        "message": f"Enroll thành công cho {owner_id}",
        "num_samples_received": len(decoded),
    }


@app.post("/api/train")
def train_from_mobile(
    owner_id: str = Form(...),
    audio_sample: UploadFile = File(...),
) -> dict:
    try:
        raw = _decode_upload_to_mono_16k(audio_sample)

        if auth.enrollment.preprocessor.calibrated_noise_floor_rms is None:
            ambient = raw[: min(len(raw), 16000 * 2)]
            auth.enrollment.calibrate_noise_floor_from_audio(ambient, ambient_sec=max(1.0, len(ambient) / 16000.0))

        train_result = auth.enrollment.train_from_audio(owner_id=owner_id, raw_audio=raw)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    return {
        "status": "ok",
        "owner_id": owner_id,
        **train_result,
    }


@app.post("/api/verify-only")
def verify_only_from_mobile(
    owner_id: str = Form(...),
    audio_sample: UploadFile = File(...),
) -> dict:
    """Verify voice identity only — no Whisper transcription, no backend command dispatch."""
    try:
        raw = _decode_upload_to_mono_16k(audio_sample)

        if auth.enrollment.preprocessor.calibrated_noise_floor_rms is None:
            ambient = raw[: min(len(raw), 16000 * 2)]
            auth.enrollment.calibrate_noise_floor_from_audio(ambient, ambient_sec=max(1.0, len(ambient) / 16000.0))

        result = auth.verify_from_audio(owner_id=owner_id, raw_audio=raw)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    return {
        "status": "ok",
        "owner_id": owner_id,
        "anti_spoof_score": result.anti_spoof_score,
        "similarity_score": result.similarity_score,
        "fusion_score": result.fusion_score,
        "snr_db": result.snr_db,
        "is_valid": result.is_valid,
        "message": result.message,
    }


@app.post("/api/verify")
def verify_from_mobile(
    owner_id: str = Form(...),
    audio_sample: UploadFile = File(...),
) -> dict:
    processing_result = None
    processing_error = None
    backend_dispatch = None

    try:
        raw = _decode_upload_to_mono_16k(audio_sample)

        if auth.enrollment.preprocessor.calibrated_noise_floor_rms is None:
            ambient = raw[: min(len(raw), 16000 * 2)]
            auth.enrollment.calibrate_noise_floor_from_audio(ambient, ambient_sec=max(1.0, len(ambient) / 16000.0))

        result = auth.verify_from_audio(owner_id=owner_id, raw_audio=raw)

        try:
            processing_result = processing_stage.process_audio_to_action(raw)
            gemini_raw = processing_result.action_json.get("gemini_raw_text", "")
            if gemini_raw:
                print(f"[GEMINI RAW] {gemini_raw}")

            if result.is_valid:
                backend_dispatch = _dispatch_voice_command_to_backend(
                    owner_id=owner_id,
                    transcript_text=processing_result.transcript_text,
                    action_json=processing_result.action_json,
                    is_valid=result.is_valid,
                    fusion_score=result.fusion_score,
                )
                print(f"[VOICE->BACKEND] {backend_dispatch}")
                print(f"Xác thực thành công. Đang thực hiện lệnh: {processing_result.action_json}")
            else:
                print(f"Xác thực thất bại (is_valid=False). Không gửi lệnh tới backend.")
                backend_dispatch = {
                    "status": "rejected",
                    "reason": "Voice verification failed",
                }
        except Exception as stage_exc:
            processing_error = str(stage_exc)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    response = {
        "status": "ok",
        "owner_id": owner_id,
        "anti_spoof_score": result.anti_spoof_score,
        "similarity_score": result.similarity_score,
        "fusion_score": result.fusion_score,
        "snr_db": result.snr_db,
        "is_valid": result.is_valid,
        "message": result.message,
    }

    if processing_result is not None:
        response["processing_stage"] = {
            "transcript_text": processing_result.transcript_text,
            "action_json": processing_result.action_json,
            "device_catalog": DEVICE_CATALOG,
        }
        if backend_dispatch is not None:
            response["processing_stage"]["backend_dispatch"] = backend_dispatch
    if processing_error is not None:
        response["processing_stage_error"] = processing_error

    return response


@app.post("/api/calibrate")
def calibrate_from_mobile(
    owner_id: str = Form(...),
    audio_samples: List[UploadFile] = File(...),
) -> dict:
    try:
        if len(audio_samples) < 3:
            raise HTTPException(status_code=400, detail="Cần ít nhất 3 file audio để calibrate.")

        decoded = [_decode_upload_to_mono_16k(f) for f in audio_samples]
        cal = auth.calibrate_owner_from_audios(owner_id=owner_id, raw_audios=decoded)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    return {
        "status": "ok",
        "owner_id": owner_id,
        "calibration": cal,
    }


@app.post("/api/anti-spoof/train")
def train_anti_spoof_from_mobile(
    owner_id: str = Form(...),
    spoof_samples: List[UploadFile] = File(...),
) -> dict:
    """Upload real spoof audio samples (loa phát lại, TTS, ...) to retrain anti-spoof model."""
    try:
        if len(spoof_samples) < 1:
            raise HTTPException(status_code=400, detail="Cần ít nhất 1 file audio spoof.")

        decoded = [_decode_upload_to_mono_16k(f) for f in spoof_samples]
        train_result = auth.retrain_anti_spoof(owner_id=owner_id, real_spoof_audios=decoded)
    except HTTPException:
        raise
    except Exception as exc:
        raise _to_http_exception(exc)

    _log_anti_spoof_to_backend(owner_id, "retrain", train_result)

    return {
        "status": "ok",
        "owner_id": owner_id,
        "message": f"Anti-spoof retrain hoàn tất cho {owner_id}",
        **train_result,
    }


def _log_anti_spoof_to_backend(owner_id: str, action: str, train_result: dict) -> None:
    """Best-effort log training session to backend_account MongoDB."""
    backend_base = os.getenv("BACKEND_ACCOUNT_URL", "http://127.0.0.1:4000").strip().rstrip("/")
    endpoint = f"{backend_base}/api/anti-spoof-logs"
    payload = {
        "ownerId": owner_id,
        "action": action,
        "numBonafide": train_result.get("num_bonafide", 0),
        "numSpoofSimulated": train_result.get("num_spoof_simulated", 0),
        "numSpoofReal": train_result.get("num_spoof_real", 0),
        "numSpoofRealNew": train_result.get("num_spoof_real_new", 0),
        "savedSpoofFiles": train_result.get("saved_spoof_files", []),
        "epochs": train_result.get("epochs", 0),
        "finalLoss": train_result.get("final_loss"),
        "source": "api",
    }
    try:
        req = urllib_request.Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib_request.urlopen(req, timeout=5) as resp:
            print(f"[ANTI-SPOOF LOG] Đã ghi log MongoDB: {resp.status}")
    except Exception as exc:
        print(f"[ANTI-SPOOF LOG] Không ghi được log MongoDB: {exc}")


@app.get("/api/anti-spoof/history")
def get_anti_spoof_history(owner_id: str) -> dict:
    """Return training stats and real spoof sample count for an owner."""
    profile_path = auth.anti_spoof._profile_path(owner_id)
    if not profile_path.exists():
        raise HTTPException(status_code=404, detail=f"Chưa có profile anti-spoof cho owner: {owner_id}")

    import json as _json
    profile = _json.loads(profile_path.read_text(encoding="utf-8"))
    training_stats = profile.get("training_stats", {})
    real_spoof_count = auth.anti_spoof.real_spoof_sample_count(owner_id)
    effective_threshold = auth.anti_spoof._effective_threshold(owner_id=owner_id)

    return {
        "status": "ok",
        "owner_id": owner_id,
        "training_stats": training_stats,
        "total_real_spoof_samples": real_spoof_count,
        "anti_spoof_threshold_configured": auth.anti_spoof.threshold,
        "anti_spoof_threshold_effective": effective_threshold,
        "bonafide_mean": profile.get("bonafide_mean"),
        "bonafide_std": profile.get("bonafide_std"),
        "spoof_mean": profile.get("spoof_mean"),
        "spoof_std": profile.get("spoof_std"),
    }


# ==================== ADMIN: Sample Details & Delete ====================

@app.get("/api/voice-profiles/{owner_id}/samples")
def list_owner_samples(owner_id: str) -> dict:
    """Return detailed list of voice samples for an owner."""
    owner_dir = VOICEPRINT_DIR / owner_id
    if not owner_dir.exists() or not owner_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Owner '{owner_id}' không tồn tại.")

    samples = []
    for f in sorted(owner_dir.glob("sample_*.npy")):
        stat = f.stat()
        samples.append({
            "filename": f.name,
            "size_bytes": stat.st_size,
            "created_at": datetime.fromtimestamp(stat.st_ctime).isoformat(),
            "modified_at": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        })

    calibration_file = VOICEPRINT_DIR / f"{owner_id}_calibration.json"
    meta_file = owner_dir / "metadata.json"
    metadata = None
    if meta_file.exists():
        metadata = json.loads(meta_file.read_text(encoding="utf-8"))

    return {
        "owner_id": owner_id,
        "sample_count": len(samples),
        "samples": samples,
        "calibrated": calibration_file.exists(),
        "metadata": metadata,
    }


@app.delete("/api/voice-profiles/{owner_id}/samples/{filename}")
def delete_owner_sample(owner_id: str, filename: str) -> dict:
    """Delete a single voice sample file."""
    # Validate filename to prevent path traversal
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="Tên file không hợp lệ.")
    if not filename.startswith("sample_") or not filename.endswith(".npy"):
        raise HTTPException(status_code=400, detail="Chỉ xóa được file sample_*.npy.")

    owner_dir = VOICEPRINT_DIR / owner_id
    file_path = owner_dir / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail=f"File '{filename}' không tồn tại.")

    file_path.unlink()

    # Rebuild merged embedding after deleting sample
    remaining = list(owner_dir.glob("sample_*.npy"))
    if remaining:
        templates = np.stack([np.load(p).astype(np.float32).reshape(-1) for p in remaining], axis=0)
        merged = np.mean(templates, axis=0).astype(np.float32)
        merged = merged / (np.linalg.norm(merged) + 1e-8)
        np.save(owner_dir / "merged.npy", merged)
        meta = {"num_samples": len(remaining), "embedding_dim": int(merged.shape[0])}
        (owner_dir / "metadata.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        # No samples left, clean up merged + metadata
        for cleanup in [owner_dir / "merged.npy", owner_dir / "metadata.json"]:
            if cleanup.exists():
                cleanup.unlink()

    return {
        "status": "ok",
        "message": f"Đã xóa '{filename}' của {owner_id}",
        "remaining_samples": len(remaining) if remaining else 0,
    }


@app.delete("/api/voice-profiles/{owner_id}")
def delete_owner_profile(owner_id: str) -> dict:
    """Delete entire voice profile for an owner."""
    owner_dir = VOICEPRINT_DIR / owner_id
    if not owner_dir.exists():
        raise HTTPException(status_code=404, detail=f"Owner '{owner_id}' không tồn tại.")

    shutil.rmtree(owner_dir)

    # Also remove calibration file if exists
    cal_file = VOICEPRINT_DIR / f"{owner_id}_calibration.json"
    if cal_file.exists():
        cal_file.unlink()

    # Also remove anti-spoof profile if exists
    for ext in [".json", "_rawnet2.pt"]:
        asp = VOICEPRINT_DIR / "anti_spoof_profiles" / f"{owner_id}{ext}"
        if asp.exists():
            asp.unlink()

    return {
        "status": "ok",
        "message": f"Đã xóa toàn bộ hồ sơ giọng nói của '{owner_id}'",
    }
