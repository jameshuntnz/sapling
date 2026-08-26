#!/bin/bash
# Keep files small enough to hold in your head.
#
# A file over the limit is a prompt to split along a seam that already exists —
# an extension, a nested type, a distinct responsibility — not a reason to
# reach for the limit itself.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LIMIT="${SAPLING_MAX_FILE_LINES:-300}"
WARN=$(( LIMIT * 5 / 6 ))
status=0

while read -r count file; do
    [ "$file" = "total" ] && continue
    if [ "$count" -gt "$LIMIT" ]; then
        echo "error: $file is $count lines (limit $LIMIT)"
        status=1
    elif [ "$count" -gt "$WARN" ]; then
        echo "warning: $file is $count lines (limit $LIMIT)"
    fi
done < <(find Sources Tests -name '*.swift' -exec wc -l {} +)

if [ "$status" -eq 0 ]; then
    largest=$(find Sources Tests -name '*.swift' -exec wc -l {} + \
        | grep -v ' total$' | sort -rn | head -1)
    echo "file sizes ok (largest:$largest, limit $LIMIT)"
fi
exit "$status"
