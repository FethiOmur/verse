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

## Paraphrase bank matcher (F3, brain)

Checked 2026-10-14 (F3 embedding matcher in `brain/verse_brain/runtime/embed.py`).

| Component | Licence | Where read | Commercial distribution |
|---|---|---|---|
| `litert-lm-api` 0.18.0 (PyPI wheel `py3-none-macosx_12_0_arm64`, imported as `litert_lm`; pinned in `brain/pyproject.toml`, same version as `bench/embed/.venv`). Ships the prebuilt `liblitert-lm.dylib`. | Apache-2.0 | Wheel `METADATA` (`License: Apache-2.0`, classifier "Apache Software License"); the wheel carries no licence file. Full Apache-2.0 text read in `LICENSE` of `github.com/google-ai-edge/LiteRT-LM` (GitHub licence API: `Apache-2.0`); the repo root has no NOTICE file. | Allowed. Keep the Apache-2.0 text with a redistribution. Not audited: the third-party code statically linked into `liblitert-lm.dylib` (the repo's `third_party/` folder was not read). |
| EmbeddingGemma 2 text 270M, LiteRT-LM conversion `litert-community/embeddinggemma-2-text-270m-litert-lm` (revision `9be6e8b9`, file `embeddinggemma-2-text-270m.litertlm`, in `~/Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/`) | Apache-2.0 (the conversion and its base model `google/embeddinggemma-2`) | Local `README.md` (YAML header `license: apache-2.0`) and `SOURCE.txt` next to the model; Hugging Face API metadata of both repos (`license:apache-2.0`, base model not gated). The base model card's prose and any usage policy it links were **not read**. | Allowed (Apache-2.0: keep the licence text with a redistribution). The model is not shipped with the app and the code never downloads it. |

## Interview simulation prep (S1, brain)

Checked 2026-10-15 (CV PDF reading in `brain/verse_brain/prep/sim.py`).

| Component | Licence | Where read | Commercial distribution |
|---|---|---|---|
| `pypdf` 6.20.1 (PyPI, pinned in `brain/pyproject.toml`) | BSD-3-Clause | Wheel `METADATA` (`License-Expression: BSD-3-Clause`) and the `LICENSE` file in its `dist-info` (BSD-3 text, copyright Mathieu Fenniak and contributors) | Allowed. Keep the copyright notice and licence text with a redistribution; do not use the authors' names to endorse Verse. |

## Apple frameworks

`Speech` (`SpeechTranscriber`, `DictationTranscriber`, `SpeechAnalyzer`), `AVFoundation`, `CoreAudio`, `CoreML` are
system frameworks under the Apple SDK agreement; no redistribution of their models by Verse.

## Code adapted from Moonglade

Moonglade (https://github.com/ixjosemi/Moonglade, local checkout `~/Developer/Moonglade`, read 2026-10-14), MIT licence; `LICENSE` read
in full in the checkout. Verse adapts code from it in these files, each with a one-line header naming the source:

| Verse file | Adapted from |
|---|---|
| `app/Sources/VerseUI/HangingNotchGeometry.swift` | `Sources/MoongladeCore/Presentation/HangingNotchGeometry.swift` |
| `app/Sources/VerseUI/NotchGlass.swift` | `Sources/MoongladeApp/NotchGlassBackground.swift`, `Sources/MoongladeCore/Presentation/NotchGlassStyle.swift` |
| `app/Sources/VerseUI/NotchPanel.swift` (silhouette hit testing only) | `Sources/MoongladeApp/NotchPanel.swift` |

The MIT licence requires the notice below in all copies or substantial portions; keep it with any distribution of Verse.

```
MIT License

Copyright (c) 2026 Josemi Hernandez

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The glass uses private Core Animation classes (`CABackdropLayer`, `CASDFLayer`, `CAFilter` type `glassBackground`),
resolved at run time with a public fallback. Fine for a directly distributed app; Mac App Store review would reject it.

## Local degraded-mode brain (G1, brain)

Checked 2026-10-15 (`brain/verse_brain/runtime/local_llm.py`, `fallback.py`). Gemma answers only while the API is offline,
rate-limited or out of credit; it runs in the brain process through `litert-lm-api` (already listed above, Apache-2.0).
No new Python dependency.

| Component | Licence | Where read | Commercial distribution |
|---|---|---|---|
| Gemma 4 E4B-it, LiteRT-LM conversion `litert-community/gemma-4-E4B-it-litert-lm` (revision `2eee7ac3`, file `gemma-4-E4B-it.litertlm`, 3,659,530,240 bytes, in `~/Library/Application Support/Verse/models/gemma-4-E4B-it-litert-lm/`) | Apache-2.0 per the Hugging Face metadata of the conversion (`license: apache-2.0`) and of the base model `google/gemma-4-E4B-it` (card: "License: Apache 2.0", linking to Google's Gemma 4 licence page). The local `SOURCE.txt` says "Apache-2.0 + Gemma Prohibited Use Policy". | **There is no README or licence file next to the model**: the folder holds only `SOURCE.txt` (read in full) and the `.litertlm` file. Read on the web instead: the HF pages of the conversion and of `google/gemma-4-E4B-it` (YAML licence field and card prose; neither card is gated and neither has a licence or acceptable-use section of its own) and the Gemma Prohibited Use Policy at `ai.google.dev/gemma/prohibited_use_policy`. **Not read:** the Gemma 4 licence text on Google's licence page (the card links to it); the Gemma Terms of Use. The web pages were read through a summarising fetch tool, not as raw text. | Allowed on the Apache-2.0 reading (keep the licence text and notices with a redistribution). The model is not shipped with the app and the code never downloads it; if a release ever downloads it for users, that is distribution: ship the Apache-2.0 text and the pointer to the Prohibited Use Policy. |

### Gemma Prohibited Use Policy: what matters for Verse

The policy page lists prohibited uses (rights infringement; dangerous, illegal or malicious activity, including tracking
people without consent and processing sensitive personal data without the needed consents; misinforming or misleading,
including impersonating a person or presenting generated content as human-made "in order to deceive", and fully
automated employment decisions; sexually explicit content). It does not restrict commercial use and does not mention
meeting or interview assistance. Two points to keep in view:

1. **Applicability is unclear.** The conversion card and the base card show Apache-2.0 and no standalone policy; the
   policy page I read is Google's Gemma policy page and may be the older Gemma-family text. Verse treats it as applying
   (the stricter reading, as for the NVIDIA licence above).
2. **Deception clause.** The "mislead ... in order to deceive" wording is about intent. Verse writes words for Alex to
   say in his own interviews and meetings; the deception reading would only apply if the output is presented to the
   other side as something it is not, which is a question of the interview's own rules, not of this software. Flagged
   for the owner's judgement; no technical term found forbids this use.

Nothing found forbids the degraded-mode use. Memory and disk: about 1.7 GB peak RSS (2.2 GB peak memory footprint) while
loaded and primed; 3.4 GB on disk plus a compiled-model cache (`cache/` next to the model, 2.1 GB measured) created on first load.
