#!/bin/sh
# ocr-check.sh FRAME — LOCAL DEV VALIDATOR (not run by CI). Runs every gate OCR
# *detection* on a captured frame, mirroring desktop-test.sh, so detection can be
# tuned without a CI build. Usage: download a run's boot-artifacts, then
#   ./ocr-check.sh tests/desk-005.ppm     (or any captured .ppm/.png frame)
# The interactive steps (sendkey) still need a live guest; this only simulates
# the OCR checks. Writes temp files NEXT TO the frame (as CI does), which also
# sidesteps the local Bash-sandbox that blocks tesseract reads outside the workdir.
# ocr-check.sh FRAME — run every gate OCR *detection* on a captured frame,
# mirroring desktop-test.sh. Writes temp files NEXT TO the frame (as CI does).
f="$1"; d=$(dirname "$f")
ocr()        { magick "$f" -resize 200% "$d/_full.png" 2>/dev/null; tesseract "$d/_full.png" - 2>/dev/null | tr -d '\r'; }
ocr_corner() { magick "$f" -gravity NorthEast -crop 42%x24%+0+0 +repage -colorspace Gray -resize 400% "$d/_ne.png" 2>/dev/null; tesseract "$d/_ne.png" - 2>/dev/null | tr -d '\r'; }
full=$(ocr); corner=$(ocr_corner)
chk() { printf '  %-22s' "$2:"; printf '%s' "$3" | grep -qiE "$1" && echo "detected" || echo "MISSING"; }
echo "frame: $f"
chk 'System[[:space:]]*Disk'                    "System Disk (corner)" "$corner"
chk 'Workspace'                                 "Workspace (full)"     "$full"
chk 'About[[:space:]]*This[[:space:]]*Computer' "About This Computer"  "$full"
chk 'command to execute|Type the command'       "Run dialog"           "$full"
