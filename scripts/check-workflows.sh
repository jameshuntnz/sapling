#!/bin/bash
# Validate the GitHub Actions workflow files.
#
# An invalid workflow doesn't fail loudly — GitHub records a run that fails in
# zero seconds with no log, and lists the workflow by path instead of by name
# because it couldn't parse far enough to read `name:`. That is easy to mistake
# for an unrelated flake, and verify-node.yml sat broken through three pushes
# before anyone looked.
#
# The specific trap: `run: echo "hostname: $(hostname)"` is invalid YAML,
# because a plain scalar cannot contain ": ". Use a block scalar instead.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

status=0
for file in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -e "$file" ] || continue
    if ! message="$(ruby -ryaml -e '
        begin
          doc = YAML.load_file(ARGV[0])
          abort "no jobs defined" unless doc.is_a?(Hash) && doc["jobs"].is_a?(Hash)
          abort "no name" unless doc["name"]
          # `on` parses as the boolean true in YAML 1.1, which is fine, but it
          # has to be present one way or the other.
          abort "no triggers" unless doc.key?("on") || doc.key?(true)
        rescue => e
          abort e.message
        end' "$file" 2>&1)"; then
        echo "error: $file — $message" >&2
        status=1
    else
        echo "  ok  $file"
    fi
done

[ "$status" -eq 0 ] && echo "workflows ok"
exit "$status"
