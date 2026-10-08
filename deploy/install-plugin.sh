#!/usr/bin/env bash
set -euo pipefail

commit=${1:?merged commit required}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 1

source="/shared/isbf-alumni-releases/$commit/isbf-alumni"
target=/var/www/discourse/plugins/isbf-alumni
test -f "$source/plugin.rb"
test "$(cat "$source/.release-commit")" = "$commit"

if test -L "$target"; then
  test "$(readlink "$target")" = "$source"
else
  test ! -e "$target"
  ln -s "$source" "$target"
fi
