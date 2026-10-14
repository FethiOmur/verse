# Licences of third-party components

Checked 2026-10-14 (P1-3 Nemotron engine). Only components that Verse links or loads at run time are listed.
"Read" means the text was read for this note; "not read" means only metadata was seen.

## Local English speech engine

| Component | Licence | Where read | Commercial distribution |
|---|---|---|---|
| FluidAudio 0.17.7 (Swift package, `app/Package.swift`, exact pin) | Apache-2.0 | `LICENSE` in the checkout (full Apache-2.0 text); GitHub licence API | Allowed. Keep the licence text and NOTICE with a redistribution. |
| NemoTextProcessing xcframework (`FluidInference/text-processing-rs` v0.3.1, prebuilt binary pulled in by FluidAudio and statically linked) | Apache-2.0 | GitHub licence API for the repo (`Apache-2.0`); `LICENSE` on `main` is the Apache-2.0 text; FluidAudio's `ThirdPartyLicenses/NemoTextProcessing-LICENSE.md` (written for v0.3.0) lists what it embeds: NVIDIA NeMo Text Processing (Apache-2.0), `rustfst` (MIT OR Apache-2.0), `flate2` (MIT OR Apache-2.0), other permissive Rust crates (MIT/Apache-2.0) | Allowed. Not checked: the licence file inside the v0.3.1 release zip itself (only `main` and the v0.3.0 note were read). |
| Nemotron Speech Streaming 0.6B weights, CoreML conversion `FluidInference/nemotron-speech-streaming-en-0.6b-coreml` (we use the `nemotron_coreml_560ms` folder) | **NVIDIA Open Model License Agreement** (Last Modified Oct 24, 2025). HF metadata of both the CoreML repo and the base model `nvidia/nemotron-speech-streaming-en-0.6b`: `license: other`, `license_name: nvidia-open-model-license`. | Full agreement text read at https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ ; base model card: "ready for commercial/non-commercial use", "Governing Terms: ... NVIDIA Open Model License Agreement" | Allowed with conditions, see below. |

### Conflict on the CoreML model card

The `FluidInference/...-coreml` README ends with "## License: Apache 2.0 (following NVIDIA's original license)", while
its YAML header says `nvidia-open-model-license` and the base model is governed by the NVIDIA Open Model License.
The card contradicts itself. Verse treats the weights as **NVIDIA Open Model License** (the stricter reading; the base
model's own card is authoritative for NVIDIA's weights). A converter cannot relicense NVIDIA's weights to Apache-2.0.

### NVIDIA Open Model License: what matters for Verse

Nothing in it restricts commercial use or distribution of the weights. Stated in the agreement: models are commercially
usable; free to create and distribute Derivative Models; NVIDIA claims no ownership of outputs (transcripts). Conditions:

1. **Redistribution of the model files** (only if a Verse release ships them or hosts them for download): give the
   recipient a copy of the agreement and include a Notice text file with: "Licensed by NVIDIA Corporation under the
   NVIDIA Open Model License". Today the model is not shipped with the app: it sits in
   `~/Library/Application Support/Verse/models/nemotron-en-0.6b-560ms/` on the owner's Mac and is never downloaded by the
   code. If a later release downloads it for users from a Verse-controlled server, that is distribution: ship the
   agreement and the Notice with it.
2. Rights terminate if the user bypasses or disables a technical guardrail or safety mechanism of the model (not
   applicable to plain ASR use), or if the user sues anyone claiming the model infringes copyright or patents.
3. Use must be consistent with NVIDIA's Trustworthy AI terms (https://www.nvidia.com/en-us/agreements/trustworthy-ai/terms/;
   linked from the agreement, **not read**).
4. NVIDIA may update the agreement "to comply with legal and regulatory requirements at any time"; the user must then
   comply with the updated licence or stop using/distributing the model. A revocable licence: do not build a product
   that cannot survive losing the model (the Apple engine fallback covers this).
5. Indemnity: the licensee indemnifies NVIDIA against third-party claims arising from use or distribution of the model
   or outputs (clause "Indemnity"). Relevant only if Verse is offered to others.
6. Not an NVIDIA Cosmos Model, so the "Built on NVIDIA Cosmos" notice does not apply. No trademark permission beyond
   describing the origin of the model.

**Flag:** no restriction on commercial distribution found. The open points are the contradictory model card (resolved
above in favour of the NVIDIA licence) and the unread Trustworthy AI terms.

### Also in the FluidAudio package

`FluidAudio_FluidAudio.bundle` (about 1 MB, copied next to the binary) carries text-processing and TTS data that
FluidAudio documents in `ThirdPartyLicenses/` (e.g. Japanese G2P word list and unidic-lite under the BSD option of its
GPL/LGPL/BSD tri-licence, Kokoro ANE notices). Verse does not use those features, but a redistributed build includes the
bundle, so ship FluidAudio's `LICENSE` and `ThirdPartyLicenses/` with it. Not audited file by file.

## Apple frameworks

`Speech` (`SpeechTranscriber`, `DictationTranscriber`, `SpeechAnalyzer`), `AVFoundation`, `CoreAudio`, `CoreML` are
system frameworks under the Apple SDK agreement; no redistribution of their models by Verse.
