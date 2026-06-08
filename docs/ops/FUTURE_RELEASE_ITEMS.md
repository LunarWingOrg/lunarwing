# Future / Unscheduled Ideas

> Scheduled, version-targeted work lives in the deferred-items roadmap in `RELEASE-v1.1.1.md`.
> This file holds longer-horizon ideas that don't yet have a firm release target or plan.

- **Lunartica / Multica** — multi-agent coordination (forked Multica; self-hostable FOSS).
  Currently pre-release/experimental; refinements targeted v1.1.4 (see roadmap).
- **LunarVoice** — voice (audio in/out) interface. No plan yet; needs proper planning.
- **LunarVision / K.E.R.S.** — further improve OCR + image recognition (the vision sidecar has
  already shipped; this is enhancement beyond it).
- **Character lorebooks + profile enhancements** — profile onboarding already shipped; add
  lorebooks and extend the testing suite to cover them.
- **Human-delay mode** (`IdeasFromDocumentWrench`) — partial; not yet planned.

## Testing follow-ups

- Migrate a file-based libSQL instance to a live MT setup to verify migration end-to-end.
- Extend automated test coverage for the codex container, the pebble external worker, and the
  reflex compiler (over a longer run).
