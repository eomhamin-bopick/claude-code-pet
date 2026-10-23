"""tools/make_pet.py 테스트: 합성 캐릭터로 시트 규격·프레임·눈 깜빡임·배경 제거·CLI 를 확인한다."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    raise unittest.SkipTest("Pillow 가 없어 건너뜁니다")

TOOLS = os.path.join(os.path.dirname(__file__), "..", "tools")
sys.path.insert(0, TOOLS)
import make_pet  # noqa: E402


def blob(transparent: bool = True, eyes: bool = True) -> Image.Image:
    """파란 젤리 덩어리 + 어두운 눈 두 개."""
    bg = (0, 0, 0, 0) if transparent else (255, 255, 255, 255)
    im = Image.new("RGBA", (240, 260), bg)
    d = ImageDraw.Draw(im)
    d.ellipse((30, 40, 210, 250), fill=(120, 190, 240, 255))
    if eyes:
        d.ellipse((85, 110, 107, 134), fill=(20, 40, 130, 255))
        d.ellipse((133, 110, 155, 134), fill=(20, 40, 130, 255))
    return im


def cell(sheet: Image.Image, row: int, col: int) -> Image.Image:
    w, h = make_pet.CELL_W, make_pet.CELL_H
    return sheet.crop((col * w, row * h, (col + 1) * w, (row + 1) * h))


class SheetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        character = make_pet.prepare_character(blob())
        cls.sheet, cls.blinks = make_pet.build_sheet(character)

    def test_sheet_matches_codex_pet_grid(self) -> None:
        self.assertEqual(self.sheet.size, (make_pet.CELL_W * 8, make_pet.CELL_H * 11))
        self.assertEqual(make_pet.ROW_FRAMES, [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8])

    def test_every_frame_is_drawn_and_unused_cells_are_empty(self) -> None:
        for row, count in enumerate(make_pet.ROW_FRAMES):
            for col in range(8):
                box = cell(self.sheet, row, col).getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
                if col < count:
                    self.assertIsNotNone(box, "비어 있는 프레임: row %d col %d" % (row, col))
                else:
                    self.assertIsNone(box, "빈 칸이어야 함: row %d col %d" % (row, col))

    def test_no_frame_touches_the_cell_border(self) -> None:
        for row, count in enumerate(make_pet.ROW_FRAMES):
            for col in range(count):
                box = cell(self.sheet, row, col).getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
                self.assertIsNotNone(box)
                left, top, right, bottom = box
                self.assertGreater(left, 0, "왼쪽이 잘림 row %d col %d" % (row, col))
                self.assertGreater(top, 0, "위쪽이 잘림 row %d col %d" % (row, col))
                self.assertLess(right, make_pet.CELL_W, "오른쪽이 잘림 row %d col %d" % (row, col))
                self.assertLess(bottom, make_pet.CELL_H, "아래쪽이 잘림 row %d col %d" % (row, col))

    def test_blink_is_detected_and_changes_idle_frames(self) -> None:
        self.assertTrue(self.blinks)
        open_eyes = cell(self.sheet, 0, 0).tobytes()
        closed_eyes = cell(self.sheet, 0, 2).tobytes()
        self.assertNotEqual(open_eyes, closed_eyes)

    def test_run_left_is_mirror_of_run_right(self) -> None:
        right = cell(self.sheet, 1, 3)
        left = cell(self.sheet, 2, 3)
        mirrored = right.transpose(Image.FLIP_LEFT_RIGHT)
        diff = sum(abs(a - b) for a, b in zip(mirrored.tobytes(), left.tobytes())) / len(left.tobytes())
        self.assertLess(diff, 2.0)

    def test_jump_rises_and_lands(self) -> None:
        def bottom(col: int) -> int:
            return cell(self.sheet, 4, col).getchannel("A").point(lambda v: 255 if v > 80 else 0).getbbox()[3]
        self.assertLess(bottom(2), bottom(0) - 10)  # 정점에서는 바닥에서 떠 있다
        self.assertAlmostEqual(bottom(4), bottom(0), delta=3)  # 착지하면 처음 높이로


class PreparationTest(unittest.TestCase):
    def test_eyeless_character_has_no_blink(self) -> None:
        character = make_pet.prepare_character(blob(eyes=False))
        self.assertIsNone(make_pet.find_eyes(character))
        _, blinks = make_pet.build_sheet(character)
        self.assertFalse(blinks)

    def test_opaque_background_is_removed(self) -> None:
        cleaned = make_pet.remove_background(blob(transparent=False), tolerance=24)
        self.assertEqual(cleaned.getpixel((2, 2))[3], 0)       # 모서리 = 배경 = 투명
        self.assertEqual(cleaned.getpixel((120, 180))[3], 255)  # 몸통은 그대로

    def test_already_transparent_image_is_untouched(self) -> None:
        original = blob()
        self.assertEqual(make_pet.remove_background(original, 24).tobytes(), original.tobytes())


class CliTest(unittest.TestCase):
    def test_cli_writes_pet_json_and_sheet(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "character.png")
            blob().save(src)
            out = os.path.join(tmp, "pets", "demo")
            run = subprocess.run(
                [sys.executable, os.path.join(TOOLS, "make_pet.py"), src, "--id", "demo", "--name", "Demo",
                 "--out", out, "--no-preview"],
                capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            with open(os.path.join(out, "pet.json"), encoding="utf-8") as f:
                meta = json.load(f)
            self.assertEqual(meta["id"], "demo")
            self.assertEqual(meta["displayName"], "Demo")
            self.assertEqual(meta["spriteVersionNumber"], 2)
            self.assertNotIn("animations", meta)  # 눈이 있으면 기본 깜빡임 박자를 쓴다
            with Image.open(os.path.join(out, "spritesheet.png")) as sheet:
                self.assertEqual(sheet.size, (1536, 2288))

    def test_cli_without_blink_overrides_idle_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "c.png")
            blob().save(src)
            out = os.path.join(tmp, "p")
            subprocess.run([sys.executable, os.path.join(TOOLS, "make_pet.py"), src, "--id", "x", "--out", out,
                            "--no-blink", "--no-preview"], check=True, capture_output=True)
            with open(os.path.join(out, "pet.json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["animations"], {"idle": {"secs": 0.25}})

    def test_cli_rejects_bad_id(self) -> None:
        run = subprocess.run([sys.executable, os.path.join(TOOLS, "make_pet.py"), "x.png", "--id", "Bad Id"],
                             capture_output=True, text=True, check=False)
        self.assertNotEqual(run.returncode, 0)


if __name__ == "__main__":
    unittest.main()
