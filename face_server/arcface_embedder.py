# arcface_embedder.py
import cv2
import numpy as np
from numpy.linalg import norm
from insightface.app import FaceAnalysis

class ArcFaceEmbedder:
    def __init__(self, device="cpu"):
        providers = ["CPUExecutionProvider"]
        ctx_id = -1

        self.app = FaceAnalysis(
            name="buffalo_l",
            providers=providers
        )
        self.app.prepare(ctx_id=ctx_id, det_size=(640, 640))

    def get_embedding(self, face_bgr):
        """
        face_bgr: ảnh mặt đã cắt (BGR)
        return: vector 512D (numpy array)
        """
        face = cv2.resize(face_bgr, (112, 112))
        emb = self.app.models["recognition"].get_feat(face)[0]
        return emb / norm(emb)
