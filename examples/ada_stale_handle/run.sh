#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output_dir=${COUNTERWEAVE_OUTPUT_DIR:-/tmp}
case_file=$output_dir/counterweave-stale-handle.cwcase
run_file=$output_dir/counterweave-stale-handle.cwrun
solver=${COUNTERWEAVE_SOLVER:-cp-sat}

cd "$root"
alr -n build

bin/counterweave search \
  --model examples/ada_stale_handle/model.mzn \
  --adapter bin/stale_handle_adapter \
  --solver "$solver" \
  --draw capacity=1..4 \
  --draw old_value=10..100 \
  --draw new_value=101..200 \
  --draw scenario=0..31 \
  --seed 42 \
  --trials 64 \
  --pack ada-stale-handle \
  --intent explore \
  --target released-handles-stay-stale \
  --case-output "$case_file" \
  --run-output "$run_file"

grep -q '"outcome": "failed"' "$run_file"
grep -q '"expected_stale":true' "$run_file"
grep -q '"stale_read_accepted":true' "$run_file"
grep -q '"index":7,"operation":"read","status":"ok"' "$run_file"
grep -q '"old_generation": 1,"new_generation": 1' "$run_file"
if [ ! -t 1 ]; then
  echo "bug reproduced; evidence: $run_file"
fi
