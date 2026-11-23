#!/usr/bin/env python3
"""Rà soát dự án APP scan PDF trước khi đẩy lên GitHub.

Kiểm tra:
  1. Đủ các file bắt buộc (kể cả thư mục ẩn .github/).
  2. Mọi import tương đối / package:smart_document_scanner/... trỏ tới file có thật.
  3. Mọi asset khai báo trong pubspec.yaml tồn tại.
  4. Ngoặc (), [], {} cân bằng trong từng file Dart (bỏ qua chuỗi & chú thích).
  5. Script mà CI / Vercel gọi tới tồn tại.
  6. So khớp với FILES.md (danh sách + mã SHA-256) để phát hiện file thiếu/hỏng khi upload.

Dùng:  python3 scripts/check_files.py            # kiểm tra
       python3 scripts/check_files.py --write    # cập nhật FILES.md
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = "smart_document_scanner"

REQUIRED = [
    "pubspec.yaml", "analysis_options.yaml", ".gitignore", "README.md", "vercel.json",
    ".github/workflows/build.yml",
    "lib/main.dart",
    "assets/fonts/DejaVuSans.ttf", "assets/fonts/DejaVu-LICENSE.txt",
    "scripts/bootstrap.sh", "scripts/patch_platforms.py", "scripts/vercel_build.sh",
    "scripts/check_files.py",
    "native_templates/android/MainActivity.kt", "native_templates/android/proguard-rules.pro",
    "native_templates/ios/Podfile", "native_templates/ios/SdsStoragePlugin.swift.txt",
    "site/index.html", "site/config.js",
]
SKIP_DIRS = {".git", ".dart_tool", "build", "__pycache__", ".idea"}
# android/ và ios/ ở GỐC dự án do flutter create sinh ra trên CI – không phải native_templates/
SKIP_TOP = {"android", "ios"}
MANIFEST = ROOT / "FILES.md"


def all_files():
    out = []
    for p in sorted(ROOT.rglob("*")):
        rel = p.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts) or rel.parts[0] in SKIP_TOP or p.is_dir():
            continue
        if rel.as_posix() == "FILES.md":
            continue
        out.append(rel.as_posix())
    return out


def sha(p):
    return hashlib.sha256((ROOT / p).read_bytes()).hexdigest()


def strip_dart(src):
    """Bỏ chú thích và nội dung chuỗi để đếm ngoặc."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        raw = c == "r" and i + 1 < n and src[i + 1] in "'\"" and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_"))
        if c in "'\"" or raw:
            if raw:
                i += 1
                c = src[i]
            triple = src.startswith(c * 3, i)
            q = c * 3 if triple else c
            i += len(q)
            while i < n:
                if not raw and src[i] == "\\":
                    i += 2
                    continue
                if not raw and src.startswith("${", i):
                    # nội suy: tìm '}' khớp (có thể lồng)
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if src[i] == "{":
                            depth += 1
                        elif src[i] == "}":
                            depth -= 1
                        i += 1
                    continue
                if src.startswith(q, i):
                    i += len(q)
                    break
                if not triple and src[i] == "\n":
                    break  # chuỗi chưa đóng trên một dòng
                i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_brackets(path):
    s = strip_dart((ROOT / path).read_text(encoding="utf-8"))
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in s:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                return f"ngoặc '{ch}' thừa/sai ở dòng ~{line}"
            stack.pop()
    if stack:
        return f"ngoặc '{stack[-1][0]}' mở ở dòng {stack[-1][1]} chưa đóng"
    return None


def main():
    write = "--write" in sys.argv
    errors, warns = [], []
    files = all_files()
    fileset = set(files)

    for r in REQUIRED:
        if r not in fileset:
            errors.append(f"THIẾU file bắt buộc: {r}")

    dart = [f for f in files if f.endswith(".dart")]
    imp = re.compile(r"""^\s*(?:import|export|part)\s+['"]([^'"]+)['"]""", re.M)
    for f in dart:
        src = (ROOT / f).read_text(encoding="utf-8")
        for m in imp.finditer(src):
            u = m.group(1)
            if u.startswith("dart:"):
                continue
            if u.startswith("package:"):
                if not u.startswith(f"package:{PKG}/"):
                    continue  # gói bên ngoài – kiểm tra ở pubspec
                target = "lib/" + u[len(f"package:{PKG}/"):]
            else:
                target = (pathlib.PurePosixPath(f).parent / u).as_posix()
                parts = []
                for part in target.split("/"):
                    if part == "..":
                        parts.pop()
                    elif part != ".":
                        parts.append(part)
                target = "/".join(parts)
            if target not in fileset:
                errors.append(f"{f}: import '{u}' → không có file {target}")
        b = check_brackets(f)
        if b:
            errors.append(f"{f}: {b}")

    # gói bên ngoài được dùng phải khai báo trong pubspec
    pub = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    used = set()
    for f in dart:
        used |= set(re.findall(r"package:([a-z0-9_]+)/", (ROOT / f).read_text(encoding="utf-8")))
    for p in sorted(used - {PKG, "flutter", "flutter_test"}):
        if not re.search(rf"^\s+{p}:", pub, re.M):
            errors.append(f"Gói '{p}' được import nhưng chưa khai báo trong pubspec.yaml")

    for a in re.findall(r"^\s+-\s+(assets/\S+)", pub, re.M):
        if a not in fileset:
            errors.append(f"pubspec.yaml khai báo asset không tồn tại: {a}")

    wf = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8") if ".github/workflows/build.yml" in fileset else ""
    for s in re.findall(r"(scripts/[\w./-]+)", wf + (ROOT / "vercel.json").read_text(encoding="utf-8")):
        if s not in fileset:
            errors.append(f"CI/Vercel gọi tới script không tồn tại: {s}")

    tests = [f for f in files if f.startswith("test/") and f.endswith("_test.dart")]
    if not tests:
        warns.append("Không có file kiểm thử trong test/")

    if write:
        lines = ["# Danh sách file dự án (tự sinh bởi scripts/check_files.py --write)", "",
                 f"Tổng: **{len(files)} file**. Thư mục `android/`, `ios/` KHÔNG cần upload –",
                 "chúng được sinh tự động bởi `scripts/bootstrap.sh` trên GitHub Actions.", "",
                 "| File | Byte | SHA-256 (12 ký tự đầu) |", "|---|---:|---|"]
        for f in files:
            lines.append(f"| `{f}` | {(ROOT / f).stat().st_size} | {sha(f)[:12]} |")
        MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Đã ghi FILES.md ({len(files)} file)")
    elif MANIFEST.exists():
        listed = {}
        for m in re.finditer(r"^\| `([^`]+)` \| (\d+) \| ([0-9a-f]{12}) \|", MANIFEST.read_text(encoding="utf-8"), re.M):
            listed[m.group(1)] = m.group(3)
        for f, h in listed.items():
            if f not in fileset:
                errors.append(f"THIẾU so với FILES.md: {f}")
            elif sha(f)[:12] != h:
                warns.append(f"Khác nội dung so với FILES.md (đã sửa sau khi lập danh sách?): {f}")
        for f in files:
            if f not in listed:
                warns.append(f"File mới chưa có trong FILES.md: {f}")

    print(f"Đã rà soát {len(files)} file, {len(dart)} file Dart, {len(tests)} file kiểm thử.")
    for w in warns:
        print("  CẢNH BÁO:", w)
    for e in errors:
        print("  LỖI:", e)
    if errors:
        print(f"KẾT QUẢ: {len(errors)} lỗi – CHƯA đủ điều kiện upload.")
        sys.exit(1)
    print("KẾT QUẢ: ĐẦY ĐỦ – sẵn sàng upload.")


if __name__ == "__main__":
    main()
