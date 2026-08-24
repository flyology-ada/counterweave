#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output_dir=${COUNTERWEAVE_OUTPUT_DIR:-/tmp}
case_file=$output_dir/counterweave-stale-handle.cwcase
run_file=$output_dir/counterweave-stale-handle.cwrun
campaign_file=$output_dir/counterweave-stale-handle.cwcampaign
reduced_case_file=$output_dir/counterweave-stale-handle-reduced.cwcase
reduced_run_file=$output_dir/counterweave-stale-handle-reduced.cwrun
reduction_file=$output_dir/counterweave-stale-handle.cwreduction
unsupported_case=$output_dir/counterweave-stale-handle-unsupported.cwcase
unsupported_error=$output_dir/counterweave-stale-handle-unsupported.stderr
solver=${COUNTERWEAVE_SOLVER:-cp-sat}

trap 'rm -f "$unsupported_case" "$unsupported_error"' EXIT HUP INT TERM

cd "$root"
alr -n build

run_search() {
  bin/counterweave search \
    --model examples/ada_stale_handle/model.mzn \
    --adapter bin/stale_handle_adapter \
    --solver "$solver" \
    --draw capacity=1..4 \
    --draw old_value=10..100 \
    --draw new_value=101..200 \
    --draw history_shape=0..255 \
    --draw scenario=0..31 \
    "$@" \
    --trials 128 \
    --pack ada-stale-handle \
    --intent explore \
    --target released-handles-stay-stale \
    --case-output "$case_file" \
    --run-output "$run_file" \
    --campaign-output "$campaign_file"
}

if [ -n "${COUNTERWEAVE_SEED:-}" ]; then
  run_search --seed "$COUNTERWEAVE_SEED"
else
  run_search
fi

grep -q '"outcome": "property-violation"' "$run_file"
grep -q '"fingerprint":"stale-read-accepted"' "$run_file"
grep -q 'counterweave.trace/1' "$run_file"
grep -q '"status":"divergence"' "$run_file"
grep -q '"status":"violation"' "$run_file"
grep -q '"expected_stale":true' "$run_file"
grep -q '"stale_read_accepted":true' "$run_file"
grep -Eq '"index":(9|1[0-9]|2[01]),"operation":"read","status":"ok"' "$run_file"
grep -q '"old_generation": 1,"new_generation": 1' "$run_file"
grep -q '"status": "property-violation"' "$campaign_file"
grep -q '"failure_fingerprint":"stale-read-accepted"' "$campaign_file"
bin/counterweave reduce \
  --campaign "$campaign_file" \
  --case-output "$reduced_case_file" \
  --run-output "$reduced_run_file" \
  --report-output "$reduction_file" \
  --max-attempts 256
grep -q '"format": "counterweave.reduction/3"' "$reduction_file"
grep -q '"maximum_attempts": 256' "$reduction_file"
grep -q '"stop_reason": "attempt-limit"' "$reduction_file"
grep -q '"capacity":1' "$reduction_file"
grep -q '"new_value":101' "$reduction_file"
grep -q '"history_shape":0' "$reduction_file"
grep -q '"scenario":23' "$reduction_file"
grep -q '"summary":"capacity 1 | old 10 | new 101 | 9 steps"' "$reduction_file"
grep -q '"failure_fingerprint": "stale-read-accepted"' "$reduction_file"
grep -q '"original_trace": {' "$reduction_file"
grep -q '"final_trace": {' "$reduction_file"
grep -q '"outcome": "property-violation"' "$reduced_run_file"
grep -q '"fingerprint":"stale-read-accepted"' "$reduced_run_file"
sed 's/"version": "1"/"version": "2"/' \
  "$case_file" > "$unsupported_case"
if bin/stale_handle_adapter --case "$unsupported_case" \
  > /dev/null 2> "$unsupported_error"; then
  echo "unsupported stale-handle pack version was accepted" >&2
  exit 1
fi
grep -q 'unsupported model pack: ada-stale-handle/2' "$unsupported_error"
if [ ! -t 1 ]; then
  echo "bug reproduced and reduced; evidence: $reduction_file"
fi
