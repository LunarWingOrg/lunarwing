# Qwen3-VL + Tesseract OCR on rootless Podman (quadlets)

Two containers on a shared Podman network:

- **`qwen3vl`** — `llama-server` (CUDA), GPU-attached, serves the OpenAI-compatible vision API.
- **`ocr`** — CPU-only Python service. `/ocr` = pure Tesseract (text + word boxes + confidence). `/extract` = Tesseract text injected into Qwen3-VL as grounding, so the VLM does structured extraction anchored to deterministic OCR.

Rootless layout: drop the `.network` and `.container` files in `~/.config/containers/systemd/`.

---

## 0. Prereqs (one-time)

```bash
# CDI spec for rootless GPU — REGENERATE after every NVIDIA driver update
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# survive logout (rootless services)
loginctl enable-linger "$USER"

# models on disk (example layout):
#   ~/models/qwen3-vl-30b-a3b/Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL.gguf
#   ~/models/qwen3-vl-30b-a3b/mmproj-F16.gguf
```

If SELinux denies GPU device nodes, install the nvidia-container SELinux policy module; to *confirm* that's the cause, temporarily add `SecurityLabelDisable=true` to the `[Container]` section.

---

## 1. `vlm.network`

```ini
[Network]
NetworkName=vlm
# aardvark-dns is on by default → containers resolve each other by ContainerName
```

---

## 2. `qwen3vl.container`

```ini
[Unit]
Description=Qwen3-VL (llama.cpp server, CUDA)
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/ggml-org/llama.cpp:server-cuda
ContainerName=qwen3vl
AddDevice=nvidia.com/gpu=all
Volume=%h/models:/models:z,ro
Network=vlm.network
PublishPort=8080:8080
# All args passed to the server binary directly (no reliance on env var names):
Exec=-m /models/qwen3-vl-30b-a3b/Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL.gguf \
     --mmproj /models/qwen3-vl-30b-a3b/mmproj-F16.gguf \
     -c 32768 -ngl 99 --flash-attn on \
     --cache-type-k q8_0 --cache-type-v q8_0 \
     --jinja --host 0.0.0.0 --port 8080

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

Pin a specific build for reproducibility if you want (e.g. `:server-cuda-bXXXX`); `:server-cuda` tracks latest, which is already well past b6907.

---

## 3. `ocr_pipeline.py`

```python
import base64, io, os, requests
from fastapi import FastAPI, UploadFile, File, Form
from PIL import Image, ImageOps
import pytesseract

VLM_URL = os.environ.get("VLM_URL", "http://qwen3vl:8080/v1/chat/completions")
TESS_CFG = "--oem 1 --psm 3"          # LSTM engine; tune psm per doc layout
app = FastAPI()

def preprocess(img: Image.Image) -> Image.Image:
    return ImageOps.autocontrast(ImageOps.grayscale(img))

@app.post("/ocr")
async def ocr(file: UploadFile = File(...)):
    img = preprocess(Image.open(io.BytesIO(await file.read())))
    d = pytesseract.image_to_data(img, config=TESS_CFG,
                                  output_type=pytesseract.Output.DICT)
    words = [
        {"text": t, "conf": int(c), "bbox": [x, y, w, h]}
        for t, c, x, y, w, h in zip(d["text"], d["conf"], d["left"],
                                    d["top"], d["width"], d["height"])
        if t.strip() and int(c) >= 0
    ]
    return {"text": pytesseract.image_to_string(img, config=TESS_CFG),
            "words": words}

@app.post("/extract")
async def extract(file: UploadFile = File(...),
                  prompt: str = Form("Extract all fields as JSON.")):
    raw = await file.read()
    b64 = base64.b64encode(raw).decode()
    ocr_text = pytesseract.image_to_string(
        preprocess(Image.open(io.BytesIO(raw))), config=TESS_CFG)
    payload = {
        "model": "qwen3-vl",
        "temperature": 0.2,
        "messages": [{"role": "user", "content": [
            {"type": "text",
             "text": f"{prompt}\n\nTesseract OCR (ground-truth text):\n{ocr_text}"},
            {"type": "image_url",
             "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ]}],
    }
    r = requests.post(VLM_URL, json=payload, timeout=300)
    return {"ocr_text": ocr_text,
            "vlm": r.json()["choices"][0]["message"]["content"]}
```

---

## 4. `Containerfile.ocr`

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        tesseract-ocr tesseract-ocr-eng \
        # add languages as needed, e.g. tesseract-ocr-jpn tesseract-ocr-chi-sim \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" pytesseract pillow requests
WORKDIR /app
COPY ocr_pipeline.py .
EXPOSE 8000
CMD ["uvicorn", "ocr_pipeline:app", "--host", "0.0.0.0", "--port", "8000"]
```

Build it:

```bash
podman build -t ocr-pipeline -f Containerfile.ocr .
```

(Or use a `.build` quadlet on Podman 5.x and reference `Image=ocr-pipeline.build`.)

---

## 5. `ocr.container`

```ini
[Unit]
Description=Tesseract OCR + Qwen3-VL pipeline
After=qwen3vl.service
Wants=qwen3vl.service

[Container]
Image=localhost/ocr-pipeline:latest
ContainerName=ocr
Network=vlm.network
PublishPort=8000:8000
Environment=VLM_URL=http://qwen3vl:8080/v1/chat/completions

[Service]
Restart=always

[Install]
WantedBy=default.target
```

---

## 6. Start + test

```bash
systemctl --user daemon-reload
systemctl --user start qwen3vl ocr      # qwen3vl pulls first; ~min to load model

# pure Tesseract (boxes + confidence)
curl -s -F "file=@page.png" http://localhost:8000/ocr | jq

# grounded structured extraction (Tesseract → Qwen3-VL)
curl -s -F "file=@invoice.png" \
     -F "prompt=Return JSON: invoice_number, date, line_items[], total" \
     http://localhost:8000/extract | jq
```

---

## Scaling notes

- Need OCR independently scalable/reusable? Split `/ocr` into its own container and keep `/extract` as a thin gateway — three units, same network. For a single node, the 2-container form above is leaner.
- `--psm` matters more than people expect: `3` (auto) for full pages, `6` for uniform blocks, `4` for columns, `11`/`12` for sparse text. Expose it as a form param if your inputs vary.
- For heavier layout/table work, PaddleOCR / docTR / Surya outperform Tesseract — drop-in swap behind the same `/ocr` contract if Tesseract's accuracy ceiling bites.
