# Service logo sources

These marks identify the monitored services. They are not BeaverMeter branding
and do not imply endorsement. Each mark belongs to its respective owner.

Retrieved from primary sources on 2026-10-03:

- `codex.svg`: OpenAI Blossom, the inline SVG from [OpenAI Developers](https://developers.openai.com/).
  See [OpenAI's design guidelines](https://openai.com/brand/). Codex intentionally uses the OpenAI mark.
- `claude.svg`: “Claude Spark - Clay.svg” from [Anthropic's official press kit](https://www.anthropic.com/press-kit).
- `cursor.svg`: “CUBE_2D_LIGHT.svg” from [Cursor's official brand archive](https://cursor.com/brand).
- `deepseek.svg`: [DeepSeek's official logo SVG](https://github.com/deepseek-ai/DeepSeek-LLM/blob/main/images/logo.svg).
  Rendering selects only the whale path; the wordmark remains in the source file.
- `antigravity.svg`: “Icon - Full Color” from [Google Antigravity's official press assets](https://antigravity.google/press),
  downloaded from [the linked SVG](https://antigravity.google/assets/image/brand/antigravity-icon__full-color.svg)
  on 2026-10-31. The original official geometry, masks, filters and colors are preserved.

Run `swift scripts/make_provider_assets.swift` from the repository root to
rebuild `Design/ProviderAssets`. It works offline using a nonpersistent WebKit
canvas. Output is transparent 256×256 PNG: an original-color variant and a white
alpha mask. Geometry and aspect ratio remain intact; four percent clear space is
added around the symbol. Antigravity is framed using its outer silhouette because
its masked color layers extend beyond the visible symbol. Pass provider names,
for example `swift scripts/make_provider_assets.swift antigravity`, to rebuild only
those marks. The app never downloads these assets at runtime.
