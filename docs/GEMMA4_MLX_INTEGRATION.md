# Gemma 4 MLX Integration Notes

## Summary

This app did not get Gemma 4 support by only updating `mlx-swift` or `mlx-swift-lm`.

At the time of implementation:

- existing model families like `gemma3`, `gemma3n`, `qwen3`, and `qwen3_5` were already present upstream
- upstream `mlx-swift-lm` still did not expose `gemma4` or `gemma4_text`
- Gemma 4 MLX configs on Hugging Face used:
  - top-level `model_type: "gemma4"`
  - nested `text_config.model_type: "gemma4_text"`

So the working approach was:

1. keep upstream MLX packages
2. add an app-local Gemma 4 text model implementation
3. register `gemma4` and `gemma4_text` at runtime
4. preserve all existing model support

## What Was Added

The main integration lives in [RSSReaderApp/Services/MLXLocalService.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Services/MLXLocalService.swift).

### 1. App-local Gemma 4 model types

Added local types for Gemma 4 text inference:

- `Gemma4TextConfiguration`
- `Gemma4Attention`
- `Gemma4MLP`
- `Gemma4DecoderLayer`
- `Gemma4TextBackbone`
- `Gemma4TextModel`
- `Gemma4ProportionalRoPE`
- `Gemma4RMSNormNoScale`

This mirrors the existing `mlx-swift-lm` model style instead of replacing the app’s MLX architecture.

### 2. Nested config decoding

Gemma 4 MLX repos may store text config under `text_config`.

`Gemma4TextConfiguration` was written to decode either:

- a normal text-only config
- a VLM-style config with nested `text_config`

That keeps the same model loader path working for both kinds of repositories.

### 3. Runtime model registration

Added `registerGemma4SupportIfNeeded()` in `MLXLocalService`.

It does two things:

- registers `gemma4` and `gemma4_text` with `LLMTypeRegistry.shared`
- registers a few known Gemma 4 Hugging Face ids in `LLMModelFactory.shared.modelRegistry`

That means existing models still work, and Gemma 4 becomes additive support rather than a fork of the whole registry.

### 4. Hooked registration into both load paths

Gemma 4 registration is called before:

- hub model loading
- local directory model loading

That matters because the app supports both remote HF ids and local downloaded/external models.

### 5. Weight sanitizing

`Gemma4TextModel.sanitize(weights:)` does two important things:

- unwraps `language_model.*` weights for Gemma 4 models packaged in multimodal layout
- ties `lm_head` to `embed_tokens` when `lm_head.weight` is absent

Without that, loading fails for common MLX-exported Gemma 4 repos.

## Important Fixes

### Missing computed RoPE weights

Gemma 4 proportional RoPE computes `freqs` locally.

MLX load verification initially failed with:

`Key model.layers.X.self_attn.rope.freqs not found`

Fix (stable crash prevention):

- renamed the internal tensor from `freqs` to `_frequencies` in `Gemma4ProportionalRoPE`
- passed `_frequencies` into `MLXFast.RoPE(...)`
- removed the strict key-fallback override and rely on underscore-key filtering

Reason:

- `freqs` is derived from config and should not be expected in checkpoint weights
- parameters whose names start with `_` are ignored by `MLX.Module.parameterIsValid`, so strict `.all` verification does not require it

### Memory API cleanup

The service originally used deprecated GPU cache APIs.

Changed:

- `GPU.set(cacheLimit:)` -> `Memory.cacheLimit`
- `GPU.clearCache()` -> `Memory.clearCache()`

This keeps the file clean against current MLX APIs.

## UI Change

The default app model was not changed.

[RSSReaderApp/Models/Models.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Models/Models.swift) still defaults to Gemma 3, which avoids destabilizing existing users.

Only the settings hint text was updated in [RSSReaderApp/Views/SettingsView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/SettingsView.swift) so a user can manually enter a Gemma 4 model id.

## Verification Method

The most reliable local verification during implementation was:

1. focused `swiftc -typecheck` on `MLXLocalService.swift`
2. full `xcodebuild` for the iOS target

The focused typecheck was useful because full app builds were initially blocked by an unrelated dependency issue.

## Upstream Build Blocker Encountered

The app build failed before reaching the Gemma 4 code because `mlx-audio-swift` was incompatible with the current MLX API.

The failing file was:

- `build/DerivedData/SourcePackages/checkouts/mlx-audio-swift/Sources/MLXAudioCore/MLX+Extensions.swift`

The problem:

- it used `MLXArray.zeros(..., type: Float16.self)`
- current MLX no longer accepted `Float16` in that path

Fix applied:

- use `MLXArray.zeros(..., dtype: dtype)` instead of `type: Float16.self`
- for generated float16 ranges, create a float array first, then cast with `.asType(.float16)`

Important:

- this dependency patch was made inside the checked-out SourcePackages directory under `build/DerivedData`
- it fixed the local build
- it is not durable across a fresh package resolve

If you repeat this in another app, make the package fix persistent by:

- pinning a patched fork, or
- vendoring the package, or
- updating to an upstream release that already includes the fix

## Reusing This In Another App

If another app already uses `mlx-swift-lm` through a local service layer, the minimum repeatable process is:

1. confirm upstream still lacks `gemma4` / `gemma4_text`
2. copy the app-local Gemma 4 model implementation into that app’s MLX service layer
3. register the model types at runtime
4. support nested `text_config`
5. sanitize `language_model.*` weights
6. ignore missing computed RoPE `freqs`
7. keep existing defaults on old models until Gemma 4 is proven stable
8. run both focused typecheck and full app build

## What Not To Change

Do not:

- remove or replace existing upstream registries for older model families
- switch the app default model to Gemma 4 immediately
- assume updating `mlx-swift` alone adds Gemma 4 support

The safe path is additive Gemma 4 support on top of the existing MLX integration.
