#!/usr/bin/env bash
# Compare our terrain against all 5 vanilla fixture seeds + chunk coords.
#
# For each fixture: extract several real chunks from the user's vanilla save,
# generate the same chunks with our worldgen at the same seed, run cell-diff.
# Output a markdown report at /tmp/audit_report.md.
#
# Usage:
#   bash tools/run_audit_suite.sh

set -e

REPO_DIR="/Users/tomdonohue/projects/minecraft-clone"
SAVES_DIR="$HOME/Library/Application Support/minecraft/saves"
OUT_DIR=/tmp/audit_suite
REPORT="/tmp/audit_report.md"

mkdir -p "$OUT_DIR"

# (world_name, seed) — paired with the saves on disk.
declare -a WORLDS=(
  "World1:-8927182785535458754"
  "World2:-4677851207947696890"
  "World3:4968446981084792528"
  "World4:1737401494247853575"
  "World5:6241878179848955143"
)

# Number of chunks to sample per world (auto-discovered from existing .dat files)
SAMPLE_COUNT=5

cd "$REPO_DIR"

echo "# Audit Suite Report" > "$REPORT"
echo "Generated: $(date)" >> "$REPORT"
echo "" >> "$REPORT"
echo "Compares our 2D heightmap terrain against vanilla Alpha 1.2.6 chunks at the same seed." >> "$REPORT"
echo "Cell-match % is after translating our block IDs → vanilla block IDs." >> "$REPORT"
echo "" >> "$REPORT"

for entry in "${WORLDS[@]}"; do
  world="${entry%%:*}"
  seed="${entry##*:}"
  echo "## $world (seed=$seed)" >> "$REPORT"
  echo "" >> "$REPORT"
  echo "| Chunk | Cell match | First divergence |" >> "$REPORT"
  echo "|--|--|--|" >> "$REPORT"

  total_match=0
  total_cells=0

  # Auto-discover the first SAMPLE_COUNT chunk files in this world
  # (any .dat under the world dir, sampled deterministically by sort).
  CHUNK_FILES=$(find "$SAVES_DIR/$world" -name "c.*.dat" 2>/dev/null | sort | head -$SAMPLE_COUNT)
  if [ -z "$CHUNK_FILES" ]; then
    echo "| (no chunks on disk) | — | — |" >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  while IFS= read -r vanilla; do
    [ -z "$vanilla" ] && continue
    base=$(basename "$vanilla" .dat)
    # Parse "c.cx.cz" -> cx, cz
    cx=$(echo "$base" | cut -d. -f2)
    cz=$(echo "$base" | cut -d. -f3)

    ours_raw="$OUT_DIR/${world}_${cx}_${cz}.raw"
    godot --headless --path . -s tools/export_chunk.gd -- "$seed" "$cx" "$cz" "$ours_raw" 2>&1 | grep -q "Wrote" || {
      echo "| ($cx, $cz) | (export failed) | — |" >> "$REPORT"
      continue
    }

    cmp_out=$(python3 tools/compare_chunks.py "$vanilla" "$ours_raw" 2>&1)
    match=$(echo "$cmp_out" | grep "Cell match:" | sed -E 's/.*\(([0-9.]+)%\).*/\1/')
    matched_cells=$(echo "$cmp_out" | grep "Cell match:" | sed -E 's/Cell match: ([0-9]+).*/\1/')
    div=$(echo "$cmp_out" | grep "First divergence:" | sed 's/First divergence: //' || echo "(perfect match)")
    echo "| ($cx, $cz) | ${match}% | $div |" >> "$REPORT"

    total_match=$((total_match + matched_cells))
    total_cells=$((total_cells + 32768))
  done <<< "$CHUNK_FILES"

  if [ "$total_cells" -gt 0 ]; then
    avg=$(python3 -c "print(f'{100.0 * $total_match / $total_cells:.2f}')")
    echo "" >> "$REPORT"
    echo "**$world average across sampled chunks: ${avg}%**" >> "$REPORT"
  fi
  echo "" >> "$REPORT"
done

echo "Report written to $REPORT"
cat "$REPORT"
