import numpy as np
import pickle
from sklearn.svm import SVC
from sklearn.preprocessing import LabelEncoder
import os

# ===== ĐƯỜNG DẪN ĐÚNG THEO NODE ARCFAE =====
MODEL_DIR = 'face_models_arcface_512'

EMBEDDINGS_PATH = os.path.join(MODEL_DIR, 'faces_embeddings_arcface_512.npz')
SVM_PATH = os.path.join(MODEL_DIR, 'svm_arcface_512.pkl')
LABEL_ENCODER_PATH = os.path.join(MODEL_DIR, 'label_encoder_arcface.pkl')

# ===== LOAD EMBEDDINGS =====
print('🔹 Loading embeddings...')
data = np.load(EMBEDDINGS_PATH)
X = data['embeddings']      # shape: (N, 512)
y = data['labels']

print("Embedding shape:", X.shape)

# ===== ENCODE LABEL =====
print('🔹 Encoding labels...')
label_encoder = LabelEncoder()
y_encoded = label_encoder.fit_transform(y)

# ===== TRAIN SVM =====
print('🔹 Training SVM...')
svm_model = SVC(kernel='linear', probability=True)
svm_model.fit(X, y_encoded)

# ===== SAVE MODEL =====
print('🔹 Saving SVM and label encoder...')
os.makedirs(MODEL_DIR, exist_ok=True)

with open(SVM_PATH, 'wb') as f:
    pickle.dump(svm_model, f)

with open(LABEL_ENCODER_PATH, 'wb') as f:
    pickle.dump(label_encoder, f)

print('✅ Done! ArcFace 512D SVM and label encoder saved.')
