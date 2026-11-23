#!/usr/bin/env sh
# Chạy trên Vercel: ghi tên repo GitHub vào site/config.js để nút "Tải APK" trỏ đúng.
set -e
OWNER="${VERCEL_GIT_REPO_OWNER:-}"
SLUG="${VERCEL_GIT_REPO_SLUG:-}"
if [ -n "$OWNER" ] && [ -n "$SLUG" ]; then
  printf 'window.APP_REPO = "%s/%s";\n' "$OWNER" "$SLUG" > site/config.js
  echo "Đã cấu hình repo: $OWNER/$SLUG"
else
  echo "Không có biến VERCEL_GIT_REPO_* – giữ nguyên site/config.js"
fi
test -f site/index.html || { echo "THIẾU site/index.html"; exit 1; }
