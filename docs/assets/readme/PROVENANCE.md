# README visual provenance

This directory contains publish-ready assets for the repository README.

## Source preservation

- `hero.jpg` is an AI-assisted edit derived from the repository's `desk-sprite/console/visuals/art-still.png`. The cat's identity, fur colors, green eyes, proportions, sitting pose, and photographic character were required to remain recognizable. The generated treatment changed the background and lighting only; exact product claims and UI were not generated into the image.
- `hero-v2.jpg` combines a warm, light AI-generated editorial background with three real transparent animation frames exported from `media/idle-core.mov`, `media/work-loop.mov`, and `media/nap-loop.mov`. The title, Chinese tagline, capability labels, and project mascot badge were composited deterministically with PingFang SC rather than generated into the image.
- `openclaw-desk-pet-flow.jpg` uses a warm ivory AI-generated information-design background. The official OpenClaw icon, real project cat frame, Gateway label, directional relationship, and six application states were added deterministically so no product relationship or copy was invented by the image model.
- `mascot-command.jpg` is an identity-preserving ImageGen composition: the project cat from `desk-sprite/console/visuals/art-still.png` rides and points forward from the official OpenClaw mascot. The final edit explicitly locks the project cat's round face, short muzzle, green eyes, golden shaded fur, compact body, and calm expression.
- `openclaw-icon.jpg` is an optimized 384 px export of the official OpenClaw macOS icon. It is not redrawn or AI-generated.
- `config-console.jpg` comes from a real user-supplied DeskSprite control-console screenshot. The personal workspace path was replaced with the generic `$HOME/.openclaw`; no Token value or other secret is visible. The screenshot was then downscaled for GitHub.
- `inspiration-real-cat.jpg` is a crop of the supplied real-life cat photo `IMG_4036.jpeg`. It was re-encoded without EXIF, GPS coordinates, device model, or capture time.
- `demo-task.gif`, `scene-quick-task.jpg`, `scene-subagent.jpg`, and `scene-result.jpg` were exported from the supplied real product recording `启动任务.mov`.
- `demo-text.gif` was exported from the supplied real product recording `录屏2026-05-07 15.19.46.mov`.
- `demo-sleep.gif` was exported from the supplied real product recording `已发布：睡觉.mov`.
- `scene-tools.jpg` was exported from the supplied real product recording `录屏2026-05-07 15.18.56.mov`.

The source recordings are intentionally not copied into the repository. Only compressed README exports are tracked.

## Generated hero prompt

Use case: ads-marketing. Create a wide GitHub README product-launch hero from the supplied real cat reference. Preserve the same golden cat, green eyes, face, fur colors, proportions, sitting pose, silhouette, and photographic realism. Replace only the plain background with a restrained charcoal-to-coral gradient, subtle cyan/violet activity lights, and blank translucent speech-bubble shapes. Keep negative space on the left. No readable text, logos, UI, device, watermark, extra animal, or invented product capability.

## Generated v2 background prompts

### Hero background

Use case: ads-marketing. Create a refined warm, light 16:9 editorial background for an OpenClaw desktop-pet hero. Use warm ivory paper, pale apricot and blush-coral shapes, restrained sky-blue accents, generous title space, and three carefully balanced display plinths. Background only: no cats, animals, people, text, letters, logos, icons, UI, or watermark.

### Relationship-diagram background

Use case: infographic-diagram. Create a premium warm-light information-design foundation on ivory paper with a pale-coral card on the left, pale-honey card on the right, a central Gateway node space, coral and muted-blue directional ribbons, and six evenly aligned state cards. Flat editorial styling, restrained shadows, no glassmorphism or neon. Background and containers only: no text, letters, logos, icons, cats, people, UI, or watermark.

### Mascot badge identity edit

Use case: identity-preserve. Edit the riding-and-pointing mascot composition so the cat unmistakably matches `art-still.png`: round face, short muzzle, compact cheeks, large green eyes, small pink nose, golden shaded fur, cream chin and chest, stocky body, and calm expression. Keep the exact riding pose, official OpenClaw character, dark rounded badge, and lighting unchanged. No text, extra limbs, clothing, or watermark.

## Export notes

- Hero, relationship diagram, configuration screenshot, and stills: optimized JPEG.
- Motion previews: palette-optimized GIF at 6–8 fps and 320 px width.
- Exact copy remains in Markdown; repeated hero and diagram labels are deterministic overlays for visual scanning.
