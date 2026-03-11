from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import time

import numpy as np
import torch
from speechbrain.inference.speaker import EncoderClassifier


@dataclass
class EnrollmentResult:
    template_embeddings: np.ndarray
    merged_embedding: np.ndarray
    processed_audios: list[np.ndarray]
    anti_spoof_audios: list[np.ndarray]


class AudioPreprocessor:
    def __init__(self, sample_rate: int = 16000):
        self.sample_rate = sample_rate
        self.calibrated_noise_floor_rms: float | None = None

    def set_noise_floor(self, noise_floor_rms: float) -> None:
        self.calibrated_noise_floor_rms = float(max(noise_floor_rms, 1e-6))

    @staticmethod
    def _rms(audio: np.ndarray) -> float:
        return float(np.sqrt(np.mean(np.square(audio), dtype=np.float64) + 1e-12))

    def spectral_subtraction(self, audio: np.ndarray, noise_sec: float = 0.3, n_fft: int = 512, hop: int = 160) -> np.ndarray:
        signal = np.squeeze(audio).astype(np.float32)
        if len(signal) < n_fft:
            return signal

        frames = []
        for start in range(0, len(signal) - n_fft + 1, hop):
            frame = signal[start : start + n_fft] * np.hanning(n_fft)
            frames.append(np.fft.rfft(frame))
        spec = np.array(frames)

        mag = np.abs(spec)
        phase = np.angle(spec)

        noise_frames = max(1, int((noise_sec * self.sample_rate - n_fft) / hop) + 1)
        noise_profile = np.mean(mag[:noise_frames], axis=0)

        oversub = 1.35
        floor = 0.08
        denoised_mag = np.maximum(mag - oversub * noise_profile[None, :], floor * noise_profile[None, :])
        denoised_spec = denoised_mag * np.exp(1j * phase)

        out = np.zeros(len(signal), dtype=np.float32)
        weight = np.zeros(len(signal), dtype=np.float32)
        idx = 0
        window = np.hanning(n_fft).astype(np.float32)
        for start in range(0, len(signal) - n_fft + 1, hop):
            frame_time = np.fft.irfft(denoised_spec[idx], n=n_fft).astype(np.float32)
            out[start : start + n_fft] += frame_time * window
            weight[start : start + n_fft] += window + 1e-8
            idx += 1

        valid = weight > 1e-8
        out[valid] /= weight[valid]
        out = np.clip(out, -1.0, 1.0)
        return self._bandpass_fft(out, low_hz=90.0, high_hz=7600.0)

    def _bandpass_fft(self, audio: np.ndarray, low_hz: float, high_hz: float) -> np.ndarray:
        signal = np.squeeze(audio).astype(np.float32)
        n = len(signal)
        if n == 0:
            return signal
        spectrum = np.fft.rfft(signal)
        freqs = np.fft.rfftfreq(n, d=1.0 / self.sample_rate)
        mask = (freqs >= low_hz) & (freqs <= high_hz)
        spectrum[~mask] = 0
        filtered = np.fft.irfft(spectrum, n=n).astype(np.float32)
        return np.clip(filtered, -1.0, 1.0)

    def normalize_loudness_ebu(self, audio: np.ndarray, target_lufs: float = -23.0) -> np.ndarray:
        signal = np.squeeze(audio).astype(np.float32)
        current_rms = self._rms(signal)
        current_lufs = 20.0 * np.log10(current_rms + 1e-9)
        gain_db = target_lufs - current_lufs
        gain_db = float(np.clip(gain_db, -12.0, 20.0))
        gain = float(10 ** (gain_db / 20.0))
        normalized = np.clip(signal * gain, -1.0, 1.0)
        return normalized.astype(np.float32)

    def trim_silence_dynamic(
        self,
        audio: np.ndarray,
        frame_ms: int = 25,
        hop_ms: int = 10,
        speech_margin_db: float = 12.0,
        pad_ms: int = 120,
    ) -> np.ndarray:
        signal = np.squeeze(audio).astype(np.float32)
        if signal.ndim != 1 or len(signal) == 0:
            return signal

        frame_len = max(1, int(self.sample_rate * frame_ms / 1000))
        hop_len = max(1, int(self.sample_rate * hop_ms / 1000))
        if len(signal) < frame_len:
            return signal

        rms_values = []
        starts = []
        for start in range(0, len(signal) - frame_len + 1, hop_len):
            frame = signal[start : start + frame_len]
            rms_values.append(self._rms(frame))
            starts.append(start)

        rms_arr = np.array(rms_values, dtype=np.float32)
        if rms_arr.size == 0:
            return signal

        frame_noise_floor = float(np.percentile(rms_arr, 25))
        if self.calibrated_noise_floor_rms is not None:
            noise_floor = max(float(self.calibrated_noise_floor_rms), frame_noise_floor)
        else:
            noise_floor = frame_noise_floor
        noise_floor = max(noise_floor, 0.0010)
        adaptive_margin_db = 8.0 if noise_floor < 0.0025 else speech_margin_db
        dynamic_threshold = noise_floor * (10 ** (adaptive_margin_db / 20.0))
        dynamic_threshold = max(dynamic_threshold, 0.0015)

        voiced = rms_arr >= dynamic_threshold
        if not np.any(voiced):
            print(
                "[VAD] Không có đoạn nào vượt ngưỡng speech từ noise floor. "
                f"(noise_floor={noise_floor:.6f}, threshold={dynamic_threshold:.6f}, margin={adaptive_margin_db:.1f}dB)"
            )
            return np.array([], dtype=np.float32)

        pad_samples = int(self.sample_rate * pad_ms / 1000)
        keep_mask = np.zeros(len(signal), dtype=bool)
        voiced_indices = np.where(voiced)[0]
        for idx in voiced_indices:
            start_sample = max(0, starts[idx] - pad_samples)
            end_sample = min(len(signal), starts[idx] + frame_len + pad_samples)
            keep_mask[start_sample:end_sample] = True

        trimmed = signal[keep_mask]
        voiced_ratio = float(np.mean(voiced))
        if voiced_ratio < 0.08:
            print(f"[VAD] Tỷ lệ khung thoại quá thấp ({voiced_ratio:.3f}).")
            return np.array([], dtype=np.float32)
        if len(trimmed) < int(0.5 * self.sample_rate):
            print("[VAD] Đoạn sau lọc quá ngắn và không đủ dữ liệu thoại hợp lệ.")
            return np.array([], dtype=np.float32)
        return trimmed.astype(np.float32)

    def process(self, audio: np.ndarray) -> np.ndarray:
        denoised = self.spectral_subtraction(audio)
        trimmed = self.trim_silence_dynamic(denoised)
        if len(trimmed) == 0:
            raise RuntimeError("Không phát hiện giọng nói vượt ngưỡng Noise Floor. Vui lòng nói to/rõ hơn.")
        normalized = self.normalize_loudness_ebu(trimmed)
        return normalized.astype(np.float32)

    def process_for_anti_spoof(self, audio: np.ndarray) -> np.ndarray:
        denoised = self.spectral_subtraction(audio)
        trimmed = self.trim_silence_dynamic(denoised)
        if len(trimmed) == 0:
            raise RuntimeError("Không có tín hiệu thoại hợp lệ cho anti-spoof.")
        trimmed = trimmed - float(np.mean(trimmed))
        peak = float(np.max(np.abs(trimmed)) + 1e-8)
        scaled = np.clip(trimmed / peak, -1.0, 1.0)
        return scaled.astype(np.float32)


class ECAPAEmbeddingExtractor:
    def __init__(self, model_cache_dir: str = "pretrained_models"):
        self.classifier = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            savedir=model_cache_dir,
        )

    def extract_embedding(self, audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
        if sample_rate != 16000:
            raise ValueError("ECAPA-TDNN yêu cầu sample_rate=16000.")
        signal = np.squeeze(audio).astype(np.float32)
        if signal.ndim != 1:
            raise ValueError("Audio đầu vào phải là mono 1 chiều.")
        if len(signal) < int(0.4 * sample_rate):
            raise ValueError("Audio sau tiền xử lý quá ngắn để trích embedding.")

        tensor = torch.from_numpy(signal).unsqueeze(0)
        with torch.no_grad():
            embedding = self.classifier.encode_batch(tensor)
        return embedding.squeeze().cpu().numpy().astype(np.float32)


class VoiceprintStore:
    def __init__(self, base_dir: str = "voiceprints"):
        self.base_dir = Path(base_dir)
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self.max_samples = None

    def _owner_dir(self, owner_id: str) -> Path:
        return self.base_dir / owner_id

    def _sample_files(self, owner_id: str) -> list[Path]:
        owner_dir = self._owner_dir(owner_id)
        if not owner_dir.exists():
            return []
        return sorted(owner_dir.glob("sample_*.npy"))

    def _legacy_path(self, owner_id: str, ext: str = ".npz") -> Path:
        normalized_ext = ext if ext.startswith(".") else f".{ext}"
        return self.base_dir / f"{owner_id}{normalized_ext}"

    def sample_count(self, owner_id: str) -> int:
        return len(self._sample_files(owner_id))

    def _bonafide_dir(self, owner_id: str) -> Path:
        """Directory to store raw bonafide audio for anti-spoof training."""
        d = self._owner_dir(owner_id) / "bonafide_audio"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def save_bonafide_audio(self, owner_id: str, audio: np.ndarray) -> str:
        """Save a bonafide (anti-spoof processed) audio as .npy, return filename."""
        bdir = self._bonafide_dir(owner_id)
        ts = int(time.time() * 1000)
        fname = f"bonafide_{ts}.npy"
        fpath = bdir / fname
        while fpath.exists():
            ts += 1
            fname = f"bonafide_{ts}.npy"
            fpath = bdir / fname
        np.save(fpath, np.squeeze(audio).astype(np.float32))
        return fname

    def load_bonafide_audios(self, owner_id: str) -> list[np.ndarray]:
        """Load all saved bonafide audio files for an owner."""
        bdir = self._bonafide_dir(owner_id)
        if not bdir.exists():
            return []
        files = sorted(bdir.glob("bonafide_*.npy"))
        return [np.load(f).astype(np.float32) for f in files]

    def bonafide_audio_count(self, owner_id: str) -> int:
        bdir = self._bonafide_dir(owner_id)
        if not bdir.exists():
            return 0
        return len(list(bdir.glob("bonafide_*.npy")))

    def clear_bonafide_audios(self, owner_id: str) -> None:
        """Remove all bonafide audio files (used when re-enrolling)."""
        bdir = self._bonafide_dir(owner_id)
        if bdir.exists():
            for f in bdir.glob("bonafide_*.npy"):
                f.unlink(missing_ok=True)

    def _save_metadata(self, owner_id: str, merged: np.ndarray) -> None:
        owner_dir = self._owner_dir(owner_id)
        owner_dir.mkdir(parents=True, exist_ok=True)
        metadata = {
            "num_samples": len(self._sample_files(owner_id)),
            "embedding_dim": int(merged.shape[0]),
            "max_samples": self.max_samples,
        }
        (owner_dir / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

    def save(self, owner_id: str, templates: np.ndarray, merged: np.ndarray, ext: str = ".npz") -> Path:
        templates = np.asarray(templates, dtype=np.float32)
        if templates.ndim == 1:
            templates = templates[None, :]

        owner_dir = self._owner_dir(owner_id)
        owner_dir.mkdir(parents=True, exist_ok=True)

        for old_file in owner_dir.glob("sample_*.npy"):
            old_file.unlink(missing_ok=True)

        for idx, template in enumerate(templates, start=1):
            np.save(owner_dir / f"sample_{idx:04d}.npy", template.astype(np.float32))

        merged_norm = np.asarray(merged, dtype=np.float32)
        np.save(owner_dir / "merged.npy", merged_norm)
        self._save_metadata(owner_id, merged_norm)

        print(f"[STORE] Đã lưu gallery voiceprint tại: {owner_dir}")
        return owner_dir

    def append_template(self, owner_id: str, embedding: np.ndarray) -> tuple[bool, str, str | None, int | None]:
        emb = np.asarray(embedding, dtype=np.float32).reshape(-1)
        owner_dir = self._owner_dir(owner_id)
        owner_dir.mkdir(parents=True, exist_ok=True)

        sample_files = self._sample_files(owner_id)
        existing = []
        for path in sample_files:
            existing.append(np.load(path).astype(np.float32).reshape(-1))

        if existing:
            sims = []
            for tpl in existing:
                sim = float(np.dot(emb, tpl) / ((np.linalg.norm(emb) * np.linalg.norm(tpl)) + 1e-8))
                sims.append(sim)
            if max(sims) > 0.997:
                return False, "Mẫu mới quá trùng lặp, bỏ qua cập nhật.", None, None

        timestamp_ms = int(time.time() * 1000)
        new_path = owner_dir / f"sample_{timestamp_ms}.npy"
        while new_path.exists():
            timestamp_ms += 1
            new_path = owner_dir / f"sample_{timestamp_ms}.npy"
        np.save(new_path, emb)

        templates, merged = self.load(owner_id=owner_id, ext=".npz")
        np.save(owner_dir / "merged.npy", merged)
        self._save_metadata(owner_id, merged)
        return True, "Đã thêm mẫu mới vào template gallery.", new_path.name, timestamp_ms

    def load(self, owner_id: str, ext: str = ".npz") -> tuple[np.ndarray, np.ndarray]:
        owner_dir = self._owner_dir(owner_id)
        sample_files = self._sample_files(owner_id)
        if sample_files:
            templates = np.stack([np.load(path).astype(np.float32).reshape(-1) for path in sample_files], axis=0)
            merged = np.mean(templates, axis=0).astype(np.float32)
            merged = merged / (np.linalg.norm(merged) + 1e-8)
            return templates, merged

        legacy_path = self._legacy_path(owner_id, ext)
        if not legacy_path.exists():
            raise FileNotFoundError(f"Không tìm thấy voiceprint gallery hoặc file cũ cho owner: {owner_id}")

        suffix = legacy_path.suffix.lower()
        if suffix == ".pt":
            data = torch.load(legacy_path, map_location="cpu")
            templates = np.asarray(data.get("templates", data.get("merged")), dtype=np.float32)
            if templates.ndim == 1:
                templates = templates[None, :]
        elif suffix == ".npy":
            merged = np.load(legacy_path).astype(np.float32)
            templates = merged[None, :]
        else:
            data = np.load(legacy_path)
            templates = np.asarray(data.get("templates", data.get("merged")), dtype=np.float32)
            if templates.ndim == 1:
                templates = templates[None, :]

        merged = np.mean(templates, axis=0).astype(np.float32)
        merged = merged / (np.linalg.norm(merged) + 1e-8)
        self.save(owner_id=owner_id, templates=templates, merged=merged, ext=ext)
        return templates, merged


class EnrollmentService:
    def __init__(self, voiceprint_dir: str = "voiceprints"):
        self.sample_rate = 16000
        self.extractor = ECAPAEmbeddingExtractor()
        self.store = VoiceprintStore(base_dir=voiceprint_dir)
        self.preprocessor = AudioPreprocessor(sample_rate=self.sample_rate)
        self.enroll_takes = 3
        self.noise_floor_path = Path(voiceprint_dir) / "noise_floor.json"
        self.noise_floor_measured_this_session = False
        self._load_noise_floor_if_exists()
        self.incremental_min_snr_db = 12.0

    def _ensure_voiceprint_dir(self) -> None:
        self.store.base_dir.mkdir(parents=True, exist_ok=True)

    def _prepare_uploaded_audio(self, audio: np.ndarray) -> np.ndarray:
        signal = np.asarray(audio, dtype=np.float32)
        if signal.ndim == 2:
            signal = np.mean(signal, axis=1)
        signal = np.squeeze(signal)
        if signal.ndim != 1 or len(signal) == 0:
            raise ValueError("Audio upload không hợp lệ.")

        peak = float(np.max(np.abs(signal)) + 1e-8)
        if peak > 1.5:
            signal = signal / 32768.0
        signal = np.clip(signal, -1.0, 1.0)
        return signal.astype(np.float32)

    def _extract_multi_view_embedding(self, processed_audio: np.ndarray) -> np.ndarray:
        signal = np.squeeze(processed_audio).astype(np.float32)
        sr = self.sample_rate
        win = int(1.2 * sr)
        hop = int(0.6 * sr)

        if len(signal) < win:
            emb = self.extractor.extract_embedding(signal, sample_rate=sr)
            return self._l2_normalize(emb)

        embeddings = []
        for start in range(0, len(signal) - win + 1, hop):
            chunk = signal[start : start + win]
            emb = self.extractor.extract_embedding(chunk, sample_rate=sr)
            embeddings.append(self._l2_normalize(emb))
            if len(embeddings) >= 5:
                break

        if not embeddings:
            emb = self.extractor.extract_embedding(signal, sample_rate=sr)
            return self._l2_normalize(emb)

        merged = np.mean(np.stack(embeddings, axis=0), axis=0).astype(np.float32)
        return self._l2_normalize(merged)

    def _load_noise_floor_if_exists(self) -> None:
        self._ensure_voiceprint_dir()
        if not self.noise_floor_path.exists():
            return
        try:
            data = json.loads(self.noise_floor_path.read_text(encoding="utf-8"))
            noise_floor = float(data.get("noise_floor_rms", 0.0))
            if noise_floor > 0:
                self.preprocessor.set_noise_floor(noise_floor)
                print(f"[NOISE] Đã nạp Noise Floor: {noise_floor:.6f}")
        except Exception:
            pass

    def calibrate_noise_floor_from_audio(self, ambient_audio: np.ndarray, ambient_sec: float = 5.0) -> float:
        self._ensure_voiceprint_dir()
        ambient_audio = self._prepare_uploaded_audio(ambient_audio)
        frame_len = int(0.05 * self.sample_rate)
        hop = int(0.025 * self.sample_rate)
        frame_rms = []
        for start in range(0, max(1, len(ambient_audio) - frame_len + 1), hop):
            frame = ambient_audio[start : start + frame_len]
            if len(frame) < frame_len:
                break
            frame_rms.append(float(np.sqrt(np.mean(np.square(frame), dtype=np.float64) + 1e-12)))

        if frame_rms:
            noise_rms = float(np.percentile(np.array(frame_rms, dtype=np.float32), 60))
        else:
            noise_rms = float(np.sqrt(np.mean(np.square(ambient_audio), dtype=np.float64) + 1e-12))

        noise_rms = max(noise_rms, 1e-6)
        self.preprocessor.set_noise_floor(noise_rms)
        self.noise_floor_measured_this_session = True
        payload = {
            "noise_floor_rms": noise_rms,
            "ambient_sec": ambient_sec,
            "sample_rate": self.sample_rate,
            "source": "mobile_upload",
        }
        self.noise_floor_path.parent.mkdir(parents=True, exist_ok=True)
        self.noise_floor_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[NOISE] Noise Floor (upload) đã lưu: {noise_rms:.6f}")
        return noise_rms

    @staticmethod
    def _l2_normalize(embedding: np.ndarray) -> np.ndarray:
        norm = np.linalg.norm(embedding) + 1e-8
        return (embedding / norm).astype(np.float32)

    def capture_probe_audio_and_embedding_from_audio(self, raw_audio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        prepared = self._prepare_uploaded_audio(raw_audio)
        processed_audio = self.preprocessor.process(prepared)
        anti_spoof_audio = self.preprocessor.process_for_anti_spoof(prepared)
        embedding = self._extract_multi_view_embedding(processed_audio)
        return anti_spoof_audio, embedding

    def enroll_from_audios(
        self,
        owner_id: str,
        raw_audios: list[np.ndarray],
        ext: str = ".npz",
    ) -> EnrollmentResult:
        if len(raw_audios) < self.enroll_takes:
            raise ValueError(f"Cần ít nhất {self.enroll_takes} mẫu audio để enroll.")

        embeddings = []
        processed_audios = []
        anti_spoof_audios = []

        print(f"[ENROLL] Mobile enroll cho: {owner_id} với {len(raw_audios)} mẫu")
        for idx, raw in enumerate(raw_audios[: self.enroll_takes], start=1):
            prepared = self._prepare_uploaded_audio(raw)
            processed_audio = self.preprocessor.process(prepared)
            anti_spoof_audio = self.preprocessor.process_for_anti_spoof(prepared)
            embedding = self._extract_multi_view_embedding(processed_audio)
            embeddings.append(embedding)
            processed_audios.append(processed_audio)
            anti_spoof_audios.append(anti_spoof_audio)
            print(f"[ENROLL] Đã xử lý mẫu upload {idx}/{self.enroll_takes}")

        templates = np.stack(embeddings, axis=0).astype(np.float32)
        merged = self._l2_normalize(np.mean(templates, axis=0).astype(np.float32))
        self.store.save(owner_id=owner_id, templates=templates, merged=merged, ext=ext)

        # Save raw bonafide audio for anti-spoof training (clear old ones on re-enroll)
        self.store.clear_bonafide_audios(owner_id)
        for idx, asp_audio in enumerate(anti_spoof_audios, start=1):
            self.store.save_bonafide_audio(owner_id, asp_audio)
            print(f"[ENROLL] Saved bonafide audio {idx}/{len(anti_spoof_audios)} for anti-spoof")

        return EnrollmentResult(
            template_embeddings=templates,
            merged_embedding=merged,
            processed_audios=processed_audios,
            anti_spoof_audios=anti_spoof_audios,
        )

    def train_from_audio(self, owner_id: str, raw_audio: np.ndarray) -> dict:
        prepared = self._prepare_uploaded_audio(raw_audio)
        processed_audio = self.preprocessor.process(prepared)
        anti_spoof_audio = self.preprocessor.process_for_anti_spoof(prepared)
        snr_db = self.estimate_snr_db(anti_spoof_audio)
        if snr_db < 10.0:
            raise RuntimeError("Môi trường quá ồn, mẫu này không đủ chất lượng để học")
        embedding = self._extract_multi_view_embedding(processed_audio)

        success, msg, sample_file, sample_timestamp_ms = self.store.append_template(owner_id=owner_id, embedding=embedding)
        if not success:
            raise RuntimeError(msg)

        # Also save bonafide audio for anti-spoof training
        self.store.save_bonafide_audio(owner_id, anti_spoof_audio)
        print(f"[TRAIN] Saved bonafide audio for anti-spoof (total: {self.store.bonafide_audio_count(owner_id)})")

        self.store.load(owner_id=owner_id, ext=".npz")
        return {
            "status": "ok",
            "message": msg,
            "gallery_samples": self.store.sample_count(owner_id),
            "processed_seconds": round(len(processed_audio) / float(self.sample_rate), 3),
            "anti_spoof_seconds": round(len(anti_spoof_audio) / float(self.sample_rate), 3),
            "snr_db": round(snr_db, 3),
            "stored_sample_file": sample_file,
            "stored_sample_timestamp_ms": sample_timestamp_ms,
        }

    def estimate_snr_db(self, audio: np.ndarray) -> float:
        signal = np.squeeze(audio).astype(np.float32)
        signal_rms = float(np.sqrt(np.mean(np.square(signal), dtype=np.float64) + 1e-12))
        noise_rms = float(self.preprocessor.calibrated_noise_floor_rms or 1e-6)
        return float(20.0 * np.log10((signal_rms + 1e-9) / (noise_rms + 1e-9)))

    def try_incremental_update(
        self,
        owner_id: str,
        embedding: np.ndarray,
        processed_audio: np.ndarray,
        anti_spoof_score: float,
        min_anti_spoof_score: float,
        ext: str = ".npz",
    ) -> tuple[bool, str]:
        snr_db = self.estimate_snr_db(processed_audio)
        if snr_db < self.incremental_min_snr_db:
            return False, f"SNR thấp ({snr_db:.2f} dB), không cập nhật gallery."
        if anti_spoof_score < min_anti_spoof_score:
            return False, f"Anti-spoof thấp ({anti_spoof_score:.3f}), không cập nhật gallery."

        success, msg, _, _ = self.store.append_template(owner_id=owner_id, embedding=embedding)
        if success:
            return True, f"{msg} (SNR={snr_db:.2f} dB, anti-spoof={anti_spoof_score:.3f})"
        return False, msg
