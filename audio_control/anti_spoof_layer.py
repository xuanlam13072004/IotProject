from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Optional

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim


class RawNet2Block(nn.Module):
    def __init__(self, in_ch: int, out_ch: int, stride: int = 1):
        super().__init__()
        self.conv1 = nn.Conv1d(in_ch, out_ch, kernel_size=3, stride=stride, padding=1)
        self.bn1 = nn.BatchNorm1d(out_ch)
        self.conv2 = nn.Conv1d(out_ch, out_ch, kernel_size=3, padding=1)
        self.bn2 = nn.BatchNorm1d(out_ch)
        self.shortcut = None
        if stride != 1 or in_ch != out_ch:
            self.shortcut = nn.Sequential(
                nn.Conv1d(in_ch, out_ch, kernel_size=1, stride=stride),
                nn.BatchNorm1d(out_ch),
            )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        residual = x
        out = torch.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        if self.shortcut is not None:
            residual = self.shortcut(residual)
        out = torch.relu(out + residual)
        return out


class RawNet2AntiSpoof(nn.Module):
    def __init__(self):
        super().__init__()
        self.front = nn.Sequential(
            nn.Conv1d(1, 24, kernel_size=5, stride=2, padding=2),
            nn.BatchNorm1d(24),
            nn.ReLU(),
        )
        self.res = nn.Sequential(
            RawNet2Block(24, 48, stride=2),
            RawNet2Block(48, 48, stride=1),
            RawNet2Block(48, 96, stride=2),
            RawNet2Block(96, 96, stride=1),
            RawNet2Block(96, 128, stride=2),
        )
        self.pool = nn.AdaptiveAvgPool1d(1)
        self.head = nn.Sequential(
            nn.Flatten(),
            nn.Linear(128, 48),
            nn.ReLU(),
            nn.Dropout(0.2),
            nn.Linear(48, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.front(x)
        x = self.res(x)
        x = self.pool(x)
        return self.head(x)


class AntiSpoofDetector:
    """RawNet2-style anti-spoof detector (bonafide vs replay/TTS-like)."""

    def __init__(self, threshold: float = 0.55, profile_dir: str = "voiceprints/anti_spoof_profiles"):
        self.threshold = threshold
        self.sample_rate = 16000
        self.target_len = self.sample_rate * 2
        self.profile_dir = Path(profile_dir)
        self.profile_dir.mkdir(parents=True, exist_ok=True)
        self.current_owner_id: Optional[str] = None
        self.device = torch.device("cpu")
        self.model = RawNet2AntiSpoof().to(self.device)
        torch.manual_seed(42)

    def _profile_path(self, owner_id: str) -> Path:
        return self.profile_dir / f"{owner_id}.json"

    def _weight_path(self, owner_id: str) -> Path:
        return self.profile_dir / f"{owner_id}_rawnet2.pt"

    def _real_spoof_dir(self, owner_id: str) -> Path:
        """Directory to persist real spoof samples for an owner."""
        d = self.profile_dir / f"{owner_id}_real_spoof"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _save_real_spoof_samples(self, owner_id: str, audios: list[np.ndarray]) -> list[str]:
        """Save real spoof audio arrays as .npy files and return filenames."""
        spoof_dir = self._real_spoof_dir(owner_id)
        saved_files: list[str] = []
        for audio in audios:
            ts = int(time.time() * 1000)
            fname = f"spoof_{ts}.npy"
            fpath = spoof_dir / fname
            while fpath.exists():
                ts += 1
                fname = f"spoof_{ts}.npy"
                fpath = spoof_dir / fname
            np.save(fpath, np.squeeze(audio).astype(np.float32))
            saved_files.append(fname)
        return saved_files

    def _load_real_spoof_samples(self, owner_id: str) -> list[np.ndarray]:
        """Load all previously saved real spoof samples for an owner."""
        spoof_dir = self._real_spoof_dir(owner_id)
        if not spoof_dir.exists():
            return []
        files = sorted(spoof_dir.glob("spoof_*.npy"))
        return [np.load(f).astype(np.float32) for f in files]

    def real_spoof_sample_count(self, owner_id: str) -> int:
        spoof_dir = self._real_spoof_dir(owner_id)
        if not spoof_dir.exists():
            return 0
        return len(list(spoof_dir.glob("spoof_*.npy")))

    def _prepare_wave(self, audio: np.ndarray) -> np.ndarray:
        x = np.squeeze(audio).astype(np.float32)
        if len(x) == 0:
            x = np.zeros(self.target_len, dtype=np.float32)
        if len(x) < self.target_len:
            x = np.pad(x, (0, self.target_len - len(x)))
        elif len(x) > self.target_len:
            x = x[: self.target_len]

        peak = np.max(np.abs(x)) + 1e-8
        x = x / peak
        return x.astype(np.float32)

    def _artifact_features(self, audio: np.ndarray) -> np.ndarray:
        x = self._prepare_wave(audio)
        n_fft = 512
        hop = 160
        if len(x) < n_fft:
            x = np.pad(x, (0, n_fft - len(x)))

        frames = []
        for start in range(0, len(x) - n_fft + 1, hop):
            frame = x[start : start + n_fft] * np.hanning(n_fft)
            frames.append(np.fft.rfft(frame))
        spec = np.array(frames)

        mag = np.abs(spec) + 1e-8
        logmag = np.log(mag)
        freqs = np.fft.rfftfreq(n_fft, d=1.0 / self.sample_rate)

        def band_energy(low: float, high: float) -> float:
            idx = (freqs >= low) & (freqs < high)
            if not np.any(idx):
                return 0.0
            return float(np.mean(mag[:, idx]))

        e_low = band_energy(80, 1000)
        e_mid = band_energy(1000, 3500)
        e_high = band_energy(3500, 7600)
        high_ratio = e_high / (e_low + e_mid + e_high + 1e-8)
        mid_ratio = e_mid / (e_low + e_mid + e_high + 1e-8)

        spectral_flatness = float(np.exp(np.mean(logmag)) / np.mean(mag))
        temporal_diff = float(np.mean(np.abs(np.diff(x))))
        zcr = float(np.mean(np.abs(np.diff(np.sign(x))) > 0))
        frame_var = float(np.std(np.mean(mag, axis=1)) / (np.mean(np.mean(mag, axis=1)) + 1e-8))

        return np.array([high_ratio, mid_ratio, spectral_flatness, temporal_diff, zcr, frame_var], dtype=np.float32)

    @staticmethod
    def _simulate_replay(audio: np.ndarray) -> np.ndarray:
        x = np.squeeze(audio).astype(np.float32)
        blur_kernel = np.array([0.15, 0.7, 0.15], dtype=np.float32)
        blurred = np.convolve(x, blur_kernel, mode="same")
        delayed = np.roll(blurred, 200) * 0.25
        hum = 0.005 * np.sin(np.linspace(0, 120 * np.pi, len(x), dtype=np.float32))
        y = np.clip(0.9 * blurred + delayed + hum, -1.0, 1.0)
        return y.astype(np.float32)

    def _simulate_phone_speaker(self, audio: np.ndarray) -> np.ndarray:
        x = np.squeeze(audio).astype(np.float32)
        n = len(x)
        spectrum = np.fft.rfft(x)
        freqs = np.fft.rfftfreq(n, d=1.0 / self.sample_rate)
        mask = (freqs >= 300.0) & (freqs <= 3400.0)
        spectrum[~mask] *= 0.05
        y = np.fft.irfft(spectrum, n=n).astype(np.float32)
        companded = np.tanh(1.8 * y)
        return np.clip(companded, -1.0, 1.0).astype(np.float32)

    @staticmethod
    def _simulate_tts_like(audio: np.ndarray) -> np.ndarray:
        x = np.squeeze(audio).astype(np.float32)
        q = np.round(x * 64.0) / 64.0
        env = np.convolve(np.abs(q), np.ones(80, dtype=np.float32) / 80.0, mode="same")
        y = np.clip(q * (0.7 + 0.3 * env), -1.0, 1.0)
        return y.astype(np.float32)

    def fit_owner_profile(self, owner_id: str, bonafide_audios: list[np.ndarray], real_spoof_audios: list[np.ndarray] | None = None, save_real_spoof: bool = True) -> dict:
        if len(bonafide_audios) < 2:
            raise ValueError("Cần ít nhất 2 mẫu bonafide để tạo hồ sơ anti-spoof.")

        # --- Persist new real spoof samples ---
        saved_spoof_files: list[str] = []
        if real_spoof_audios and save_real_spoof:
            saved_spoof_files = self._save_real_spoof_samples(owner_id, real_spoof_audios)

        # --- Load all accumulated real spoof samples ---
        all_real_spoof = self._load_real_spoof_samples(owner_id)

        bonafide = [self._prepare_wave(a) for a in bonafide_audios]
        replay = [self._prepare_wave(self._simulate_replay(a)) for a in bonafide_audios]
        tts_like = [self._prepare_wave(self._simulate_tts_like(a)) for a in bonafide_audios]
        phone_like = [self._prepare_wave(self._simulate_phone_speaker(a)) for a in bonafide_audios]

        # Real spoof samples (accumulated)
        real_spoof_prepared = [self._prepare_wave(a) for a in all_real_spoof]
        # Keep retraining balanced: too many spoof samples can collapse bonafide score.
        max_real_spoof = max(8, len(bonafide) * 2)
        if len(real_spoof_prepared) > max_real_spoof:
            real_spoof_prepared = real_spoof_prepared[-max_real_spoof:]

        x = np.stack(bonafide + replay + tts_like + phone_like + real_spoof_prepared, axis=0)
        y = np.concatenate(
            [
                np.ones(len(bonafide), dtype=np.float32),
                np.zeros(len(replay), dtype=np.float32),
                np.zeros(len(tts_like), dtype=np.float32),
                np.zeros(len(phone_like), dtype=np.float32),
                np.zeros(len(real_spoof_prepared), dtype=np.float32),
            ]
        )

        x_tensor = torch.from_numpy(x).unsqueeze(1).to(self.device)
        y_tensor = torch.from_numpy(y).unsqueeze(1).to(self.device)

        self.model = RawNet2AntiSpoof().to(self.device)
        self.model.train()

        # Correct class imbalance: spoof samples almost always outnumber bonafide
        # (3 simulated × bonafide + N real spoof vs. len(bonafide))
        # pos_weight = num_spoof / num_bonafide tells the loss to weight each
        # bonafide sample proportionally so the model doesn't bias toward spoof.
        num_bonafide = len(bonafide)
        num_spoof = len(x) - num_bonafide
        pos_weight_val = max(1.0, num_spoof / max(num_bonafide, 1))
        pos_weight_tensor = torch.tensor([pos_weight_val], dtype=torch.float32, device=self.device)
        criterion = nn.BCEWithLogitsLoss(pos_weight=pos_weight_tensor)
        optimizer = optim.Adam(self.model.parameters(), lr=8e-4)

        # More epochs when real spoof data is present
        epochs = 36 if real_spoof_prepared else 24
        for _ in range(epochs):
            optimizer.zero_grad()
            logits = self.model(x_tensor)
            loss = criterion(logits, y_tensor)
            loss.backward()
            optimizer.step()

        with torch.no_grad():
            probs = torch.sigmoid(self.model(x_tensor)).squeeze(1).cpu().numpy()

        bonafide_feat = np.stack([self._artifact_features(a) for a in bonafide], axis=0)
        spoof_feat = np.stack([self._artifact_features(a) for a in replay + tts_like + phone_like + real_spoof_prepared], axis=0)

        final_loss = float(loss.item())

        profile = {
            "owner_id": owner_id,
            "threshold": self.threshold,
            "bonafide_mean": float(np.mean(probs[: len(bonafide)])),
            "bonafide_std": float(np.std(probs[: len(bonafide)]) + 1e-6),
            "spoof_mean": float(np.mean(probs[len(bonafide) :])),
            "spoof_std": float(np.std(probs[len(bonafide) :]) + 1e-6),
            "feat_bona_mean": bonafide_feat.mean(axis=0).tolist(),
            "feat_bona_std": (bonafide_feat.std(axis=0) + 1e-6).tolist(),
            "feat_spoof_mean": spoof_feat.mean(axis=0).tolist(),
            "feat_spoof_std": (spoof_feat.std(axis=0) + 1e-6).tolist(),
            "training_stats": {
                "num_bonafide": len(bonafide),
                "num_spoof_simulated": len(replay) + len(tts_like) + len(phone_like),
                "num_spoof_real": len(real_spoof_prepared),
                "epochs": epochs,
                "final_loss": round(final_loss, 6),
                "trained_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            },
        }

        torch.save(self.model.state_dict(), self._weight_path(owner_id))
        self._profile_path(owner_id).write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8")
        self.current_owner_id = owner_id

        return {
            "num_bonafide": len(bonafide),
            "num_spoof_simulated": len(replay) + len(tts_like) + len(phone_like),
            "num_spoof_real": len(real_spoof_prepared),
            "num_spoof_real_new": len(saved_spoof_files),
            "saved_spoof_files": saved_spoof_files,
            "epochs": epochs,
            "final_loss": round(final_loss, 6),
        }

    def _load_owner_profile(self, owner_id: Optional[str]) -> Optional[dict]:
        if owner_id is None:
            owner_id = self.current_owner_id
        if owner_id is None:
            return None

        profile_path = self._profile_path(owner_id)
        weight_path = self._weight_path(owner_id)
        if not profile_path.exists() or not weight_path.exists():
            return None

        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        self.model = RawNet2AntiSpoof().to(self.device)
        self.model.load_state_dict(torch.load(weight_path, map_location=self.device))
        self.model.eval()
        self.current_owner_id = owner_id
        return profile

    def score_bonafide(self, audio: np.ndarray, owner_id: Optional[str] = None) -> float:
        profile = self._load_owner_profile(owner_id)
        wave = self._prepare_wave(audio)
        x_tensor = torch.from_numpy(wave).unsqueeze(0).unsqueeze(0).to(self.device)

        with torch.no_grad():
            prob = float(torch.sigmoid(self.model(x_tensor)).item())

        if profile is None:
            return float(np.clip(prob, 0.0, 1.0))

        bonafide_mean = float(profile.get("bonafide_mean", 0.75))
        bonafide_std = float(profile.get("bonafide_std", 0.08))
        spoof_mean_prob = float(profile.get("spoof_mean", 0.25))
        z = (prob - bonafide_mean) / (bonafide_std + 1e-8)
        calibrated = 1.0 / (1.0 + np.exp(-z))

        # Relative margin between spoof and bonafide distributions is more stable
        # than absolute probability after many retraining rounds.
        sep = max(1e-4, bonafide_mean - spoof_mean_prob)
        margin_score = float(np.clip((prob - spoof_mean_prob) / sep, 0.0, 1.0))

        feat = self._artifact_features(wave)
        bona_mean = np.array(profile.get("feat_bona_mean", [0.0] * len(feat)), dtype=np.float32)
        bona_std = np.array(profile.get("feat_bona_std", [1.0] * len(feat)), dtype=np.float32)
        spoof_feat_mean = np.array(profile.get("feat_spoof_mean", [0.0] * len(feat)), dtype=np.float32)
        spoof_std = np.array(profile.get("feat_spoof_std", [1.0] * len(feat)), dtype=np.float32)

        z_bona = float(np.mean(np.abs((feat - bona_mean) / (bona_std + 1e-8))))
        z_spoof = float(np.mean(np.abs((feat - spoof_feat_mean) / (spoof_std + 1e-8))))
        feat_bona_score = 1.0 / (1.0 + np.exp(-(2.2 - z_bona)))
        feat_spoof_score = 1.0 / (1.0 + np.exp(-(2.2 - z_spoof)))
        artifact_score = float(np.clip(0.65 * feat_bona_score + 0.35 * (1.0 - feat_spoof_score), 0.0, 1.0))

        blended = 0.35 * prob + 0.2 * calibrated + 0.2 * artifact_score + 0.25 * margin_score

        # Stretch score into owner-specific [spoof_mean, bonafide_mean] range to
        # increase real vs replay separation and avoid fusion "rescuing" low anti-spoof.
        normalized = float(np.clip((blended - spoof_mean_prob) / sep, 0.0, 1.0))
        contrast = 1.0 / (1.0 + np.exp(-7.0 * (normalized - 0.5)))
        return float(np.clip(contrast, 0.0, 1.0))

    def _effective_threshold(self, owner_id: Optional[str] = None) -> float:
        profile = self._load_owner_profile(owner_id)
        if profile is None:
            return self.threshold

        bonafide_mean = float(profile.get("bonafide_mean", 0.75))
        bonafide_std = float(profile.get("bonafide_std", 0.08))
        adaptive = float(np.clip(bonafide_mean - 2.5 * bonafide_std, 0.35, 0.9))
        return min(self.threshold, adaptive)

    def hard_reject_threshold(self, owner_id: Optional[str] = None) -> float:
        """Stricter anti-spoof floor used as a hard gate in verification."""
        profile = self._load_owner_profile(owner_id)
        base = self._effective_threshold(owner_id=owner_id)
        if profile is None:
            return base

        bonafide_mean = float(profile.get("bonafide_mean", 0.75))
        spoof_mean = float(profile.get("spoof_mean", 0.25))
        sep = max(1e-4, bonafide_mean - spoof_mean)

        # Place hard floor away from spoof cluster and keep a minimum guardrail.
        dist_floor = float(np.clip(spoof_mean + 0.55 * sep, 0.22, 0.95))
        return max(base, dist_floor)

    def is_bonafide(self, audio: np.ndarray, owner_id: Optional[str] = None) -> tuple[bool, float]:
        score = self.score_bonafide(audio, owner_id=owner_id)
        return score >= self._effective_threshold(owner_id=owner_id), score
