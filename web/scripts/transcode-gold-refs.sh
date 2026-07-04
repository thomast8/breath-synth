#!/usr/bin/env bash
# Transcodes the committed AIFC gold-reference takes EnrollmentScript.swift points at into WAV,
# since the Linux server's AudioIO/WavIO path only reads WAV (no AIFC decoder without AVFoundation).
# Run on macOS (needs afconvert) whenever a gold reference asset changes; output is committed —
# Railway's Linux build has no afconvert to regenerate these itself.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src_dir="$repo_root/Assets/breaths"
out_dir="$repo_root/web/server/Resources/gold-refs"
mkdir -p "$out_dir"

# Every `reference:` filename in EnrollmentScript.swift's technique steps (calm/FRC/RV/packing) —
# recovery has no gold reference (its lanes pass `reference: nil`), so it's not listed here.
refs=(
  calm_inhale.aifc
  calm_exhale.aifc
  frc_1.aifc
  rv.aifc
  packing_1.aifc
  packing_2.aifc
)

for name in "${refs[@]}"; do
  src="$src_dir/$name"
  out="$out_dir/${name%.aifc}.wav"
  if [ ! -f "$src" ]; then
    echo "warning: missing source asset $src" >&2
    continue
  fi
  afconvert -f WAVE -d LEF32 "$src" "$out"
  echo "wrote $out"
done
