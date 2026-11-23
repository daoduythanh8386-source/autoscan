#!/usr/bin/env bash
# Sinh thư mục android/ và ios/ bằng flutter create rồi vá cấu hình cho ứng dụng.
# Chạy từ thư mục gốc dự án:  bash scripts/bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/.."

flutter --version
# flutter create KHÔNG ghi đè file đã có (lib/, pubspec.yaml, test/...).
flutter create \
  --org vn.smartscanner \
  --project-name smart_document_scanner \
  --platforms android,ios \
  .
python3 scripts/patch_platforms.py
flutter pub get
echo "Bootstrap hoàn tất."
