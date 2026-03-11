from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from anti_spoof_layer import AntiSpoofDetector
from enrollment_features import EnrollmentService
from speaker_identity_layer import SpeakerVerifier


@dataclass
class VerificationResult:
    anti_spoof_score: float
    similarity_score: float
    fusion_score: float
    snr_db: float
    is_bonafide: bool
    is_owner: bool
    is_valid: bool
    message: str


class TwoLayerVoiceAuthenticator:
    def __init__(
        self,
        voiceprint_dir: str = "voiceprints",
        speaker_threshold: float = 0.68,
        anti_spoof_threshold: float = 0.62,
        voiceprint_ext: str = ".npz",
        fusion_threshold: float = 0.64,
    ):
        self.enrollment = EnrollmentService(voiceprint_dir=voiceprint_dir)
        self.anti_spoof = AntiSpoofDetector(threshold=anti_spoof_threshold)
        self.verifier = SpeakerVerifier(threshold=speaker_threshold)
        self.voiceprint_ext = voiceprint_ext
        self.voiceprint_dir = Path(voiceprint_dir)
        self.voiceprint_dir.mkdir(parents=True, exist_ok=True)
        self.fusion_threshold = fusion_threshold
        self.auto_update_similarity_threshold = 0.85
        self.auto_update_anti_spoof_threshold = 0.80

    def _ensure_voiceprint_dir(self) -> None:
        self.voiceprint_dir.mkdir(parents=True, exist_ok=True)

    def _calibration_path(self, owner_id: str) -> Path:
        return self.voiceprint_dir / f"{owner_id}_calibration.json"

    def _load_calibration(self, owner_id: str) -> dict | None:
        self._ensure_voiceprint_dir()
        path = self._calibration_path(owner_id)
        if not path.exists():
            return None
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)

    def _save_calibration(self, owner_id: str, calibration: dict) -> None:
        self._ensure_voiceprint_dir()
        path = self._calibration_path(owner_id)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(calibration, f, ensure_ascii=False, indent=2)

    def enroll_from_audios(self, owner_id: str, raw_audios: list[np.ndarray]):
        result = self.enrollment.enroll_from_audios(
            owner_id=owner_id,
            raw_audios=raw_audios,
            ext=self.voiceprint_ext,
        )
        self.anti_spoof.fit_owner_profile(owner_id=owner_id, bonafide_audios=result.anti_spoof_audios)
        print("[ENROLL] Mobile enroll hoàn tất.")

    def retrain_anti_spoof(self, owner_id: str, real_spoof_audios: list[np.ndarray]) -> dict:
        """Retrain anti-spoof model using real bonafide audio + new real spoof samples."""
        owner_dir = self.voiceprint_dir / owner_id
        if not owner_dir.exists():
            raise FileNotFoundError(f"Chưa có gallery bonafide cho owner: {owner_id}. Hãy enroll trước.")

        # Load real bonafide audio saved during enroll/train
        bonafide_waves = self.enrollment.store.load_bonafide_audios(owner_id)
        num_real_bonafide = len(bonafide_waves)

        if num_real_bonafide < 2:
            raise ValueError(
                f"Cần ít nhất 2 mẫu bonafide audio để retrain anti-spoof "
                f"(hiện có {num_real_bonafide}). "
                f"Hãy enroll lại hoặc thêm mẫu qua Training để hệ thống lưu audio thật."
            )

        print(f"[ANTI-SPOOF] Retrain cho {owner_id} với {num_real_bonafide} mẫu bonafide thật")

        train_result = self.anti_spoof.fit_owner_profile(
            owner_id=owner_id,
            bonafide_audios=bonafide_waves,
            real_spoof_audios=real_spoof_audios,
            save_real_spoof=True,
        )
        print(f"[ANTI-SPOOF] Retrain hoàn tất cho {owner_id}: {train_result}")
        return train_result

    def verify_from_audio(self, owner_id: str, raw_audio: np.ndarray) -> VerificationResult:
        templates, _ = self.enrollment.store.load(owner_id=owner_id, ext=self.voiceprint_ext)

        calibration = self._load_calibration(owner_id)
        if calibration is not None:
            self.verifier.threshold = float(calibration.get("speaker_threshold", self.verifier.threshold))
            self.anti_spoof.threshold = float(calibration.get("anti_spoof_threshold", self.anti_spoof.threshold))
            self.fusion_threshold = float(calibration.get("fusion_threshold", self.fusion_threshold))

        audio, probe_embedding = self.enrollment.capture_probe_audio_and_embedding_from_audio(raw_audio)

        is_bonafide, anti_spoof_score = self.anti_spoof.is_bonafide(audio, owner_id=owner_id)
        is_owner, similarity_score = self.verifier.verify(probe_embedding, templates, strategy="centroid")
        anti_hard_floor = self.anti_spoof.hard_reject_threshold(owner_id=owner_id)

        snr_db = self.enrollment.estimate_snr_db(audio)
        sim_weight = 0.65 if snr_db >= 14.0 else 0.55
        anti_weight = 1.0 - sim_weight
        fusion_score = sim_weight * similarity_score + anti_weight * anti_spoof_score
        anti_pass = anti_spoof_score >= anti_hard_floor
        is_valid = is_owner and anti_pass and fusion_score >= self.fusion_threshold

        if is_valid:
            message = "HỢP LỆ: Chủ nhà + Giọng thật"
        elif anti_spoof_score < anti_hard_floor:
            message = "CẢNH BÁO: Nghi ngờ replay attack (loa phát lại)"
        elif similarity_score < self.verifier.threshold:
            message = "CẢNH BÁO: Không khớp voiceprint chủ nhà"
        else:
            message = "CẢNH BÁO: Điểm fusion chưa đạt ngưỡng an toàn"

        if is_valid and similarity_score > self.auto_update_similarity_threshold and anti_spoof_score > self.auto_update_anti_spoof_threshold:
            updated, update_msg = self.enrollment.try_incremental_update(
                owner_id=owner_id,
                embedding=probe_embedding,
                processed_audio=audio,
                anti_spoof_score=anti_spoof_score,
                min_anti_spoof_score=self.auto_update_anti_spoof_threshold,
                ext=self.voiceprint_ext,
            )
            if updated:
                print(f"[GALLERY] {update_msg}")
            else:
                print(f"[GALLERY] Bỏ qua auto-update: {update_msg}")

        return VerificationResult(
            anti_spoof_score=anti_spoof_score,
            similarity_score=similarity_score,
            fusion_score=fusion_score,
            snr_db=snr_db,
            is_bonafide=is_bonafide,
            is_owner=is_owner,
            is_valid=is_valid,
            message=message,
        )

    def calibrate_owner_from_audios(self, owner_id: str, raw_audios: list[np.ndarray]) -> dict:
        templates, _ = self.enrollment.store.load(owner_id=owner_id, ext=self.voiceprint_ext)
        if len(raw_audios) < 1:
            raise ValueError("Cần ít nhất 1 mẫu audio để calibrate.")

        sim_scores = []
        anti_scores = []
        fusion_scores = []

        for raw in raw_audios:
            audio, probe_embedding = self.enrollment.capture_probe_audio_and_embedding_from_audio(raw)
            _, anti_score = self.anti_spoof.is_bonafide(audio, owner_id=owner_id)
            _, sim_score = self.verifier.verify(probe_embedding, templates, strategy="centroid")
            fusion_score = 0.7 * sim_score + 0.3 * anti_score
            sim_scores.append(sim_score)
            anti_scores.append(anti_score)
            fusion_scores.append(fusion_score)

        sim_arr = np.array(sim_scores, dtype=np.float32)
        anti_arr = np.array(anti_scores, dtype=np.float32)
        fusion_arr = np.array(fusion_scores, dtype=np.float32)

        calibration = {
            "speaker_threshold": float(np.clip(np.mean(sim_arr) - 2.0 * np.std(sim_arr), 0.45, 0.95)),
            "anti_spoof_threshold": float(np.clip(np.mean(anti_arr) - 2.0 * np.std(anti_arr), 0.35, 0.95)),
            "fusion_threshold": float(np.clip(np.mean(fusion_arr) - 2.0 * np.std(fusion_arr), 0.45, 0.95)),
            "trials": len(raw_audios),
            "source": "mobile_upload",
        }

        self._save_calibration(owner_id, calibration)
        self.verifier.threshold = calibration["speaker_threshold"]
        self.anti_spoof.threshold = calibration["anti_spoof_threshold"]
        self.fusion_threshold = calibration["fusion_threshold"]
        return calibration
