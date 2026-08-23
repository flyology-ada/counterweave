#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output_dir=${COUNTERWEAVE_OUTPUT_DIR:-/tmp}
case_file=$output_dir/counterweave-idempotent-transfer.cwcase
run_file=$output_dir/counterweave-idempotent-transfer.cwrun
campaign_file=$output_dir/counterweave-idempotent-transfer.cwcampaign
reduced_case_file=$output_dir/counterweave-idempotent-transfer-reduced.cwcase
reduced_run_file=$output_dir/counterweave-idempotent-transfer-reduced.cwrun
reduction_file=$output_dir/counterweave-idempotent-transfer.cwreduction
diversity_one=$output_dir/counterweave-idempotent-transfer-diversity-1.cwcase
diversity_two=$output_dir/counterweave-idempotent-transfer-diversity-2.cwcase
solver=${COUNTERWEAVE_SOLVER:-cp-sat}

cd "$root"
alr -n build

bin/counterweave search \
  --model examples/ada_idempotent_transfer/model.mzn \
  --adapter bin/idempotent_transfer_adapter \
  --solver "$solver" \
  --draw step_count=5..14 \
  --draw account_count=2..4 \
  --draw initial_balance=40..120 \
  --draw max_amount=5..30 \
  --seed 20260823 \
  --trials 64 \
  --pack ada-idempotent-transfer \
  --intent explore \
  --target transfers-are-idempotent \
  --case-output "$case_file" \
  --run-output "$run_file" \
  --campaign-output "$campaign_file"

grep -q '"outcome": "property-violation"' "$run_file"
grep -q '"fingerprint":"duplicate-transfer-not-ignored"' "$run_file"
grep -q '"status": "property-violation"' "$campaign_file"
grep -q '"failure_fingerprint":"duplicate-transfer-not-ignored"' "$campaign_file"
bin/counterweave reduce \
  --campaign "$campaign_file" \
  --case-output "$reduced_case_file" \
  --run-output "$reduced_run_file" \
  --report-output "$reduction_file"
grep -q '"step_count":5' "$reduction_file"
grep -q '"property": "transfers-are-idempotent"' "$reduction_file"
grep -q '"failure_fingerprint": "duplicate-transfer-not-ignored"' "$reduction_file"
for diversity_seed in 1 2; do
  bin/counterweave generate \
    --model examples/ada_idempotent_transfer/model.mzn \
    --solver "$solver" \
    --draw step_count=5..5 \
    --draw account_count=2..2 \
    --draw initial_balance=40..40 \
    --draw max_amount=5..5 \
    --seed "$diversity_seed" \
    --pack ada-idempotent-transfer \
    --intent explore \
    --target transfers-are-idempotent \
    --output "$output_dir/counterweave-idempotent-transfer-diversity-$diversity_seed.cwcase"
done
history_one=$(sed -n '/"step_operation"/p;/"step_transaction"/p;/"step_amount"/p' "$diversity_one")
history_two=$(sed -n '/"step_operation"/p;/"step_transaction"/p;/"step_amount"/p' "$diversity_two")
test "$history_one" != "$history_two"
if [ ! -t 1 ]; then
  echo "idempotency bug reproduced and reduced; evidence: $reduction_file"
fi
