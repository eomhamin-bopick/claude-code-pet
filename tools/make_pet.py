#!/usr/bin/env python3
"""그림 한 장으로 Claude Code 펫을 만든다.

캐릭터 이미지 한 장을 받아서, Codex 펫과 같은 규격(8열 x 11줄, 칸 192x208)의
스프라이트 시트와 pet.json 을 만든다. 모션은 찌그러짐/늘어남/기울임/흔들림 같은
변형으로 만들기 때문에, 말랑한 젤리·유령·동그란 캐릭터에 특히 잘 어울린다.

사용법:
  python3 tools/make_pet.py character.png --id jelly --name "Jelly"
  python3 tools/make_pet.py character.png --id jelly --out pets/jelly --no-blink

필요한 것: Python 3.8+ 와 Pillow  (python3 -m pip install pillow)
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from typing import Any, Optional

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps
except ImportError:  # pragma: no cover
    sys.exit("Pillow 가 필요합니다:  python3 -m pip install pillow")

CELL_W, CELL_H = 192, 208
COLS = 8
# 줄별 프레임 수 (Codex 펫 규격 v2)
ROW_FRAMES = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]
ROW_NAMES = ["idle", "runRight", "runLeft", "wave", "jump", "failed",
             "waiting", "working", "review", "lookAround", "spin"]
SS = 2                       # 그릴 때만 쓰는 확대 배율 (가장자리를 부드럽게)
ANCHOR = (CELL_W / 2, 190)   # 발 밑 기준점(칸 좌표)
MAX_W, MAX_H = 160, 150      # 캐릭터가 차지할 기본 크기 (점프·늘어남 여유를 위에 남겨 둔다)


# --------------------------------------------------------------------------
# 이미지 준비
# --------------------------------------------------------------------------
def remove_background(im: Image.Image, tolerance: int) -> Image.Image:
    """투명 배경이 아니면 가장자리에서부터 같은 색을 지워 배경을 없앤다."""
    im = im.convert("RGBA")
    if im.getchannel("A").getextrema()[0] < 250:
        return im  # 이미 투명한 부분이 있다
    w, h = im.size
    px = im.load()
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    def near(c):
        return max(abs(c[0] - bg[0]), abs(c[1] - bg[1]), abs(c[2] - bg[2])) <= tolerance

    seen = bytearray(w * h)
    stack = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
    while stack:
        x, y = stack.pop()
        i = y * w + x
        if seen[i] or not near(px[x, y]):
            continue
        seen[i] = 1
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                stack.append((nx, ny))
    out = im.copy()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            if seen[y * w + x]:
                opx[x, y] = (bg[0], bg[1], bg[2], 0)
    # 가장자리를 살짝 부드럽게
    alpha = out.getchannel("A").filter(ImageFilter.GaussianBlur(0.8))
    out.putalpha(alpha)
    return out


def premul_resize(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    """투명한 가장자리에 하얀 테두리가 끼지 않게, 알파를 곱한 채로 크기를 바꾼다."""
    return im.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def prepare_character(im: Image.Image, scale_adjust: float = 1.0) -> Image.Image:
    """투명 영역을 잘라내고 칸에 맞는 크기(확대 배율 SS 적용)로 줄인다."""
    bbox = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox is None:
        sys.exit("투명하지 않은 픽셀이 없습니다. 이미지를 확인해 주세요.")
    im = im.crop(bbox)
    scale = min(MAX_W / im.width, MAX_H / im.height) * scale_adjust
    size = (max(1, round(im.width * scale * SS)), max(1, round(im.height * scale * SS)))
    return premul_resize(im, size)


# --------------------------------------------------------------------------
# 눈 깜빡임 (눈이 어두운 점 두 개일 때만)
# --------------------------------------------------------------------------
def _components(mask: bytearray, w: int, h: int, min_area: int) -> list[list[int]]:
    seen = bytearray(w * h)
    comps = []
    for start in range(w * h):
        if not mask[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        pixels = []
        while stack:
            i = stack.pop()
            pixels.append(i)
            x, y = i % w, i // w
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < w and 0 <= ny < h:
                    j = ny * w + nx
                    if mask[j] and not seen[j]:
                        seen[j] = 1
                        stack.append(j)
        if len(pixels) >= min_area:
            comps.append(pixels)
    return comps


def find_eyes(im: Image.Image) -> Optional[list[dict[str, Any]]]:
    """얼굴 쪽에 있는 크기가 비슷한 어두운 덩어리 두 개를 눈으로 본다. 못 찾으면 None."""
    w, h = im.size
    px = im.load()
    mask = bytearray(w * h)
    for y in range(int(h * 0.75)):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 200 and (r + g + b) / 3 < 120:
                mask[y * w + x] = 1
    comps = _components(mask, w, h, max(12, int(w * h * 0.0004)))
    eyes = []
    for pix in comps:
        xs = [i % w for i in pix]
        ys = [i // w for i in pix]
        bw, bh = max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
        if not 0.5 <= bw / bh <= 2.0:
            continue
        eyes.append({"pix": pix, "cx": sum(xs) / len(xs), "cy": sum(ys) / len(ys),
                     "rx": bw / 2, "ry": bh / 2, "area": len(pix)})
    best = None
    for i in range(len(eyes)):
        for j in range(i + 1, len(eyes)):
            a, b = eyes[i], eyes[j]
            if abs(a["cy"] - b["cy"]) > h * 0.08 or abs(a["cx"] - b["cx"]) < w * 0.08:
                continue
            if min(a["area"], b["area"]) / max(a["area"], b["area"]) < 0.5:
                continue
            score = min(a["area"], b["area"])
            if best is None or score > best[0]:
                best = (score, [a, b])
    return best[1] if best else None


def eye_variant(im: Image.Image, eyes: Optional[list[dict[str, Any]]], openness: float) -> Image.Image:
    """openness 1.0 = 그대로, 0.45 = 반쯤 감김, 0 = 완전히 감김."""
    if openness >= 0.999 or not eyes:
        return im
    w, h = im.size
    out = im.copy()
    px = out.load()
    layer = Image.new("RGBA", (w * 4, h * 4), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for e in eyes:
        r = max(e["rx"], e["ry"])
        pad = int(r * 0.6) + 2
        x0, x1 = int(e["cx"] - e["rx"]) - pad, int(e["cx"] + e["rx"]) + pad
        y0, y1 = int(e["cy"] - e["ry"]) - pad, int(e["cy"] + e["ry"]) + pad
        # 눈 색(가장 어두운 픽셀 평균)과 주변 바탕색(밝은 픽셀 평균)
        dark = [px[i % w, i // w] for i in e["pix"]]
        dark.sort(key=lambda c: c[0] + c[1] + c[2])
        core = dark[: max(1, len(dark) // 3)]
        eye_rgb = tuple(sum(c[k] for c in core) // len(core) for k in range(3))
        ring = []
        for yy in range(max(0, y0 - 4), min(h, y1 + 5)):
            for xx in range(max(0, x0 - 4), min(w, x1 + 5)):
                if x0 <= xx <= x1 and y0 <= yy <= y1:
                    continue
                c = px[xx, yy]
                if c[3] > 200 and (c[0] + c[1] + c[2]) / 3 > 150:
                    ring.append(c)
        if not ring:
            continue
        fill = tuple(sum(c[k] for c in ring) // len(ring) for k in range(3)) + (255,)
        for yy in range(max(0, y0), min(h, y1 + 1)):
            for xx in range(max(0, x0), min(w, x1 + 1)):
                c = px[xx, yy]
                if c[3] > 100 and (c[0] + c[1] + c[2]) / 3 < 190:
                    px[xx, yy] = fill
        cx, cy, rx, ry = e["cx"] * 4, e["cy"] * 4, e["rx"] * 4, e["ry"] * 4
        col = eye_rgb + (255,)
        if openness > 0.05:
            hh = max(ry * openness, ry * 0.25)
            draw.ellipse((cx - rx, cy + ry * 0.2 - hh, cx + rx, cy + ry * 0.2 + hh), fill=col)
        else:
            t = max(2 * 4, int(ry * 0.5))
            draw.arc((cx - rx * 1.15, cy - ry * 1.0, cx + rx * 1.15, cy + ry * 1.0), 20, 160, fill=col, width=t)
    layer = premul_resize(layer, (w, h))
    out.alpha_composite(layer)
    # 눈 바깥으로 번지지 않게 원래 알파를 유지
    out.putalpha(ImageChops.multiply(out.getchannel("A"), im.getchannel("A")))
    return out


# --------------------------------------------------------------------------
# 모션: 한 프레임의 자세를 dict 로 표현 (dx,dy: 칸 픽셀 / sx,sy: 배율 / rot: 도 / k: 기울임)
# --------------------------------------------------------------------------
def pose(**kw: Any) -> dict[str, Any]:
    d = {"dx": 0.0, "dy": 0.0, "sx": 1.0, "sy": 1.0, "rot": 0.0, "k": 0.0,
         "eyes": 1.0, "tint": None, "flip": False}
    d.update(kw)
    return d


def motion(row: int, n: int, has_eyes: bool) -> list[dict[str, Any]]:
    ph = [2 * math.pi * i / n for i in range(n)]
    if row == 0:  # idle: 숨쉬기 + 눈 깜빡임
        blink = [1.0, 0.45, 0.0, 0.45, 1.0, 1.0]
        breathe = [(1.000, 1.000), (1.000, 1.000), (1.010, 0.995), (1.000, 1.000), (1.022, 0.988), (1.008, 0.996)]
        if not has_eyes:
            breathe = [(1 + 0.025 * math.sin(p), 1 - 0.015 * math.sin(p)) for p in ph]
        return [pose(sy=breathe[i][0], sx=breathe[i][1], eyes=blink[i] if has_eyes else 1.0) for i in range(n)]
    if row in (1, 2):  # 달리기: 통통 뛰며 진행 방향으로 기울기 (2번 줄은 좌우 반전)
        out = []
        for i in range(n):
            hop = abs(math.sin(ph[i]))
            out.append(pose(dy=-8 * hop, sy=0.94 + 0.11 * hop, sx=1.05 - 0.09 * hop,
                            rot=6 + 2 * math.sin(2 * ph[i]), flip=(row == 2)))
        return out
    if row == 3:  # 손 흔들기: 좌우로 갸우뚱
        rot = [-6, 0, 6, 0]
        dy = [0, -3, 0, -3]
        return [pose(rot=rot[i], dy=dy[i]) for i in range(n)]
    if row == 4:  # 점프: 웅크림 → 도약 → 정점 → 낙하 → 착지
        seq = [(0, 0.86, 1.10), (-10, 1.08, 0.94), (-18, 1.03, 0.98), (-9, 1.06, 0.96), (0, 0.90, 1.08)]
        return [pose(dy=s[0], sy=s[1], sx=s[2]) for s in seq]
    if row == 5:  # 실패: 부들부들 떨며 처짐 + 살짝 어두운 색
        dx = [0, -5, 5, -4, 4, -2, 2, 0]
        rot = [0, -3, 3, -2, 2, -1, 1, 0]
        return [pose(dx=dx[i], rot=rot[i], sy=0.94, sx=1.04, tint=(0.88, 0.9, 0.98)) for i in range(n)]
    if row == 6:  # 대기: 천천히 좌우로 흔들흔들
        return [pose(dx=3 * math.sin(p), rot=4 * math.sin(p), dy=-1.5 * (1 - math.cos(p)) / 2) for p in ph]
    if row == 7:  # 작업 중: 타닥타닥 작게 튀며 앞으로 숙임
        return [pose(dy=-3 * abs(math.sin(p)), rot=2.5 + 1.5 * math.sin(2 * p), sy=0.98 + 0.03 * abs(math.sin(p)))
                for p in ph]
    if row == 8:  # 살펴보기: 고개를 갸웃
        return [pose(rot=9 * math.sin(p), dy=-2 * (1 - math.cos(p)) / 2, sx=1.02) for p in ph]
    if row == 9:  # 두리번: 좌우로 몸을 빼 보기
        return [pose(dx=7 * math.sin(p), k=-0.14 * math.sin(p), sx=1 - 0.12 * abs(math.sin(p)), rot=4 * math.sin(p))
                for p in ph]
    # row == 10: 빙글 (좌우 폭이 줄었다 반대로 뒤집히며 한 바퀴)
    out = []
    for p in ph:
        c = math.cos(p)
        out.append(pose(sx=max(0.14, abs(c)), flip=c < 0, dy=-3 * abs(math.sin(p))))
    return out


# --------------------------------------------------------------------------
# 그리기
# --------------------------------------------------------------------------
def render(base: Image.Image, p: dict[str, Any]) -> Image.Image:
    """base(확대 배율 SS, 발 밑이 아래 가운데)를 자세 p로 변형해 한 칸(CELL_W x CELL_H)을 만든다."""
    W, H = CELL_W * SS, CELL_H * SS
    bw, bh = base.size
    ax, ay = bw / 2, bh
    dxp = (ANCHOR[0] + p["dx"]) * SS
    dyp = (ANCHOR[1] + p["dy"]) * SS
    th = math.radians(p["rot"])
    c, s = math.cos(th), math.sin(th)
    k, sx, sy = p["k"], p["sx"], p["sy"]
    a = (c + k * s) / sx
    b = (s - k * c) / sx
    d = -s / sy
    e = c / sy
    data = (a, b, ax - a * dxp - b * dyp, d, e, ay - d * dxp - e * dyp)
    char = base.convert("RGBa").transform((W, H), Image.AFFINE, data, resample=Image.BICUBIC).convert("RGBA")
    if p["tint"]:
        r, g, bch, al = char.split()
        t = p["tint"]
        char = Image.merge("RGBA", (r.point(lambda v: int(v * t[0])), g.point(lambda v: int(v * t[1])),
                                    bch.point(lambda v: int(v * t[2])), al))

    cell = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # 바닥 그림자: 높이 뜰수록 작고 옅게
    lift = max(0.0, -p["dy"])
    shrink = max(0.45, 1 - lift / 70)
    sw = base.width / SS * 0.46 * shrink * (p["sx"] if p["sx"] > 0.5 else 0.5)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        ((ANCHOR[0] - sw) * SS, (ANCHOR[1] + 1 - 5 * shrink) * SS, (ANCHOR[0] + sw) * SS, (ANCHOR[1] + 1 + 5 * shrink) * SS),
        fill=(40, 40, 60, int(54 * shrink)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(3 * SS))
    cell.alpha_composite(shadow)
    cell.alpha_composite(char)
    if p["flip"]:
        cell = ImageOps.mirror(cell)
    return premul_resize(cell, (CELL_W, CELL_H))


def build_sheet(character: Image.Image, blink: bool = True) -> tuple[Image.Image, bool]:
    eyes = find_eyes(character) if blink else None
    variants = {1.0: character}
    if eyes:
        variants[0.45] = eye_variant(character, eyes, 0.45)
        variants[0.0] = eye_variant(character, eyes, 0.0)
    sheet = Image.new("RGBA", (CELL_W * COLS, CELL_H * len(ROW_FRAMES)), (0, 0, 0, 0))
    for row, n in enumerate(ROW_FRAMES):
        for i, p in enumerate(motion(row, n, bool(eyes))):
            base = variants.get(p["eyes"], character)
            sheet.alpha_composite(render(base, p), (i * CELL_W, row * CELL_H))
    return sheet, bool(eyes)


# --------------------------------------------------------------------------
# 미리보기
# --------------------------------------------------------------------------
def contact_sheet(sheet: Image.Image, path: str) -> None:
    bg = Image.new("RGBA", (sheet.width // 2 + 70, sheet.height // 2), (244, 241, 238, 255))
    d = ImageDraw.Draw(bg)
    for row, n in enumerate(ROW_FRAMES):
        d.text((6, row * CELL_H // 2 + CELL_H // 4 - 6), "%d %s" % (row, ROW_NAMES[row]), fill=(120, 60, 60, 255))
        for i in range(n):
            cell = sheet.crop((i * CELL_W, row * CELL_H, (i + 1) * CELL_W, (row + 1) * CELL_H))
            cell = cell.resize((CELL_W // 2, CELL_H // 2), Image.LANCZOS)
            bg.alpha_composite(cell, (70 + i * CELL_W // 2, row * CELL_H // 2))
    bg.convert("RGB").save(path)


def preview_gif(sheet: Image.Image, path: str) -> None:
    """README 에 쓸 짧은 GIF: 숨쉬기 → 작업 중 → 점프 → 대기 → 달리기."""
    plan = [(0, 0.5, 2), (7, 0.22, 3), (4, 0.12, 2), (6, 0.25, 2), (1, 0.09, 3)]
    frames, durations = [], []
    for row, sec, repeats in plan:
        for _ in range(repeats):
            for i in range(ROW_FRAMES[row]):
                cell = sheet.crop((i * CELL_W, row * CELL_H, (i + 1) * CELL_W, (row + 1) * CELL_H))
                bg = Image.new("RGBA", cell.size, (244, 241, 238, 255))
                bg.alpha_composite(cell)
                frames.append(bg.convert("P", palette=Image.ADAPTIVE, colors=128))
                durations.append(int(sec * 1000) if row != 0 else [1200, 100, 140, 100, 400, 400][i])
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durations, loop=0, disposal=2)


def main() -> None:
    ap = argparse.ArgumentParser(description="그림 한 장으로 Claude Code 펫 만들기")
    ap.add_argument("image", help="캐릭터 이미지 (PNG 권장, 배경이 투명하면 가장 좋음)")
    ap.add_argument("--id", required=True, help="펫 id (영문 소문자·숫자·하이픈)")
    ap.add_argument("--name", help="표시 이름 (기본: id)")
    ap.add_argument("--out", help="출력 폴더 (기본: pets/<id>)")
    ap.add_argument("--tolerance", type=int, default=8,
                    help="배경 제거 허용 오차 (배경이 불투명할 때만). 클수록 많이 지우고, 캐릭터 가장자리가 깎일 수 있다")
    ap.add_argument("--scale", type=float, default=1.0, help="캐릭터 크기 보정 (1.0 = 기본)")
    ap.add_argument("--no-blink", action="store_true", help="눈 깜빡임을 만들지 않는다")
    ap.add_argument("--no-preview", action="store_true", help="미리보기 파일을 만들지 않는다")
    args = ap.parse_args()

    if not args.id or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in args.id):
        sys.exit("--id 는 영문 소문자, 숫자, 하이픈만 쓸 수 있습니다.")
    out = args.out or os.path.join("pets", args.id)
    os.makedirs(out, exist_ok=True)

    im = remove_background(Image.open(args.image), args.tolerance)
    character = prepare_character(im, args.scale)
    sheet, blinks = build_sheet(character, blink=not args.no_blink)

    sheet.save(os.path.join(out, "spritesheet.png"), optimize=True)
    meta = {
        "id": args.id,
        "displayName": args.name or args.id,
        "description": "%s - 그림 한 장으로 tools/make_pet.py 가 만든 펫" % (args.name or args.id),
        "spriteVersionNumber": 2,
        "spritesheetPath": "spritesheet.png",
    }
    if not blinks:
        # 눈을 못 찾았거나 --no-blink: 깜빡임 타이밍 대신 고르게 숨쉬는 박자
        meta["animations"] = {"idle": {"secs": 0.25}}
    with open(os.path.join(out, "pet.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")
    if not args.no_preview:
        contact_sheet(sheet, os.path.join(out, "preview.png"))
        preview_gif(sheet, os.path.join(out, "preview.gif"))
    print("만들었습니다: %s  (눈 깜빡임: %s)" % (out, "있음" if blinks else "없음"))


if __name__ == "__main__":
    main()
