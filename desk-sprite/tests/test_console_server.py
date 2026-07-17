import importlib.util
import stat
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "console_server.py"
SPEC = importlib.util.spec_from_file_location("console_server", MODULE_PATH)
console_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(console_server)


class ConsoleSecurityTests(unittest.TestCase):
    def test_allows_only_loopback_host_for_bound_port(self):
        self.assertTrue(console_server.host_is_allowed("127.0.0.1:17890", 17890))
        self.assertTrue(console_server.host_is_allowed("localhost:17890", 17890))
        self.assertFalse(console_server.host_is_allowed("attacker.example:17890", 17890))
        self.assertFalse(console_server.host_is_allowed("127.0.0.1:9999", 17890))

    def test_rejects_cross_origin_browser_requests(self):
        self.assertTrue(
            console_server.origin_is_allowed(
                "http://127.0.0.1:17890", "same-origin", 17890
            )
        )
        self.assertFalse(
            console_server.origin_is_allowed(
                "https://attacker.example", "cross-site", 17890
            )
        )
        self.assertFalse(
            console_server.origin_is_allowed(
                "http://localhost:9999", "same-origin", 17890
            )
        )

    def test_rejects_multiline_config_values(self):
        with self.assertRaises(ValueError):
            console_server.validate_config(
                {"OPENCLAW_ROOT": "/tmp/openclaw\nINJECTED_COMMAND=1"}
            )

    def test_validates_gateway_scheme_and_start_script(self):
        with self.assertRaises(ValueError):
            console_server.validate_config({"OPENCLAW_GATEWAY_URL": "https://example.com"})
        with self.assertRaises(ValueError):
            console_server.validate_config({"OPENCLAW_START_SCRIPT": "relative.command"})

    def test_saved_environment_is_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".desk-sprite.env"
            console_server.save_env(
                path,
                console_server.validate_config(
                    {
                        "OPENCLAW_ROOT": "/tmp/openclaw workspace",
                        "OPENCLAW_GATEWAY_URL": "ws://127.0.0.1:18789",
                        "OPENCLAW_GATEWAY_TOKEN": "literal-$(not-executed)",
                    }
                ),
            )
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertEqual(mode, stat.S_IRUSR | stat.S_IWUSR)
            self.assertNotIn("\nINJECTED", path.read_text(encoding="utf-8"))

    def test_localizes_folder_picker_prompt(self):
        self.assertEqual(
            console_server.picker_prompt("en"),
            "Choose the OpenClaw state folder",
        )
        self.assertEqual(
            console_server.picker_prompt("ja"),
            "OpenClaw の状態フォルダーを選択",
        )
        self.assertEqual(
            console_server.picker_prompt("unsupported"),
            "选择 OpenClaw 状态目录",
        )

    def test_language_config_preserves_quick_prompts(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous_path = console_server.PROMPTS_PATH
            console_server.PROMPTS_PATH = Path(tmp) / "console_config.json"
            try:
                console_server.save_prompts(["Action one", "Action two"])
                console_server.save_language("ja")
                self.assertEqual(console_server.load_language(), "ja")
                self.assertEqual(
                    console_server.load_prompts(),
                    ["Action one", "Action two"],
                )
                with self.assertRaises(ValueError):
                    console_server.save_language("unsupported")
            finally:
                console_server.PROMPTS_PATH = previous_path


if __name__ == "__main__":
    unittest.main()
