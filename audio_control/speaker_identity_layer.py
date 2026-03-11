from __future__ import annotations

import numpy as np


class SpeakerVerifier:
    """Lớp 2: Multi-template verification bằng K-Nearest Templates."""

    def __init__(self, threshold: float = 0.65, top_k: int = 3):
        self.threshold = threshold
        self.top_k = top_k

    @staticmethod
    def cosine_similarity(embedding_a: np.ndarray, embedding_b: np.ndarray) -> float:
        a = embedding_a.astype(np.float32)
        b = embedding_b.astype(np.float32)
        score = np.dot(a, b) / ((np.linalg.norm(a) * np.linalg.norm(b)) + 1e-8)
        return float(score)

    def verify(
        self,
        probe_embedding: np.ndarray,
        owner_templates: np.ndarray,
        strategy: str = "k_nearest",
    ) -> tuple[bool, float]:
        probe = np.squeeze(probe_embedding).astype(np.float32)
        templates = np.asarray(owner_templates, dtype=np.float32)

        if templates.ndim == 1:
            templates = templates[None, :]
        if templates.ndim != 2:
            raise ValueError("owner_templates phải có shape (N, D) hoặc (D,).")
        if probe.shape[0] != templates.shape[1]:
            raise ValueError(
                f"Không khớp shape embedding: probe={probe.shape[0]}, template_dim={templates.shape[1]}"
            )

        scores = np.array([self.cosine_similarity(probe, tpl) for tpl in templates], dtype=np.float32)
        k = max(1, min(self.top_k, len(scores)))
        topk = np.sort(scores)[-k:]
        topk_avg = float(np.mean(topk))

        if strategy in {"k_nearest", "topk_avg"}:
            final_score = topk_avg
        elif strategy in {"centroid", "average", "avg_centroid"}:
            centroid = np.mean(templates, axis=0).astype(np.float32)
            centroid = centroid / (np.linalg.norm(centroid) + 1e-8)
            final_score = self.cosine_similarity(probe, centroid)
        elif strategy in {"mean_all", "avg_all"}:
            final_score = float(np.mean(scores))
        elif strategy == "max":
            final_score = float(np.max(scores))
        elif strategy == "hybrid":
            max_score = float(np.max(scores))
            final_score = 0.6 * topk_avg + 0.4 * max_score
        else:
            raise ValueError("strategy không hợp lệ. Chọn: k_nearest | mean_all | max | hybrid")

        return final_score >= self.threshold, float(final_score)
