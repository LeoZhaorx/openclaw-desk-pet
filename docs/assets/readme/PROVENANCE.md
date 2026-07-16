# README visual provenance

This directory contains publish-ready assets for the repository README.

## Source preservation

- `hero.jpg` is an AI-assisted edit derived from the repository's `desk-sprite/console/visuals/art-still.png`. The cat's identity, fur colors, green eyes, proportions, sitting pose, and photographic character were required to remain recognizable. The generated treatment changed the background and lighting only; exact product claims and UI were not generated into the image.
- `hero-v2.jpg` combines an AI-generated background with three real transparent animation frames exported from `media/idle-core.mov`, `media/work-loop.mov`, and `media/nap-loop.mov`. The OpenClaw app icon comes from `apps/macos/Icon.icon/Assets/openclaw-mac.png` in the official `openclaw/openclaw` repository. The title, Chinese tagline, and capability labels were composited deterministically with PingFang SC rather than generated into the image.
- `openclaw-desk-pet-flow.jpg` uses an AI-generated glass-panel background. The official OpenClaw icon, real project cat frame, Gateway label, directional relationship, and six application states were added deterministically so no product relationship or copy was invented by the image model.
- `openclaw-icon.jpg` is an optimized 384 px export of the official OpenClaw macOS icon. It is not redrawn or AI-generated.
- `config-console.jpg` comes from a real user-supplied DeskSprite control-console screenshot. The personal workspace path was replaced with the generic `$HOME/.openclaw`; no Token value or other secret is visible. The screenshot was then downscaled for GitHub.
- `demo-task.gif`, `demo-full.mp4`, `scene-quick-task.jpg`, `scene-subagent.jpg`, and `scene-result.jpg` were exported from the supplied real product recording `启动任务.mov`.
- `demo-text.gif` was exported from the supplied real product recording `录屏2026-05-07 15.19.46.mov`.
- `demo-sleep.gif` was exported from the supplied real product recording `已发布：睡觉.mov`.
- `scene-tools.jpg` was exported from the supplied real product recording `录屏2026-05-07 15.18.56.mov`.

The source recordings are intentionally not copied into the repository. Only compressed README exports are tracked.

## Generated hero prompt

Use case: ads-marketing. Create a wide GitHub README product-launch hero from the supplied real cat reference. Preserve the same golden cat, green eyes, face, fur colors, proportions, sitting pose, silhouette, and photographic realism. Replace only the plain background with a restrained charcoal-to-coral gradient, subtle cyan/violet activity lights, and blank translucent speech-bubble shapes. Keep negative space on the left. No readable text, logos, UI, device, watermark, extra animal, or invented product capability.

## Generated v2 background prompts

### Hero background

Use case: ads-marketing. Create a premium cinematic 16:9 background for an OpenClaw desktop-pet hero. Use a deep charcoal-to-midnight gradient, warm coral-red energy, cyan and violet light trails, generous title space, and three lower illuminated platforms. Background only: no cats, animals, people, text, letters, logos, icons, UI, or watermark.

### Relationship-diagram background

Use case: infographic-diagram. Create a clean wide macOS-style infographic foundation with a coral glass panel on the left, an amber-violet glass panel on the right, a central Gateway node space, two bidirectional data streams, and six orderly lower state-node spaces. Background and containers only: no text, letters, logos, icons, cats, people, UI, or watermark.

## Export notes

- Hero, relationship diagram, configuration screenshot, and stills: optimized JPEG.
- Motion previews: palette-optimized GIF at 6–8 fps and 320 px width.
- Full demo: H.264 MP4 at 360 px width, 24 fps, no audio, fast-start enabled.
- Exact copy remains in Markdown; repeated hero and diagram labels are deterministic overlays for visual scanning.
