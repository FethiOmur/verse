# WhisperKit Turkish bench: BLOCKED, model not on disk

Date: 2026-10-14. No benchmark was run. The brief says to stop and report when TypeWhisper's WhisperKit model cannot be found or would need downloading, and no model was downloaded.

## What was looked for

TypeWhisper's own code (`WhisperKitPlugin.swift`) stores WhisperKit models under `<pluginDataDirectory>/models/models/argmaxinc/whisperkit-coreml/<variant>` (older versions: `~/Library/Application Support/TypeWhisper[-Dev]/models/...`). The default for the owner's install records `plugin.com.typewhisper.whisperkit.loadedModel = openai_whisper-large-v3-turbo`.

## Paths and searches checked (all negative)

| check | result |
|---|---|
| `~/Library/Application Support/TypeWhisper/PluginData/` | only `com.typewhisper.groq`, `com.typewhisper.parakeet`, `com.typewhisper.speechanalyzer`, all empty (0 B); no `com.typewhisper.whisperkit` |
| `~/Library/Application Support/TypeWhisper/Plugins/` | only `GroqPlugin.bundle` and `ParakeetPlugin.bundle`; no `WhisperKitPlugin.bundle` |
| `/Applications/TypeWhisper.app/Contents/PlugIns/` | only `SpeechAnalyzerPlugin.bundle` and two appex |
| `~/Library/Application Support/TypeWhisper/` legacy `models/` | no `models` directory |
| `~/.cache/huggingface` | 56 KB, only xet logs, no model |
| `~/Documents/huggingface` (WhisperKit's default download base) | does not exist |
| `find /` (excluding `/System`, `/Volumes`) for directories named `whisperkit-coreml`, `openai_whisper-*`, `AudioEncoder.mlmodelc` | none (only the unrelated Homebrew `openai_whisper-20250625.dist-info` Python package) |
| `find ~ /opt /usr/local /Library -iname "*turbo*"` | only libjpeg-turbo files |
| Spotlight `mdfind` for `openai_whisper`, `large-v3` | no hits |
| Parakeet model (also listed as downloaded) | `PluginData/com.typewhisper.parakeet` empty; no FluidAudio cache directory under `~/Library/Application Support` or `~/Library/Caches` |

Conclusion: the plugin that owned the WhisperKit model is no longer installed and its model files are gone (or never lived in a location I can read). The stored `loadedModel` default is stale. I did not look inside TypeWhisper's history, audio, dictionary or key stores.

## What is needed to unblock

Pick one, then I can run the bench (WhisperKit is MIT, our bench code is written from scratch under `bench/whisper/`):

1. Alex reinstalls the WhisperKit plugin in TypeWhisper and downloads `Large v3 Turbo` (the plugin lists it as about 3.2 GB), or
2. Alex approves a download of `argmaxinc/whisperkit-coreml` variant `openai_whisper-large-v3_turbo` (about 3.2 GB per the plugin's catalog; a smaller `distil-whisper_distil-large-v3_turbo`, about 1.5 GB, is also in the catalog) into `bench/whisper/models/` (to be git-ignored), or
3. A different model that is already on disk is named.

## Comparison table (to be filled once unblocked)

DictationTranscriber numbers come from `bench/speech/RESULTS_speech.md` (Turkish, Yelda, 20 questions, 50 ms real-time feed).

| lang | engine | last-word lag p50 / p90 | final lag p50 / p90 | WER | CPU / RAM |
|---|---|---|---|---|---|
| tr (Yelda) | DictationTranscriber+frequentFinalization | 523 / 646 ms | 2256 / 2321 ms | 18.1 % | not measured |
| tr (Yelda) | WhisperKit large-v3-turbo | not run | not run | not run | not run |
| it (Alice) | SpeechTranscriber+fastResults | 794 / 1107 ms | 3551 / 8664 ms | 0 % | not measured |
| it (Alice) | WhisperKit large-v3-turbo | not run | not run | not run | not run |

## Planned method (unchanged from the brief, so the numbers stay comparable)

20 `say -v Yelda` Turkish questions (same corpus as `bench/speech/Sources/SpeechBench/Corpus.swift`) and the same 20 Italian with Alice as a cross-check; temp WAV files deleted right after load; real-time feed in 50 ms buffers; streaming mode = rolling-window re-decode (TypeWhisper's own preview uses a 3 s poll over the last 10 s, which cannot meet a sub-second target, so hop size is itself a result to measure); last-word lag and final lag against the energy-based acoustic end; WER as in the speech bench; CPU and RAM sampled during the run; only the bench binary and short-lived `say` children started, all checked with `pgrep` afterwards; no audio left behind.

## Processes and files

No process was started for this part. No audio file was created. The only file written here is this one.
