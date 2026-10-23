#!/usr/bin/env python3
"""claude-code-pet 설치 도우미 (install.sh / uninstall.sh / add-pet.sh 가 부른다).

    settings-install   ~/.claude/settings.json 에 펫 훅을 병합한다 (기존 훅은 그대로)
    settings-uninstall 펫 훅만 골라서 뺀다
    lua-install        ~/.hammerspoon/init.lua 에 위젯을 켜는 블록을 추가한다
    lua-uninstall      그 블록을 뺀다
    set-pet            ~/.claude-pet/config.json 의 pet 을 바꾼다

원칙: 이미 있는 설정은 보존하고, 여러 번 실행해도 결과가 같고(멱등), 바꾸기 전에 백업을 만들고,
JSON 이 깨져 있으면 손대지 않고 멈춘다. 표준 라이브러리만 쓴다.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import time
from typing import Any, Optional

PET_ID_RE = re.compile(r"[a-z0-9-]+")  # ASCII 만 (str.islower() 는 유니코드도 통과시킨다)

# (이벤트, matcher, 상태). matcher 가 None 이면 matcher 없이 등록한다.
HOOK_EVENTS: list[tuple[str, Optional[str], str]] = [
    ("SessionStart", "*", "idle"),
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", "*", "working"),
    ("PostToolUse", "*", "working"),
    ("PermissionRequest", "*", "waiting"),
    ("Notification", "permission_prompt|elicitation_dialog", "waiting"),
    ("Stop", None, "done"),
    ("SessionEnd", "*", "end"),
]
HOOK_TIMEOUT_SEC = 5

LUA_BEGIN = "-- >>> claude-code-pet >>>"
LUA_END = "-- <<< claude-code-pet <<<"
LUA_BLOCK = "\n".join([
    LUA_BEGIN,
    'local ok, err = pcall(function() require("claude-pet").start() end)',
    'if not ok then hs.printf("claude-pet: %s", tostring(err)) end',
    LUA_END,
]) + "\n"


class SetupError(Exception):
    """사용자에게 그대로 보여 줄 수 있는 오류."""


# --------------------------------------------------------------------------
# 파일 입출력
# --------------------------------------------------------------------------
def load_json(path: str) -> dict[str, Any]:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
        if not raw.strip():
            return {}  # 비어 있는 파일은 새 파일과 같게 다룬다
        data = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise SetupError("%s 을(를) 읽을 수 없습니다 (JSON 이 깨져 있으면 먼저 고쳐 주세요): %s" % (path, exc))
    if not isinstance(data, dict):
        raise SetupError("%s 의 최상위가 JSON 객체가 아닙니다. 손대지 않았습니다." % path)
    return data


def read_text(path: str) -> str:
    """줄바꿈(CRLF 등)을 바꾸지 않고 읽는다."""
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def backup(path: str) -> Optional[str]:
    """바꾸기 전에 백업을 만든다. 파일이 없으면 None.

    백업에도 비밀(토큰 등)이 들어 있을 수 있어서 처음부터 0600 으로 만들고,
    원본 모드는 쓰고 난 뒤에 맞춘다. 같은 초에 두 번 돌려도 이전 백업을 덮지 않는다.
    """
    real = os.path.realpath(path)
    if not os.path.exists(real):
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = "%s.bak-claude-pet-%s" % (real, stamp)
    n = 0
    while os.path.exists(dest):
        n += 1
        dest = "%s.bak-claude-pet-%s-%d" % (real, stamp, n)
    mode = os.stat(real).st_mode & 0o777
    with open(real, "rb") as src:
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(src.read())
            out.flush()
            os.fchmod(out.fileno(), mode)
    return dest


def write_atomic(path: str, text: str, default_mode: int = 0o600) -> None:
    """같은 폴더의 임시 파일에 쓰고 바꿔치기한다.

    심볼릭 링크(dotfiles 관리 도구)는 링크가 가리키는 실제 파일을 바꾸고 링크는 그대로 둔다.
    임시 파일은 처음부터 0600 으로 만들고, 기존 파일이 있으면 그 모드를 이어받는다.
    """
    real = os.path.realpath(path)
    os.makedirs(os.path.dirname(real) or ".", mode=0o700, exist_ok=True)
    mode = os.stat(real).st_mode & 0o777 if os.path.exists(real) else default_mode
    tmp = real + ".tmp-claude-pet"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
            f.flush()
            os.fchmod(f.fileno(), mode)
            os.fsync(f.fileno())
        os.replace(tmp, real)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise


def write_json(path: str, data: dict[str, Any]) -> None:
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


# --------------------------------------------------------------------------
# Claude Code settings.json
# --------------------------------------------------------------------------
def _state_script(hooks_dir: str) -> str:
    return os.path.join(hooks_dir, "pet-state.sh")


def _runs_script(command: str, script: str) -> bool:
    """명령이 script 를 실행하는지. 따옴표(경로에 ' 가 있을 때의 '"'"' 포함)를 풀어서 비교한다."""
    try:
        return script in shlex.split(command)
    except ValueError:
        return script in command


def _strip_pet(entry: Any, script: str) -> Any:
    """entry 에서 펫 훅만 뺀다. 남는 훅이 없으면 None, 사용자가 같은 항목에 넣어 둔 다른 훅은 그대로 둔다."""
    if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
        return entry
    rest = [h for h in entry["hooks"]
            if not (isinstance(h, dict) and _runs_script(str(h.get("command", "")), script))]
    if len(rest) == len(entry["hooks"]):
        return entry
    return {**entry, "hooks": rest} if rest else None


def add_hooks(settings: dict[str, Any], hooks_dir: str) -> bool:
    """펫 훅을 넣는다. 이미 있는 펫 항목은 새 항목으로 바꿔 중복을 막는다. 바뀌었으면 True."""
    script = _state_script(hooks_dir)
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SetupError("settings.json 의 hooks 가 객체가 아닙니다. 손대지 않았습니다.")
    before = json.dumps(settings, sort_keys=True)
    for event, matcher, state in HOOK_EVENTS:
        current = hooks.get(event, [])
        if not isinstance(current, list):
            raise SetupError("settings.json 의 hooks.%s 가 배열이 아닙니다. 손대지 않았습니다." % event)
        kept = [e for e in (_strip_pet(e, script) for e in current) if e is not None]
        entry: dict[str, Any] = {
            "hooks": [{"type": "command", "command": "bash %s %s" % (shlex.quote(script), state),
                       "timeout": HOOK_TIMEOUT_SEC}],
        }
        if matcher is not None:
            entry = {"matcher": matcher, **entry}
        hooks[event] = kept + [entry]
    return json.dumps(settings, sort_keys=True) != before


def remove_hooks(settings: dict[str, Any], hooks_dir: str) -> bool:
    script = _state_script(hooks_dir)
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    changed = False
    for event in list(hooks):
        current = hooks[event]
        if not isinstance(current, list):
            continue
        kept = [e for e in (_strip_pet(e, script) for e in current) if e is not None]
        if kept != current:
            changed = True
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
    if changed and not hooks:
        del settings["hooks"]
    return changed


def _usage_wrapper(hooks_dir: str) -> str:
    return "bash %s" % shlex.quote(os.path.join(hooks_dir, "pet-usage.sh"))


def wrap_statusline(settings: dict[str, Any], hooks_dir: str, orig_path: str, write_orig: bool = True) -> bool:
    """상태줄을 사용량 기록 래퍼로 감싼다 (원래 상태줄은 그대로 실행된다). 원본은 orig_path 에 보관.

    원래 명령은 `sh -c '<원본>'` 으로 넘겨서 `FOO=1 cmd`, `a && b` 같은 셸 문법도 그대로 동작한다.
    write_orig=False(--dry-run)면 아무 파일도 쓰지 않는다.
    """
    wrapper = _usage_wrapper(hooks_dir)
    current = settings.get("statusLine")
    if isinstance(current, dict) and str(current.get("command", "")).startswith(wrapper):
        return False  # 이미 감쌌다
    if write_orig:
        write_json(orig_path, {"statusLine": current})
    if isinstance(current, dict) and current.get("command"):
        settings["statusLine"] = {**current, "command": "%s sh -c %s" % (wrapper, shlex.quote(str(current["command"])))}
    else:
        settings["statusLine"] = {"type": "command", "command": wrapper}
    return True


def unwrap_statusline(settings: dict[str, Any], hooks_dir: str, orig_path: str) -> bool:
    wrapper = _usage_wrapper(hooks_dir)
    current = settings.get("statusLine")
    if not (isinstance(current, dict) and str(current.get("command", "")).startswith(wrapper)):
        return False
    # 지금 명령에서 래퍼를 벗기는 것이 우선이다 (설치 뒤에 명령을 고쳤어도 그 내용이 유지되고,
    # 보관본 파일이 깨졌어도 제거가 멈추지 않는다). 보관본은 벗길 명령이 없을 때의 폴백이다.
    rest = str(current["command"])[len(wrapper):].strip()
    try:
        parts = shlex.split(rest)
        if len(parts) == 3 and parts[:2] == ["sh", "-c"]:
            rest = parts[2]
    except ValueError:
        pass
    if rest:
        settings["statusLine"] = {**current, "command": rest}
        return True
    original = None
    if os.path.exists(orig_path):
        try:
            original = load_json(orig_path).get("statusLine")
        except SetupError:
            original = None
    if original is None:
        del settings["statusLine"]
    else:
        settings["statusLine"] = original
    return True


# --------------------------------------------------------------------------
# ~/.hammerspoon/init.lua
# --------------------------------------------------------------------------
def add_lua_block(text: str) -> tuple[str, bool]:
    if LUA_BEGIN in text:
        return text, False
    sep = "" if (not text or text.endswith("\n\n")) else ("\n" if text.endswith("\n") else "\n\n")
    return text + sep + LUA_BLOCK, True


def remove_lua_block(text: str) -> tuple[str, bool]:
    start = text.find(LUA_BEGIN)
    end = text.find(LUA_END)
    if start == -1 or end == -1 or end < start:
        return text, False
    end += len(LUA_END)
    if text[end:end + 1] == "\n":
        end += 1
    head = text[:start].rstrip("\n")
    tail = text[end:]
    out = head + ("\n" if head and tail else "") + tail
    if head and not tail:
        out = head + "\n"
    return out, True


# --------------------------------------------------------------------------
# 명령
# --------------------------------------------------------------------------
def cmd_settings_install(args: argparse.Namespace) -> str:
    settings = load_json(args.settings)
    changed = add_hooks(settings, args.hooks_dir)
    if args.statusline:
        orig = os.path.join(args.home, "statusline.orig.json")
        changed = wrap_statusline(settings, args.hooks_dir, orig, write_orig=not args.dry_run) or changed
    if not changed:
        return "settings.json: 이미 설정돼 있습니다 (변경 없음)"
    if args.dry_run:
        return "settings.json: 훅 %d개를 추가할 예정 (--dry-run, 파일은 그대로)" % len(HOOK_EVENTS)
    bak = backup(args.settings)
    write_json(args.settings, settings)
    return "settings.json: 훅 %d개 추가%s" % (len(HOOK_EVENTS), " (백업: %s)" % bak if bak else "")


def cmd_settings_uninstall(args: argparse.Namespace) -> str:
    if not os.path.exists(args.settings):
        return "settings.json: 파일이 없어 할 일이 없습니다"
    settings = load_json(args.settings)
    changed = remove_hooks(settings, args.hooks_dir)
    changed = unwrap_statusline(settings, args.hooks_dir, os.path.join(args.home, "statusline.orig.json")) or changed
    if not changed:
        return "settings.json: 펫 항목이 없습니다 (변경 없음)"
    bak = backup(args.settings)
    write_json(args.settings, settings)
    return "settings.json: 펫 훅 제거%s" % (" (백업: %s)" % bak if bak else "")


def cmd_lua_install(args: argparse.Namespace) -> str:
    text = read_text(args.init) if os.path.exists(args.init) else ""
    new_text, changed = add_lua_block(text)
    if not changed:
        return "init.lua: 이미 들어 있습니다 (변경 없음)"
    if args.dry_run:
        return "init.lua: 위젯을 켜는 블록을 추가할 예정 (--dry-run, 파일은 그대로)"
    bak = backup(args.init)
    write_atomic(args.init, new_text, default_mode=0o644)
    return "init.lua: 위젯 블록 추가%s" % (" (백업: %s)" % bak if bak else "")


def cmd_lua_uninstall(args: argparse.Namespace) -> str:
    if not os.path.exists(args.init):
        return "init.lua: 파일이 없어 할 일이 없습니다"
    text = read_text(args.init)
    new_text, changed = remove_lua_block(text)
    if not changed:
        return "init.lua: 위젯 블록이 없습니다 (변경 없음)"
    bak = backup(args.init)
    write_atomic(args.init, new_text, default_mode=0o644)
    return "init.lua: 위젯 블록 제거%s" % (" (백업: %s)" % bak if bak else "")


def cmd_set_pet(args: argparse.Namespace) -> str:
    if not PET_ID_RE.fullmatch(args.pet):
        raise SetupError("펫 id 는 영문 소문자, 숫자, 하이픈만 쓸 수 있습니다: %s" % args.pet)
    if not os.path.exists(os.path.join(args.home, "pets", args.pet, "pet.json")):
        raise SetupError("펫이 설치돼 있지 않습니다: %s/pets/%s" % (args.home, args.pet))
    path = os.path.join(args.home, "config.json")
    config = load_json(path)
    if args.if_unset and config.get("pet"):
        return "config.json: 쓰던 펫 유지 (pet = %s)" % config["pet"]
    config["pet"] = args.pet
    write_json(path, config)
    return "config.json: pet = %s" % args.pet


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser, *, settings: bool = False, init: bool = False) -> None:
        if settings:
            p.add_argument("--settings", required=True, help="~/.claude/settings.json")
            p.add_argument("--hooks-dir", required=True, help="pet-state.sh 가 있는 폴더")
            p.add_argument("--home", required=True, help="~/.claude-pet")
        if init:
            p.add_argument("--init", required=True, help="~/.hammerspoon/init.lua")

    p = sub.add_parser("settings-install")
    common(p, settings=True)
    p.add_argument("--statusline", action="store_true", help="상태줄을 사용량 기록 래퍼로 감싼다 (Pro/Max)")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_settings_install)

    p = sub.add_parser("settings-uninstall")
    common(p, settings=True)
    p.set_defaults(func=cmd_settings_uninstall)

    p = sub.add_parser("lua-install")
    common(p, init=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_lua_install)

    p = sub.add_parser("lua-uninstall")
    common(p, init=True)
    p.set_defaults(func=cmd_lua_uninstall)

    p = sub.add_parser("set-pet")
    p.add_argument("--home", required=True)
    p.add_argument("--pet", required=True)
    p.add_argument("--if-unset", action="store_true", help="config.json 에 pet 이 이미 있으면 바꾸지 않는다")
    p.set_defaults(func=cmd_set_pet)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        print(args.func(args))
    except SetupError as exc:
        print("오류: %s" % exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
