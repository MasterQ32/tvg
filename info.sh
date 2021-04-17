#!/bin/bash

set -e

# First, generate all example files
zig build generate

(
  echo '# Example Files'
  echo
) > examples/README.md

for file in examples/*.tvg ; do
  PNG_FILE="${file%.*}.png"
  SIZE_TVG="$(wc -c "${file}" | awk '{ print $1 }')"
  SIZE_PNG="$(wc -c "${PNG_FILE}" | awk '{ print $1 }')"
  (
    echo "## \`$(basename "${file}")\`"
    echo ""
    echo "![]($(basename "${PNG_FILE}"))"
    echo ""
    echo "**TVG Size**: ${SIZE_TVG} (100%)"
    echo "**PNG Size**: ${SIZE_PNG} ($(( (100 * ${SIZE_PNG} ) / ${SIZE_TVG} ))%)"
    echo ""
  ) >> examples/README.md
done

cat examples/README.md