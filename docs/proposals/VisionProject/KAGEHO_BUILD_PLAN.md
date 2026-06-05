# Docker Image Build Plan — OpenAI Vision OCR Worker

---

## 1) Directory layout

```
projects/
└─ ocr-openai-worker/
   ├─ Dockerfile
   └─ entrypoint.py
```

Create the folder `projects/ocr-openai-worker` in the IronClaw workspace and place the two files below.

---

## 2) Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

# ---- Install system deps -------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

# ---- Install Python deps -------------------------------------------------
RUN pip install --no-cache-dir openai==1.35.0

# ---- Add the OCR entrypoint ---------------------------------------------
COPY entrypoint.py /usr/local/bin/entrypoint.py
RUN chmod +x /usr/local/bin/entrypoint.py

# ---- Runtime defaults ----------------------------------------------------
ENTRYPOINT ["python", "/usr/local/bin/entrypoint.py"]
```

---

## 3) entrypoint.py

```python
#!/usr/bin/env python3
import os, sys, base64
from openai import OpenAI

# ----------------------------------------------------------------------
# Expected environment variables (injected by IronClaw)
#   OPENAI_API_KEY   – your secret (set via `credentials` map)
#   OCR_IMAGE        – absolute path inside the container to the image file
# ----------------------------------------------------------------------
api_key = os.getenv("OPENAI_API_KEY")
image_path = os.getenv("OCR_IMAGE")

if not api_key or not image_path:
    sys.stderr.write("❌ Missing OPENAI_API_KEY or OCR_IMAGE\n")
    sys.exit(1)

client = OpenAI(api_key=api_key)

with open(image_path, "rb") as f:
    img_bytes = f.read()

# Call the vision model (gpt-4o-mini is cheap and good for OCR)
resp = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[
        {
            "role": "user",
            "content": [
                {"type": "image_url",
                 "image_url": {"url": f"data:image/jpeg;base64,{base64.b64encode(img_bytes).decode()}"}},
                {"type": "text",
                 "text": "Extract all visible text from the image. Return plain text only."}
            ],
        }
    ],
    max_tokens=1024,
)

# Print the OCR result to stdout – IronClaw captures this as the skill output
print(resp.choices[0].message.content.strip())
```

---

## 4) Build the image (run on the host that runs IronClaw)

```bash
# Navigate to the folder
cd ~/.ironclaw/projects/ocr-openai-worker

# Build the image locally
docker build -t ironclaw/ocr-openai .
```

If you have a private registry (e.g. `registry.mycorp.local`), tag and push:

```bash
docker tag ironclaw/ocr-openai registry.mycorp.local/ocr-openai:latest
docker push registry.mycorp.local/ocr-openai:latest
```

If you keep the image local, IronClaw can still run it because the daemon uses the host Docker daemon.

---

## 5) Verify the build

```bash
docker run --rm ironclaw/ocr-openai python -c "print('image built OK')"
```

You should see `image built OK` printed, confirming the container starts correctly.

---

## 6) Next steps after the image is ready

1. **Store the OpenAI key** in the same daemon that will run the job:

   ```bash
   ironclaw secret set openai_api_key 'sk-xxxxxxxxxxxxxxxxxxxx'
   ```

2. **Install the skill** (the `SKILL.md`) so IronClaw knows how to invoke the image.

3. **Test a one-off job** (replace `<path>` with a real image inside the workspace):

   ```json
   {
     "title": "Test OCR",
     "description": "export OCR_IMAGE=/workspace/<path> && python /usr/local/bin/entrypoint.py",
     "mode": "worker",
     "project_dir": "/home/sun/.ironclaw/projects/<your-project-id>",
     "wait": true,
     "credentials": { "openai_api_key": "OPENAI_API_KEY" }
   }
   ```

   Run with `create_job`. The job's stdout will be the extracted text.

---

## 7) Optional tweaks

| Want | How to change |
|------|---------------|
| **Different OpenAI model** | Change `model="gpt-4o-mini"` to `gpt-4o` or any other vision model in `entrypoint.py`. |
| **Support PNG, GIF, PDF** | Adjust the MIME type in the `data:` URL (`image/png`, etc.) and ensure the file is opened in binary mode (already done). |
| **Add language hint** | Pass an extra env var `OCR_LANG` and modify the prompt to include "Extract text in `<OCR_LANG>`". |
| **Reduce image size** | Pre-scale the image with `pillow` before sending (add `Pillow` to `pip install`). |

---

*This file serves as the build plan for the OpenAI Vision OCR Worker Docker image.*
