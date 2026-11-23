#!/usr/bin/env python3
"""Vá thư mục android/ và ios/ do `flutter create` sinh ra cho SMART DOCUMENT SCANNER.

Idempotent: chạy nhiều lần không bị nhân đôi nội dung.
- Android: quyền CAMERA (không xin quyền bộ nhớ), minSdk 24, tên app,
  MainActivity có kênh "sds/storage", proguard cho ML Kit.
- iOS: mô tả quyền Camera/Thư viện ảnh, hiện file xuất trong app Tệp,
  iOS 15.5 (yêu cầu của ML Kit), Podfile, kênh "sds/storage".
"""
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TPL = ROOT / "native_templates"
APP_NAME = "APP scan PDF"
IOS_MIN = "15.5"


def log(msg):
    print(f"[patch] {msg}")


def patch_android():
    manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
    s = manifest.read_text(encoding="utf-8")
    if "android.permission.CAMERA" not in s:
        s = s.replace(
            "<application",
            '<uses-permission android:name="android.permission.CAMERA" />\n'
            '    <uses-feature android:name="android.hardware.camera" android:required="false" />\n'
            "    <application",
            1,
        )
    s = re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', s, count=1)
    manifest.write_text(s, encoding="utf-8")
    log("AndroidManifest.xml")

    for name in ("build.gradle.kts", "build.gradle"):
        g = ROOT / "android/app" / name
        if not g.exists():
            continue
        t = g.read_text(encoding="utf-8")
        t = re.sub(r"minSdk\s*=\s*[\w.]+", "minSdk = 24", t)
        t = re.sub(r"minSdkVersion\s+[\w.]+", "minSdkVersion 24", t)
        g.write_text(t, encoding="utf-8")
        log(f"android/app/{name}: minSdk 24")

    acts = list((ROOT / "android/app/src/main").rglob("MainActivity.kt"))
    if not acts:
        sys.exit("Không tìm thấy MainActivity.kt – hãy chạy flutter create trước")
    for a in acts:
        pkg = re.search(r"^package\s+([\w.]+)", a.read_text(encoding="utf-8"), re.M).group(1)
        body = (TPL / "android/MainActivity.kt").read_text(encoding="utf-8")
        body = re.sub(r"^package\s+[\w.]+", f"package {pkg}", body, count=1, flags=re.M)
        a.write_text(body, encoding="utf-8")
        log(f"{a.relative_to(ROOT)} (package {pkg})")

    shutil.copy(TPL / "android/proguard-rules.pro", ROOT / "android/app/proguard-rules.pro")
    log("android/app/proguard-rules.pro")


PLIST_KEYS = {
    "NSCameraUsageDescription": "Ứng dụng dùng camera để chụp và scan tài liệu. Ảnh chỉ lưu trên máy của bạn.",
    "NSPhotoLibraryUsageDescription": "Cho phép chọn ảnh tài liệu có sẵn trong thư viện để scan.",
    "CFBundleDisplayName": APP_NAME,
}
PLIST_BOOLS = {"UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True}


def patch_ios():
    plist = ROOT / "ios/Runner/Info.plist"
    s = plist.read_text(encoding="utf-8")
    for k, v in PLIST_KEYS.items():
        if f"<key>{k}</key>" in s:
            s = re.sub(rf"(<key>{k}</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{v}\g<2>", s)
        else:
            s = s.replace("</dict>\n</plist>", f"\t<key>{k}</key>\n\t<string>{v}</string>\n</dict>\n</plist>")
    for k, v in PLIST_BOOLS.items():
        if f"<key>{k}</key>" not in s:
            s = s.replace("</dict>\n</plist>", f"\t<key>{k}</key>\n\t<{str(v).lower()}/>\n</dict>\n</plist>")
    plist.write_text(s, encoding="utf-8")
    log("ios/Runner/Info.plist")

    pbx = ROOT / "ios/Runner.xcodeproj/project.pbxproj"
    t = pbx.read_text(encoding="utf-8")
    t = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;", f"IPHONEOS_DEPLOYMENT_TARGET = {IOS_MIN};", t)
    pbx.write_text(t, encoding="utf-8")
    log(f"project.pbxproj: iOS {IOS_MIN}")

    shutil.copy(TPL / "ios/Podfile", ROOT / "ios/Podfile")
    log("ios/Podfile")

    delegate = ROOT / "ios/Runner/AppDelegate.swift"
    d = delegate.read_text(encoding="utf-8")
    if "SdsStoragePlugin" not in d:
        m = re.search(r"GeneratedPluginRegistrant\.register\(with:\s*([^)]+)\)", d)
        if not m:
            sys.exit("AppDelegate.swift có cấu trúc lạ – không chèn được kênh sds/storage")
        registry = m.group(1).strip()
        reg = (f'\n    if let r = {registry}.registrar(forPlugin: "SdsStoragePlugin") '
               f'{{ SdsStoragePlugin.register(with: r) }}')
        d = d[: m.end()] + reg + d[m.end():]
        d += (TPL / "ios/SdsStoragePlugin.swift.txt").read_text(encoding="utf-8")
        delegate.write_text(d, encoding="utf-8")
    log("ios/Runner/AppDelegate.swift")


if __name__ == "__main__":
    if (ROOT / "android").exists():
        patch_android()
    if (ROOT / "ios").exists():
        patch_ios()
    log("xong")
