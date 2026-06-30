Open gaps
• XMPP → LunarVision gap: Agents can receive image files over XMPP (
attachments.rs:40
 encodes image data as ContentPart::ImageUrl for the LLM), but there’s no automatic pipeline to route those images to LunarVision for OCR/VL analysis. This is the known issue you flagged.

The XMPP → LunarVision Gap
As noted in 
RELEASE-v1.1.7.md:193
:
Although agents can receive media files over XMPP, there is no way currently for the media file to immediately be viewed via LunarVision. This will be remedied in a future release.
Current state: When an image arrives over XMPP, 
attachments.rs:40-48
 encodes it as ContentPart::ImageUrl (base64 data URL) and passes it directly to the LLM as multimodal input. The LLM “sees” the image if it’s a vision-capable model (detected by 
vision_models.rs
), but the image is never routed to LunarVision for OCR text extraction or VL analysis.
The gap: There’s no hook or pipeline that says “image attachment arrived → send to LunarVision sidecar → inject OCR/VL results into agent context.” The vision-analyze WASM tool exists and works, but it must be explicitly called by the agent — there’s no automatic interception.
What a fix would look like: Either (a) a BeforeInbound hook that detects image attachments and pre-processesses them through LunarVision, or (b) an agent-loop integration that auto-calls the vision tool when image attachments are present. Option (a) would be more consistent with the existing hook architecture (ic/src/hooks/).


Implementing the XMPP → LunarVision auto-routing

