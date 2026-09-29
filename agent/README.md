# Lele on Tencent Cloud ADP

This folder is the source of truth for the ADP app. Change it here, then copy the change into ADP.

- `prompts/lele.md`: paste into **Settings → Character Config → Prompt**.
  - Generative model: Tencent Hy3.
- `knowledge/`: upload through **Knowledge → Import**. Each folder is an ADP category:
  - `physical-therapy/` → **Physical therapy**
  - `medicines/` → **Medicines**
  - Delete the old copy of a file before uploading a changed version, then move the new copy into its category.

ADP settings this relies on:
- **Conversation Experience → Fallback Reply:** on, with Lele's text: "I'm not able to answer that one, and I don't want to guess. If it's about a medication, please check with your pharmacist. For anything about your recovery, your clinician is the best person to ask." Without it, ADP's own knowledge-base template answers from general knowledge instead.
- **Knowledge files use single-level lists only.** ADP's parser drops indented sub-items.
- **When importing, set the Effective scope to include the published app**, not only Debug.

What Lele may and may not do is set in `prompts/lele.md` and enforced again by the server (see `docs/architecture.md`).

The medical content in the knowledge base is general education. A physiotherapist and a pharmacist should review it before real patients use it.
