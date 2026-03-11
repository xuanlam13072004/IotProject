from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import google.generativeai as genai
import numpy as np
from transformers import pipeline


DEVICE_CATALOG: dict[str, dict[str, Any]] = {
    "esp32_1": {
        "name": "ESP32 Smart Home Controller",
        "type": "esp32",
        "controllable_fields": {
            "awningOpen": "boolean",
            "doorOpen": "boolean",
            "awningAutoMode": "boolean",
        },
        "telemetry_fields": {
            "temperature": "number",
            "humidity": "number",
            "gasValue": "number",
            "fireAlert": "boolean",
            "raining": "boolean",
        },
    },
}


@dataclass
class ProcessingStageResult:
    transcript_text: str
    action_json: dict[str, Any]


class ProcessingStage:
    def __init__(self, sample_rate: int = 16000):
        self.sample_rate = sample_rate
        self.device_catalog = DEVICE_CATALOG
        self.base_dir = Path(__file__).resolve().parent
        self._whisper_pipe = None
        self._whisper_model_name = os.getenv("WHISPER_MODEL", "vinai/phowhisper-small").strip() or "vinai/phowhisper-small"
        self._iot_initial_prompt_path = Path(
            os.getenv("IOT_INITIAL_PROMPT_PATH", str(self.base_dir / "initial_prompt_vi.txt"))
        )
        self._iot_initial_prompt_text = self._load_iot_initial_prompt_text()
        self._gemini_model = None
        self._gemini_model_name = None
        self._available_generate_models: list[str] = []
        self._gemini_candidates = [
            "gemini-1.5-flash",
            "gemini-1.5-flash-latest",
            "gemini-1.5-flash-8b",
            "gemini-2.0-flash",
        ]

    def _load_iot_initial_prompt_text(self) -> str:
        path = self._iot_initial_prompt_path
        if not path.exists():
            return ""
        try:
            text = path.read_text(encoding="utf-8").strip()
            return text
        except Exception:
            return ""

    def _get_whisper_pipe(self):
        if self._whisper_pipe is None:
            self._whisper_pipe = pipeline(
                task="automatic-speech-recognition",
                model=self._whisper_model_name,
                chunk_length_s=30,
                device="cpu",
            )
            # PhoWhisper: set forced_decoder_ids for Vietnamese per official docs
            if "phowhisper" in self._whisper_model_name.lower():
                try:
                    tokenizer = self._whisper_pipe.tokenizer
                    self._whisper_pipe.model.config.forced_decoder_ids = (
                        tokenizer.get_decoder_prompt_ids(language="vi", task="transcribe")
                    )
                    print(f"[WHISPER] PhoWhisper detected — forced_decoder_ids set for Vietnamese")
                except Exception as e:
                    print(f"[WHISPER] Warning: Could not set forced_decoder_ids: {e}")
        return self._whisper_pipe

    def _transcribe_vi(self, audio: np.ndarray) -> str:
        pipe = self._get_whisper_pipe()
        audio_input = {
            "raw": np.asarray(audio, dtype=np.float32),
            "sampling_rate": self.sample_rate,
        }

        is_phowhisper = "phowhisper" in self._whisper_model_name.lower()

        generate_kwargs: dict[str, Any] = {
            "language": "vi",
            "task": "transcribe",
        }
        # PhoWhisper is fine-tuned for Vietnamese — initial_prompt interferes
        # with its learned decoder behavior and degrades transcription quality.
        # Only use initial_prompt for standard Whisper models.
        if self._iot_initial_prompt_text and not is_phowhisper:
            generate_kwargs["initial_prompt"] = self._iot_initial_prompt_text

        try:
            result = pipe(audio_input, generate_kwargs=generate_kwargs)
        except Exception:
            # Some checkpoints/pipeline versions may not accept certain kwargs.
            # Fallback keeps Vietnamese transcription working.
            fallback_kwargs = {
                "language": "vi",
                "task": "transcribe",
            }
            result = pipe(audio_input, generate_kwargs=fallback_kwargs)

        text = str(result.get("text", "")).strip()
        print(f"[WHISPER] model={self._whisper_model_name} | len={len(audio)/self.sample_rate:.1f}s | transcript='{text}'")
        if not text:
            return ""
        return text

    def _get_gemini_model(self):
        if self._gemini_model is not None:
            return self._gemini_model

        api_key = os.getenv("GEMINI_API_KEY", "").strip()
        if not api_key:
            raise RuntimeError("Thiếu GEMINI_API_KEY trong môi trường.")

        genai.configure(api_key=api_key)
        try:
            available = []
            for model_info in genai.list_models():
                methods = set(getattr(model_info, "supported_generation_methods", []) or [])
                if "generateContent" in methods:
                    name = str(getattr(model_info, "name", ""))
                    if name.startswith("models/"):
                        name = name.split("/", 1)[1]
                    if name:
                        available.append(name)
            self._available_generate_models = available
        except Exception as exc:
            msg = str(exc)
            if "API_KEY_INVALID" in msg or "API key not valid" in msg:
                raise RuntimeError(
                    "Gemini API key không hợp lệ. Hãy tạo API key mới trong Google AI Studio, "
                    "bật Generative Language API và cập nhật GEMINI_API_KEY trong .env"
                )
            raise RuntimeError(f"Không kiểm tra được model Gemini: {msg}")

        preferred = [m for m in self._gemini_candidates if m in self._available_generate_models]
        fallback = [m for m in self._available_generate_models if m not in preferred]
        search_order = preferred + fallback

        if not search_order:
            raise RuntimeError("Key Gemini hiện tại không có model nào hỗ trợ generateContent.")

        last_error = None
        for model_name in search_order:
            try:
                model = genai.GenerativeModel(model_name)
                self._gemini_model = model
                self._gemini_model_name = model_name
                return self._gemini_model
            except Exception as exc:
                last_error = exc
                continue

        raise RuntimeError(f"Không khởi tạo được Gemini model. Lỗi cuối: {last_error}")

    @staticmethod
    def _normalize_gemini_error(exc: Exception) -> RuntimeError:
        msg = str(exc)
        if "API_KEY_INVALID" in msg or "API key not valid" in msg:
            return RuntimeError(
                "Gemini API key không hợp lệ. Hãy kiểm tra lại GEMINI_API_KEY trong .env "
                "hoặc tạo key mới từ Google AI Studio."
            )
        if "quota" in msg.lower() or "429" in msg:
            return RuntimeError(
                "Gemini bị giới hạn quota/rate limit (429). Chờ reset quota hoặc nâng gói rồi thử lại."
            )
        if "not found" in msg.lower() and "model" in msg.lower():
            return RuntimeError("Model Gemini không khả dụng cho key hiện tại.")
        return RuntimeError(f"Gemini lỗi: {msg}")

    @staticmethod
    def _extract_json(text: str) -> dict[str, Any]:
        cleaned = text.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.strip("`")
            cleaned = cleaned.replace("json", "", 1).strip()

        try:
            parsed = json.loads(cleaned)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass

        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start >= 0 and end > start:
            maybe = cleaned[start : end + 1]
            parsed = json.loads(maybe)
            if isinstance(parsed, dict):
                return parsed

        raise ValueError("Gemini không trả về JSON hợp lệ.")

    def _map_command_to_action(self, transcript_text: str) -> dict[str, Any]:
        self._get_gemini_model()

        schema_hint = {
            "backend_action": "open_door | close_door | open_awning | close_awning | set_auto | set_manual | set_snooze | cancel_snooze | unknown",
            "device_id": "one of catalog keys only",
            "parameters": {
                "seconds": "optional number, only for set_snooze",
                "sensor": "optional all|fire|gas, only for set_snooze/cancel_snooze",
            },
            "confidence": 0.0,
            "raw_text": transcript_text,
            "corrected_text": "string",
        }

        iot_lexicon = self._iot_initial_prompt_text or "(không có từ điển, dùng ngữ cảnh lệnh IoT để tự sửa lỗi chính tả)"

        prompt = (
            "Bạn là Voice Assistant cho hệ thống nhà thông minh.\n"
            "YÊU CẦU BẮT BUỘC:\n"
            "1) Chỉ trả về DUY NHẤT 1 JSON object, không markdown, không giải thích.\n"
            "2) Trước khi map lệnh, phải tự sửa lỗi chính tả từ transcript Whisper dựa trên từ điển lệnh IoT bên dưới.\n"
            "3) corrected_text là câu đã chuẩn hóa chính tả gần nhất với ngữ cảnh lệnh IoT.\n"
            "4) device_id phải map đúng một key trong danh sách thiết bị bên dưới.\n"
            "5) Trả về backend_action theo đúng action mà backend_account hiểu.\n"
            "6) Chỉ dùng các action hợp lệ: open_door, close_door, open_awning, close_awning, set_auto, set_manual, set_snooze, cancel_snooze, unknown.\n"
            "7) Nếu không chắc, backend_action='unknown', device_id='unknown', parameters={}.\n"
            "8) Ngay khi nhận văn bản từ Whisper, phải trả JSON action ngay.\n"
            f"\nDanh sách thiết bị (ID chuẩn): {json.dumps(self.device_catalog, ensure_ascii=False)}\n"
            f"\nTỪ ĐIỂN LỆNH IOT TIẾNG VIỆT (initial_prompt):\n{iot_lexicon}\n"
            f"\nVăn bản lệnh người dùng: {transcript_text}\n"
            f"\nSchema JSON mẫu: {json.dumps(schema_hint, ensure_ascii=False)}"
        )

        raw = ""
        last_error = None
        tried_models: list[str] = []
        search_order = []
        if self._gemini_model_name:
            search_order.append(self._gemini_model_name)
        for m in self._gemini_candidates + self._available_generate_models:
            if m not in search_order:
                search_order.append(m)

        for model_name in search_order:
            try:
                model = genai.GenerativeModel(model_name)
                tried_models.append(model_name)
                response = model.generate_content(prompt)
                raw = getattr(response, "text", "") or ""
                self._gemini_model_name = model_name
                break
            except Exception as exc:
                last_error = exc
                continue

        if not raw:
            raise self._normalize_gemini_error(
                RuntimeError(f"Gemini generate_content thất bại. Tried={tried_models}, error={last_error}")
            )

        try:
            action = self._extract_json(raw)
        except Exception as exc:
            raise RuntimeError(f"Gemini trả về nội dung không parse được JSON. raw={raw}") from exc

        action = self._normalize_action_for_backend(action)

        action.setdefault("raw_text", transcript_text)
        action.setdefault("corrected_text", transcript_text)
        action["whisper_model"] = self._whisper_model_name
        action.setdefault("llm_model", self._gemini_model_name or "unknown")
        action["gemini_raw_text"] = raw
        return action

    @staticmethod
    def _map_set_field_to_backend_action(target_field: str, value: Any) -> str:
        bool_value = bool(value)
        if target_field == "doorOpen":
            return "open_door" if bool_value else "close_door"
        if target_field == "awningOpen":
            return "open_awning" if bool_value else "close_awning"
        if target_field == "awningAutoMode":
            return "set_auto" if bool_value else "set_manual"
        return "unknown"

    def _normalize_action_for_backend(self, action: dict[str, Any]) -> dict[str, Any]:
        valid_backend_actions = {
            "open_door",
            "close_door",
            "open_awning",
            "close_awning",
            "set_auto",
            "set_manual",
            "set_snooze",
            "cancel_snooze",
            "unknown",
        }

        out = dict(action)
        device_id = str(out.get("device_id", "unknown"))
        if device_id not in self.device_catalog:
            device_id = "unknown"

        backend_action = str(out.get("backend_action", "")).strip()
        if not backend_action:
            legacy_action = str(out.get("action", "")).strip()
            if legacy_action == "set_field":
                backend_action = self._map_set_field_to_backend_action(
                    str(out.get("target_field", "unknown")),
                    out.get("value"),
                )
            else:
                backend_action = legacy_action or "unknown"

        if backend_action not in valid_backend_actions:
            backend_action = "unknown"

        parameters = out.get("parameters", {})
        if not isinstance(parameters, dict):
            parameters = {}

        normalized_params: dict[str, Any] = {}
        if backend_action == "set_snooze":
            if "seconds" in parameters:
                try:
                    normalized_params["seconds"] = int(parameters["seconds"])
                except Exception:
                    pass
            if "sensor" in parameters and str(parameters["sensor"]) in {"all", "fire", "gas"}:
                normalized_params["sensor"] = str(parameters["sensor"])
        elif backend_action == "cancel_snooze":
            if "sensor" in parameters and str(parameters["sensor"]) in {"all", "fire", "gas"}:
                normalized_params["sensor"] = str(parameters["sensor"])

        ready = device_id != "unknown" and backend_action != "unknown"
        backend_command = {"action": backend_action, **normalized_params} if ready else None

        out["device_id"] = device_id
        out["backend_action"] = backend_action
        out["parameters"] = normalized_params
        out["backend_command"] = backend_command
        out["ready_for_backend"] = ready
        return out

    def process_audio_to_action(self, audio: np.ndarray) -> ProcessingStageResult:
        transcript_text = self._transcribe_vi(audio)
        if not transcript_text:
            fallback = {
                "action": "unknown",
                "device_id": "unknown",
                "value": None,
                "confidence": 0.0,
                "raw_text": "",
            }
            return ProcessingStageResult(transcript_text="", action_json=fallback)

        action = self._map_command_to_action(transcript_text)
        return ProcessingStageResult(transcript_text=transcript_text, action_json=action)
