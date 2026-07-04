#!/usr/bin/env bash
# Transcodes the committed AIFC assets used as in-app demo playback (STEPS[].demoReference in
# web/client/src/script.ts) into AAC (.m4a), which plays natively in every current browser. Run on
# macOS (needs afconvert) whenever a demo reference changes; output is committed since Railway's
# Linux build has no afconvert to regenerate these itself. Distinct from
# web/scripts/transcode-gold-refs.sh, which produces WAV for server-side grading, not browser
# playback.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src_dir="$repo_root/Assets/breaths"
out_dir="$repo_root/web/client/public/demo"
mkdir -p "$out_dir"

refs=(
  calm_inhale.aifc
  calm_exhale.aifc
  frc_1.aifc
  rv.aifc
  packing_2.aifc
)

for name in "${refs[@]}"; do
  src="$src_dir/$name"
  out="$out_dir/${name%.aifc}.m4a"
  if [ ! -f "$src" ]; then
    echo "warning: missing source asset $src" >&2
    continue
  fi
  afconvert -f m4af -d aac "$src" "$out"
  echo "wrote $out"
done
