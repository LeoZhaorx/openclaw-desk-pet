#!/usr/bin/env python3
"""Generate deterministic localized configuration and state-preview visuals."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "docs" / "assets" / "readme"

LOCALES = {
    "en": {
        "config_badge": "CONFIGURATION",
        "config_title": "DeskSprite Console",
        "config_intro": (
            "Manage the OpenClaw path, Gateway, and quick actions in one place. "
            "Changes save automatically; reload to apply them."
        ),
        "core_title": "Core settings",
        "core_help": "The directory should contain openclaw.json and agents/main/sessions.",
        "root_label": "OpenClaw state directory (OPENCLAW_ROOT)",
        "select_directory": "Select directory",
        "gateway_label": "Gateway URL (OPENCLAW_GATEWAY_URL)",
        "token_label": "Gateway token (optional)",
        "token_placeholder": "Leave blank to read from OpenClaw configuration",
        "startup_label": "Startup script (optional)",
        "fallback_label": "File fallback active window (seconds)",
        "reload": "Reload",
        "loaded": "Configuration loaded. Changes save automatically.",
        "quick_title": "Quick action settings",
        "quick_help": (
            "Each action syncs to the pet. Changes save automatically; click Reload "
            "to apply them. Drag the handles to reorder."
        ),
        "quick_actions": ["Read the latest AI news", "Check today's weather"],
        "cycle": [
            ("IDLE", "Waiting"),
            ("TOOLING", "Using tools"),
            ("SLEEPING", "Resting"),
        ],
    },
    "zh-cn": {
        "config_badge": "配置中心",
        "config_title": "DeskSprite 控制台",
        "config_intro": (
            "把配置集中在一处管理：OpenClaw 路径、网关，以及快捷按钮。"
            "修改会自动保存，点击重新载入即可生效。"
        ),
        "core_title": "基础配置",
        "core_help": "确保目录包含 openclaw.json 与 agents/main/sessions。",
        "root_label": "OpenClaw 状态目录（OPENCLAW_ROOT）",
        "select_directory": "选择目录",
        "gateway_label": "网关地址（OPENCLAW_GATEWAY_URL）",
        "token_label": "网关 Token（可选）",
        "token_placeholder": "留空则自动从 OpenClaw 配置读取",
        "startup_label": "启动脚本（可选）",
        "fallback_label": "文件回退活跃窗口（秒）",
        "reload": "重新载入",
        "loaded": "配置已载入。修改会自动保存。",
        "quick_title": "快捷按钮配置",
        "quick_help": (
            "每条按钮文案会同步到精灵端，修改会自动保存，点击重新载入生效。"
            "拖拽左侧手柄可调整顺序。"
        ),
        "quick_actions": ["看下最前沿 AI 新闻！", "查下今天的天气吧～"],
        "cycle": [
            ("IDLE", "待命"),
            ("TOOLING", "调用工具"),
            ("SLEEPING", "休眠"),
        ],
    },
    "ja": {
        "config_badge": "設定センター",
        "config_title": "DeskSprite コンソール",
        "config_intro": (
            "OpenClaw のパス、Gateway、クイックボタンを一か所で管理。"
            "変更は自動保存され、再読み込みで反映されます。"
        ),
        "core_title": "基本設定",
        "core_help": "openclaw.json と agents/main/sessions を含むディレクトリを指定します。",
        "root_label": "OpenClaw 状態ディレクトリ（OPENCLAW_ROOT）",
        "select_directory": "フォルダを選択",
        "gateway_label": "Gateway URL（OPENCLAW_GATEWAY_URL）",
        "token_label": "Gateway Token（任意）",
        "token_placeholder": "空欄の場合は OpenClaw の設定から読み込みます",
        "startup_label": "起動スクリプト（任意）",
        "fallback_label": "ファイルフォールバック有効時間（秒）",
        "reload": "再読み込み",
        "loaded": "設定を読み込みました。変更は自動保存されます。",
        "quick_title": "クイックボタン設定",
        "quick_help": (
            "各ボタンは Desk Pet と同期します。変更は自動保存され、再読み込みで反映。"
            "左のハンドルをドラッグして並べ替えられます。"
        ),
        "quick_actions": ["最新の AI ニュースを確認", "今日の天気を調べる"],
        "cycle": [
            ("IDLE", "待機"),
            ("TOOLING", "ツール実行"),
            ("SLEEPING", "休止"),
        ],
    },
}


def resolve_font(pattern: str) -> tuple[str, int]:
    result = subprocess.run(
        ["fc-match", "-f", "%{file}\n%{index}\n", pattern],
        check=True,
        capture_output=True,
        text=True,
    )
    lines = [line for line in result.stdout.splitlines() if line]
    return lines[0], int(lines[1] or "0")


FONT_CACHE: dict[tuple[str, str, int], ImageFont.FreeTypeFont] = {}


def font(locale: str, weight: str, size: int) -> ImageFont.FreeTypeFont:
    key = (locale, weight, size)
    if key in FONT_CACHE:
        return FONT_CACHE[key]
    if locale == "ja":
        pattern = "Hiragino Sans:style=W6" if weight == "bold" else "Hiragino Sans:style=W3"
    elif locale == "zh-cn":
        pattern = "PingFang SC:style=Semibold" if weight == "bold" else "PingFang SC:style=Regular"
    else:
        pattern = "Avenir Next:style=Demi Bold" if weight == "bold" else "Avenir Next:style=Regular"
    path, index = resolve_font(pattern)
    loaded = ImageFont.truetype(path, size=size, index=index)
    FONT_CACHE[key] = loaded
    return loaded


def text_width(draw: ImageDraw.ImageDraw, text: str, text_font: ImageFont.FreeTypeFont) -> float:
    box = draw.textbbox((0, 0), text, font=text_font)
    return box[2] - box[0]


def draw_centered(
    draw: ImageDraw.ImageDraw,
    xy: tuple[float, float],
    text: str,
    text_font: ImageFont.FreeTypeFont,
    fill: str,
) -> None:
    width = text_width(draw, text, text_font)
    draw.text((xy[0] - width / 2, xy[1]), text, font=text_font, fill=fill)


def wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    text_font: ImageFont.FreeTypeFont,
    max_width: int,
) -> list[str]:
    if not text:
        return []
    if " " not in text:
        lines: list[str] = []
        current = ""
        for char in text:
            candidate = current + char
            if current and text_width(draw, candidate, text_font) > max_width:
                lines.append(current)
                current = char
            else:
                current = candidate
        if current:
            lines.append(current)
        return lines
    words = text.split()
    lines = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if current and text_width(draw, candidate, text_font) > max_width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def draw_wrapped(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    text_font: ImageFont.FreeTypeFont,
    fill: str,
    max_width: int,
    line_gap: int = 8,
) -> int:
    y = xy[1]
    for line in wrap_text(draw, text, text_font, max_width):
        draw.text((xy[0], y), line, font=text_font, fill=fill)
        box = draw.textbbox((xy[0], y), line, font=text_font)
        y += box[3] - box[1] + line_gap
    return y


def save_jpeg(image: Image.Image, path: Path, quality: int = 90) -> None:
    image.convert("RGB").save(path, "JPEG", quality=quality, optimize=True, progressive=True)


def draw_input(
    draw: ImageDraw.ImageDraw,
    locale: str,
    label: str,
    value: str,
    y: int,
    with_button: str | None = None,
) -> int:
    left = 176
    right = 1255
    draw.text((left, y), label, font=font(locale, "bold", 19), fill="#23272b")
    field_y = y + 35
    button_font = font(locale, "bold", 15)
    button_width = int(text_width(draw, with_button, button_font)) + 30 if with_button else 0
    button_left = right - button_width
    field_right = button_left - 15 if with_button else right
    draw.rounded_rectangle(
        (left, field_y, field_right, field_y + 52),
        radius=16,
        fill="#f8fafb",
        outline="#d8dee4",
        width=2,
    )
    draw.text((left + 18, field_y + 14), value, font=font(locale if any(ord(c) > 127 for c in value) else "en", "regular", 17), fill="#60676d")
    if with_button:
        draw.rounded_rectangle(
            (button_left, field_y, right, field_y + 52),
            radius=16,
            fill="#edf3f2",
            outline="#cfd9d7",
            width=2,
        )
        draw_centered(draw, ((button_left + right) / 2, field_y + 14), with_button, button_font, "#252b2e")
    return field_y + 66


def build_config(locale: str, copy: dict[str, object]) -> None:
    canvas = Image.new("RGB", (1400, 1266), "#f5f3ee")
    draw = ImageDraw.Draw(canvas)
    dark = "#171b1f"
    muted = "#667079"
    teal = "#158f82"

    draw.rounded_rectangle((142, 58, 282, 96), radius=19, fill="#ddefe9")
    draw.ellipse((158, 72, 170, 84), fill="#20aa98")
    draw.text((179, 66), str(copy["config_badge"]), font=font(locale, "bold", 16), fill="#27877d")
    draw.text((142, 115), str(copy["config_title"]), font=font(locale, "bold", 40), fill=dark)
    draw_wrapped(draw, (142, 174), str(copy["config_intro"]), font(locale, "regular", 18), muted, 900, line_gap=5)

    draw.rounded_rectangle((142, 245, 1285, 982), radius=32, fill="#ffffff")
    draw.text((175, 280), str(copy["core_title"]), font=font(locale, "bold", 24), fill=dark)
    draw.text((175, 319), str(copy["core_help"]), font=font(locale, "regular", 17), fill=muted)
    y = 364
    y = draw_input(draw, locale, str(copy["root_label"]), "$HOME/.openclaw", y, str(copy["select_directory"]))
    y = draw_input(draw, locale, str(copy["gateway_label"]), "ws://127.0.0.1:18789", y)
    y = draw_input(draw, locale, str(copy["token_label"]), str(copy["token_placeholder"]), y)
    y = draw_input(draw, locale, str(copy["startup_label"]), "/absolute/path/to/start-openclaw.command", y)
    y = draw_input(draw, locale, str(copy["fallback_label"]), "20", y)

    button_width = max(126, int(text_width(draw, str(copy["reload"]), font(locale, "bold", 17))) + 42)
    draw.rounded_rectangle((175, y, 175 + button_width, y + 58), radius=17, fill="#14191d")
    draw_centered(draw, (175 + button_width / 2, y + 16), str(copy["reload"]), font(locale, "bold", 17), "#ffffff")
    draw.text((175, y + 78), str(copy["loaded"]), font=font(locale, "regular", 16), fill=teal)

    draw.rounded_rectangle((142, 995, 1285, 1242), radius=32, fill="#ffffff")
    draw.text((175, 1025), str(copy["quick_title"]), font=font(locale, "bold", 23), fill=dark)
    draw_wrapped(draw, (175, 1061), str(copy["quick_help"]), font(locale, "regular", 16), muted, 1020, line_gap=4)

    action_y = 1124
    for action in copy["quick_actions"]:
        draw.rounded_rectangle((175, action_y, 215, action_y + 46), radius=14, fill="#edf6f4")
        for dot_y in (action_y + 16, action_y + 25, action_y + 34):
            draw.ellipse((188, dot_y, 192, dot_y + 4), fill="#87979a")
            draw.ellipse((198, dot_y, 202, dot_y + 4), fill="#87979a")
        draw.rounded_rectangle((228, action_y, 1205, action_y + 46), radius=14, fill="#f9fbfc", outline="#d9e0e5", width=2)
        draw.text((248, action_y + 12), str(action), font=font(locale, "regular", 17), fill="#20252a")
        draw.text((1228, action_y + 11), "×", font=font("en", "regular", 19), fill="#778087")
        action_y += 58

    save_jpeg(canvas, ASSET_DIR / f"config-console-{locale}.jpg", quality=90)


def extract_frames(source: Path, output_dir: Path, count: int = 8) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-vf",
            "fps=4",
            "-frames:v",
            str(count),
            str(output_dir / "%03d.png"),
        ],
        check=True,
    )
    return sorted(output_dir.glob("*.png"))


def build_state_cycle(locale: str, copy: dict[str, object]) -> None:
    clips = [
        ROOT / "media" / "idle-core.mov",
        ROOT / "media" / "work-loop.mov",
        ROOT / "media" / "nap-loop.mov",
    ]
    frames: list[Image.Image] = []
    with tempfile.TemporaryDirectory(prefix="readme-state-cycle-") as temp:
        temp_dir = Path(temp)
        for index, (clip, (state, translated)) in enumerate(zip(clips, copy["cycle"])):
            extracted = extract_frames(clip, temp_dir / str(index))
            for frame_path in extracted:
                subject = Image.open(frame_path).convert("RGBA")
                canvas = Image.new("RGBA", (640, 420), "#f7efe4")
                draw = ImageDraw.Draw(canvas)
                draw.ellipse((-100, 260, 240, 560), fill="#dbe9df")
                draw.ellipse((430, -180, 760, 140), fill="#f5d3c7")
                subject.thumbnail((600, 360), Image.Resampling.LANCZOS)
                x = (640 - subject.width) // 2
                y = 66 + (320 - subject.height) // 2
                canvas.alpha_composite(subject, (x, y))
                label = f"{state} · {translated}"
                label_font = font(locale if locale != "en" else "en", "bold", 22)
                label_width = int(text_width(draw, label, label_font)) + 44
                left = (640 - label_width) // 2
                draw.rounded_rectangle((left, 20, left + label_width, 62), radius=21, fill="#fffaf4", outline="#e2c7b7", width=2)
                draw_centered(draw, (320, 30), label, label_font, "#3b3430")
                frames.append(canvas.convert("P", palette=Image.Palette.ADAPTIVE, colors=128))

    output = ASSET_DIR / f"state-cycle-{locale}.gif"
    frames[0].save(
        output,
        save_all=True,
        append_images=frames[1:],
        duration=180,
        loop=0,
        optimize=True,
        disposal=2,
    )


def main() -> None:
    for locale, copy in LOCALES.items():
        build_config(locale, copy)
        build_state_cycle(locale, copy)
    print("Generated localized configuration and state-preview assets for: " + ", ".join(LOCALES))


if __name__ == "__main__":
    main()
