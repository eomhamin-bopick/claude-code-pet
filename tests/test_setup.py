"""tools/claude_pet_setup.py 테스트: 병합·멱등·제거·보존·오류 처리 (임시 폴더에서만 동작)."""
from __future__ import annotations

import json
import os
import shlex
import stat
import sys
import tempfile
import unittest
from typing import Any

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import claude_pet_setup as setup  # noqa: E402

HOOKS_DIR = "/home/test/.claude-pet/hooks"
USER_HOOK = {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]}


def pet_commands(settings: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for entries in settings.get("hooks", {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                if "pet-state.sh" in hook.get("command", ""):
                    out.append(hook["command"])
    return out


class HookMergeTest(unittest.TestCase):
    def test_adds_all_events_to_empty_settings(self) -> None:
        settings: dict[str, Any] = {}
        self.assertTrue(setup.add_hooks(settings, HOOKS_DIR))
        self.assertEqual(set(settings["hooks"]), {e for e, _, _ in setup.HOOK_EVENTS})
        self.assertEqual(len(pet_commands(settings)), len(setup.HOOK_EVENTS))

    def test_is_idempotent(self) -> None:
        settings: dict[str, Any] = {}
        setup.add_hooks(settings, HOOKS_DIR)
        snapshot = json.dumps(settings, sort_keys=True)
        self.assertFalse(setup.add_hooks(settings, HOOKS_DIR))
        self.assertEqual(json.dumps(settings, sort_keys=True), snapshot)
        self.assertEqual(len(pet_commands(settings)), len(setup.HOOK_EVENTS))

    def test_keeps_existing_hooks_and_other_keys(self) -> None:
        settings: dict[str, Any] = {"model": "x", "hooks": {"Stop": [USER_HOOK], "Custom": [USER_HOOK]}}
        setup.add_hooks(settings, HOOKS_DIR)
        self.assertEqual(settings["model"], "x")
        self.assertIn(USER_HOOK, settings["hooks"]["Stop"])
        self.assertEqual(settings["hooks"]["Custom"], [USER_HOOK])
        self.assertEqual(len(settings["hooks"]["Stop"]), 2)

    def test_remove_restores_original(self) -> None:
        original: dict[str, Any] = {"model": "x", "hooks": {"Stop": [USER_HOOK]}}
        settings = json.loads(json.dumps(original))
        setup.add_hooks(settings, HOOKS_DIR)
        self.assertTrue(setup.remove_hooks(settings, HOOKS_DIR))
        self.assertEqual(settings, original)

    def test_remove_drops_empty_hooks_key(self) -> None:
        settings: dict[str, Any] = {}
        setup.add_hooks(settings, HOOKS_DIR)
        setup.remove_hooks(settings, HOOKS_DIR)
        self.assertEqual(settings, {})

    def test_path_with_space_is_quoted(self) -> None:
        settings: dict[str, Any] = {}
        setup.add_hooks(settings, "/Users/a b/.claude-pet/hooks")
        self.assertTrue(all("'/Users/a b/" in c for c in pet_commands(settings)))

    def test_rejects_malformed_hooks(self) -> None:
        with self.assertRaises(setup.SetupError):
            setup.add_hooks({"hooks": []}, HOOKS_DIR)
        with self.assertRaises(setup.SetupError):
            setup.add_hooks({"hooks": {"Stop": {}}}, HOOKS_DIR)

    def test_apostrophe_in_path_is_idempotent_and_removable(self) -> None:
        # shlex.quote 는 ' 를 '"'"' 로 바꾼다. 그래도 이미 넣은 훅을 알아봐야 한다.
        hooks_dir = "/Users/John O'Brien/.claude-pet/hooks"
        settings: dict[str, Any] = {}
        setup.add_hooks(settings, hooks_dir)
        setup.add_hooks(settings, hooks_dir)
        setup.add_hooks(settings, hooks_dir)
        self.assertEqual(len(pet_commands(settings)), len(setup.HOOK_EVENTS))
        self.assertTrue(setup.remove_hooks(settings, hooks_dir))
        self.assertEqual(settings, {})

    def test_remove_keeps_a_user_hook_sharing_the_same_entry(self) -> None:
        script = os.path.join(HOOKS_DIR, "pet-state.sh")
        shared = {"hooks": [
            {"type": "command", "command": "bash %s done" % shlex.quote(script)},
            {"type": "command", "command": "echo mine"},
        ]}
        settings: dict[str, Any] = {"hooks": {"Stop": [shared]}}
        self.assertTrue(setup.remove_hooks(settings, HOOKS_DIR))
        self.assertEqual(settings["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "echo mine"}]}])


class StatuslineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.orig = os.path.join(self.tmp.name, "statusline.orig.json")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_wrap_and_unwrap_existing_statusline(self) -> None:
        original = {"type": "command", "command": "node /x/line.js"}
        settings: dict[str, Any] = {"statusLine": dict(original)}
        self.assertTrue(setup.wrap_statusline(settings, HOOKS_DIR, self.orig))
        self.assertIn("pet-usage.sh", settings["statusLine"]["command"])
        # 원래 명령은 sh -c '<원본>' 으로 넘어간다 (셸 문법을 그대로 살리려고)
        self.assertEqual(shlex.split(settings["statusLine"]["command"])[-3:], ["sh", "-c", "node /x/line.js"])
        self.assertFalse(setup.wrap_statusline(settings, HOOKS_DIR, self.orig))  # 두 번 감싸지 않는다
        self.assertTrue(setup.unwrap_statusline(settings, HOOKS_DIR, self.orig))
        self.assertEqual(settings["statusLine"], original)

    def test_shell_syntax_survives_wrap_and_fallback_unwrap(self) -> None:
        command = "FOO=1 node /x/line.js && echo 'a b'"
        settings: dict[str, Any] = {"statusLine": {"type": "command", "command": command}}
        setup.wrap_statusline(settings, HOOKS_DIR, self.orig)
        self.assertEqual(shlex.split(settings["statusLine"]["command"])[-1], command)
        os.unlink(self.orig)  # 보관본이 없어도 명령 문자열에서 원래대로 되돌린다
        self.assertTrue(setup.unwrap_statusline(settings, HOOKS_DIR, self.orig))
        self.assertEqual(settings["statusLine"]["command"], command)

    def test_unwrap_prefers_the_current_command_and_survives_a_broken_orig_file(self) -> None:
        settings: dict[str, Any] = {"statusLine": {"type": "command", "command": "echo old", "padding": 2}}
        setup.wrap_statusline(settings, HOOKS_DIR, self.orig)
        # 설치 뒤에 사용자가 감싼 명령 안의 내용을 고쳤다면 그 내용이 유지된다
        settings["statusLine"]["command"] = settings["statusLine"]["command"].replace("echo old", "echo edited")
        with open(self.orig, "w", encoding="utf-8") as f:
            f.write("{ broken")  # 보관본이 깨져 있어도 제거가 멈추지 않는다
        self.assertTrue(setup.unwrap_statusline(settings, HOOKS_DIR, self.orig))
        self.assertEqual(settings["statusLine"], {"type": "command", "command": "echo edited", "padding": 2})

    def test_dry_run_does_not_write_the_orig_file(self) -> None:
        settings: dict[str, Any] = {"statusLine": {"type": "command", "command": "echo hi"}}
        self.assertTrue(setup.wrap_statusline(settings, HOOKS_DIR, self.orig, write_orig=False))
        self.assertFalse(os.path.exists(self.orig))

    def test_wrap_when_no_statusline_then_unwrap_removes_it(self) -> None:
        settings: dict[str, Any] = {}
        setup.wrap_statusline(settings, HOOKS_DIR, self.orig)
        self.assertIn("pet-usage.sh", settings["statusLine"]["command"])
        setup.unwrap_statusline(settings, HOOKS_DIR, self.orig)
        self.assertNotIn("statusLine", settings)


class LuaBlockTest(unittest.TestCase):
    def test_add_to_empty_and_existing(self) -> None:
        text, changed = setup.add_lua_block("")
        self.assertTrue(changed)
        self.assertIn(setup.LUA_BEGIN, text)
        text2, changed2 = setup.add_lua_block('hs.alert.show("hi")\n')
        self.assertTrue(changed2)
        self.assertTrue(text2.startswith('hs.alert.show("hi")\n'))
        self.assertTrue(text2.rstrip().endswith(setup.LUA_END))

    def test_is_idempotent(self) -> None:
        text, _ = setup.add_lua_block("")
        again, changed = setup.add_lua_block(text)
        self.assertFalse(changed)
        self.assertEqual(again, text)

    def test_remove_restores_original(self) -> None:
        for original in ("", 'hs.alert.show("hi")\n', 'a = 1\nb = 2\n', "no newline at end"):
            text, _ = setup.add_lua_block(original)
            restored, changed = setup.remove_lua_block(text)
            self.assertTrue(changed)
            self.assertEqual(restored.strip(), original.strip())

    def test_remove_keeps_user_lines_after_block(self) -> None:
        text, _ = setup.add_lua_block("a = 1\n")
        text += "b = 2\n"
        restored, _ = setup.remove_lua_block(text)
        self.assertIn("a = 1", restored)
        self.assertIn("b = 2", restored)
        self.assertNotIn(setup.LUA_BEGIN, restored)


class CommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self.tmp.name, "claude", "settings.json")
        self.home = os.path.join(self.tmp.name, "pet-home")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_cli(self, *argv: str) -> int:
        return setup.main(list(argv))

    def test_install_creates_file_and_backs_up_on_change(self) -> None:
        base = ["settings-install", "--settings", self.settings, "--hooks-dir", HOOKS_DIR, "--home", self.home]
        self.assertEqual(self.run_cli(*base), 0)
        with open(self.settings, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(len(pet_commands(data)), len(setup.HOOK_EVENTS))
        before = sorted(os.listdir(os.path.dirname(self.settings)))
        self.assertEqual(self.run_cli(*base), 0)  # 두 번째는 변경 없음 -> 백업도 안 만든다
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.settings))), before)

    def test_dry_run_changes_nothing(self) -> None:
        self.assertEqual(self.run_cli("settings-install", "--settings", self.settings, "--hooks-dir", HOOKS_DIR,
                                      "--home", self.home, "--dry-run"), 0)
        self.assertFalse(os.path.exists(self.settings))

    def test_broken_json_is_left_alone(self) -> None:
        os.makedirs(os.path.dirname(self.settings))
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write("{ not json")
        code = self.run_cli("settings-install", "--settings", self.settings, "--hooks-dir", HOOKS_DIR,
                            "--home", self.home)
        self.assertEqual(code, 2)
        with open(self.settings, encoding="utf-8") as f:
            self.assertEqual(f.read(), "{ not json")

    def test_set_pet_requires_installed_pet(self) -> None:
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "jelly"), 2)
        os.makedirs(os.path.join(self.home, "pets", "jelly"))
        with open(os.path.join(self.home, "pets", "jelly", "pet.json"), "w", encoding="utf-8") as f:
            f.write("{}")
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "jelly"), 0)
        with open(os.path.join(self.home, "config.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"pet": "jelly"})

    def test_set_pet_rejects_bad_id(self) -> None:
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "../evil"), 2)
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "ab²"), 2)  # 유니코드 숫자
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "éa"), 2)  # 비ASCII 소문자

    def test_set_pet_if_unset_keeps_the_pet_in_use(self) -> None:
        for name in ("jelly", "mine"):
            os.makedirs(os.path.join(self.home, "pets", name))
            with open(os.path.join(self.home, "pets", name, "pet.json"), "w", encoding="utf-8") as f:
                f.write("{}")
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "mine"), 0)
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "jelly", "--if-unset"), 0)
        with open(os.path.join(self.home, "config.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"pet": "mine"})  # 다시 설치해도 쓰던 펫이 유지된다
        self.assertEqual(self.run_cli("set-pet", "--home", self.home, "--pet", "jelly"), 0)  # 직접 지정하면 바뀐다
        with open(os.path.join(self.home, "config.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"pet": "jelly"})

    def test_empty_settings_file_is_treated_as_new(self) -> None:
        os.makedirs(os.path.dirname(self.settings))
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write("  \n")
        code = self.run_cli("settings-install", "--settings", self.settings, "--hooks-dir", HOOKS_DIR,
                            "--home", self.home)
        self.assertEqual(code, 0)
        with open(self.settings, encoding="utf-8") as f:
            self.assertEqual(len(pet_commands(json.load(f))), len(setup.HOOK_EVENTS))

    def test_dry_run_with_statusline_writes_nothing(self) -> None:
        os.makedirs(os.path.dirname(self.settings))
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write('{"statusLine": {"type": "command", "command": "echo hi"}}')
        code = self.run_cli("settings-install", "--settings", self.settings, "--hooks-dir", HOOKS_DIR,
                            "--home", self.home, "--statusline", "--dry-run")
        self.assertEqual(code, 0)
        self.assertFalse(os.path.exists(self.home))  # statusline.orig.json 도, 폴더도 만들지 않는다
        self.assertEqual(os.listdir(os.path.dirname(self.settings)), ["settings.json"])


class FileSafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def mode(self, path: str) -> int:
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_write_through_symlink_keeps_the_link(self) -> None:
        target = os.path.join(self.dir, "dotfiles", "settings.json")
        os.makedirs(os.path.dirname(target))
        with open(target, "w", encoding="utf-8") as f:
            f.write("{}")
        link = os.path.join(self.dir, "settings.json")
        os.symlink(target, link)
        setup.write_atomic(link, '{"a": 1}')
        self.assertTrue(os.path.islink(link))
        with open(target, encoding="utf-8") as f:
            self.assertEqual(f.read(), '{"a": 1}')

    def test_existing_mode_is_kept_and_new_files_are_private(self) -> None:
        path = os.path.join(self.dir, "settings.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("{}")
        os.chmod(path, 0o600)
        setup.write_atomic(path, "{}")
        self.assertEqual(self.mode(path), 0o600)
        fresh = os.path.join(self.dir, "new", "settings.json")
        setup.write_atomic(fresh, "{}")
        self.assertEqual(self.mode(fresh), 0o600)
        lua = os.path.join(self.dir, "init.lua")
        setup.write_atomic(lua, "x", default_mode=0o644)
        self.assertEqual(self.mode(lua), 0o644)
        self.assertEqual([n for n in os.listdir(self.dir) if n.endswith(".tmp-claude-pet")], [])

    def test_backup_keeps_mode_and_never_overwrites_an_earlier_backup(self) -> None:
        path = os.path.join(self.dir, "settings.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("first")
        os.chmod(path, 0o600)
        first = setup.backup(path)
        with open(path, "w", encoding="utf-8") as f:
            f.write("second")
        second = setup.backup(path)  # 같은 초에 두 번 불러도
        assert first is not None and second is not None
        self.assertNotEqual(first, second)
        with open(first, encoding="utf-8") as f:
            self.assertEqual(f.read(), "first")
        self.assertEqual(self.mode(first), 0o600)
        self.assertIsNone(setup.backup(os.path.join(self.dir, "missing.json")))

    def test_init_lua_line_endings_are_preserved(self) -> None:
        init = os.path.join(self.dir, "init.lua")
        with open(init, "w", encoding="utf-8", newline="") as f:
            f.write('hs.alert.show("hi")\r\nlocal x = 1\r\n')
        self.assertEqual(setup.main(["lua-install", "--init", init]), 0)
        with open(init, "r", encoding="utf-8", newline="") as f:
            installed = f.read()
        self.assertTrue(installed.startswith('hs.alert.show("hi")\r\nlocal x = 1\r\n'))
        self.assertEqual(setup.main(["lua-uninstall", "--init", init]), 0)
        with open(init, "r", encoding="utf-8", newline="") as f:
            self.assertEqual(f.read(), 'hs.alert.show("hi")\r\nlocal x = 1\r\n')


if __name__ == "__main__":
    unittest.main()
