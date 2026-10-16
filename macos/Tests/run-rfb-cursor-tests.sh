#!/bin/bash
# Value decoder/geometry only: no AppKit, windows, sockets, guest or pointer input.
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
cursor_work_dir="$(mktemp -d /tmp/prp-cursor.XXXXXX)"
trap 'rm -rf "$cursor_work_dir"' EXIT
swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$repo_dir/macos/PerpendicularDesktop/RFBCursor.swift" "$test_dir/RFBCursorCheck.swift" -o "$cursor_work_dir/cursor-check"
"$cursor_work_dir/cursor-check"
# Exact causal negative: the same oracle must reject LSB-first mask decoding.
python3 - "$repo_dir/macos/PerpendicularDesktop/RFBCursor.swift" "$cursor_work_dir/BadCursor.swift" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text(); before='0x80 >> (x & 7)'
assert text.count(before)==1
Path(sys.argv[2]).write_text(text.replace(before,'1 << (x & 7)',1))
PY
swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$cursor_work_dir/BadCursor.swift" "$test_dir/RFBCursorCheck.swift" -o "$cursor_work_dir/cursor-negative"
if "$cursor_work_dir/cursor-negative" >"$cursor_work_dir/negative.log" 2>&1; then
    echo 'RFBCursor causal negative incorrectly passed' >&2; exit 1
fi
python3 - "$cursor_work_dir/negative.log" <<'PY'
from pathlib import Path
import sys
assert 'RichCursor mask/color oracle at pixel' in Path(sys.argv[1]).read_text()
print('{"causal_negative":"pass","changed":"MSB_to_LSB","failure":"mask/color_oracle","ui":false}')
PY
