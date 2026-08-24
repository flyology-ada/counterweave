int: capacity;
int: old_value;
int: new_value;
int: history_shape;
int: scenario;
int: counterweave_diversity_seed;

constraint capacity >= 1 /\ capacity <= 8;
constraint old_value != new_value;
constraint history_shape >= 0 /\ history_shape <= 255;
constraint scenario >= 0 /\ scenario <= 31;

% A zero shape is the nine-step causal core. Only one of 256 uniformly drawn
% shapes is minimal; the remaining shapes add one to twelve valid live-handle
% operations. Numeric choice shrinking naturally removes that padding.
int: padding_count = (history_shape + 21) div 22;
int: step_count = 9 + padding_count;
set of int: steps = 1..step_count;

int: release_first = padding_count + 2;
int: allocate_second = padding_count + 3;
int: release_second = padding_count + 4;
int: allocate_third = padding_count + 5;
int: release_third = padding_count + 6;
int: allocate_replacement = padding_count + 7;
int: write_replacement = padding_count + 8;
int: final_probe = padding_count + 9;

% Operations are 1=allocate, 2=write, 3=release, and 4=read.
% Expectations are 0=success and 1=stale-handle rejection.
array[steps] of var 1..4: step_operation;
array[steps] of var 1..4: step_handle;
array[steps] of var 0..200: step_value;
array[steps] of var 0..1: step_expectation;

% The model follows the one physical slot through every transition. Generation
% zero is reserved; every allocation must advance a previously used slot.
array[0..step_count] of var bool: active;
array[0..step_count] of var 0..32: generation;
array[0..step_count] of var 0..200: stored_value;

var 1..capacity: old_slot;
var 1..capacity: new_slot;
var 1..32: old_generation;
var 1..32: new_generation;
var bool: expected_stale;
var bool: probe_stale;

% Most histories inspect the live replacement. One scenario probes the first
% released handle after three slot reuses, exposing a small-generation wrap.
constraint probe_stale = (scenario = 23);

constraint forall (step in steps) (
  step_operation[step] =
    if step = 1 then 1
    elseif step <= padding_count + 1 then
      if step = 2 \/
         ((counterweave_diversity_seed div step + step) mod 2 = 0)
      then 2 else 4 endif
    elseif step = release_first then 3
    elseif step = allocate_second then 1
    elseif step = release_second then 3
    elseif step = allocate_third then 1
    elseif step = release_third then 3
    elseif step = allocate_replacement then 1
    elseif step = write_replacement then 2
    else 4
    endif
);

constraint forall (step in steps) (
  step_handle[step] =
    if step <= release_first then 1
    elseif step <= release_second then 2
    elseif step <= release_third then 3
    elseif step < final_probe then 4
    else if probe_stale then 1 else 4 endif
    endif
);

constraint forall (step in steps) (
  step_value[step] =
    if step = write_replacement then new_value
    elseif step_operation[step] = 2 then old_value
    else 0
    endif
);

constraint forall (step in steps) (
  step_expectation[step] = bool2int(step = final_probe /\ probe_stale)
);

constraint not active[0] /\ generation[0] = 0 /\ stored_value[0] = 0;
constraint forall (step in steps) (
  if step_operation[step] = 1 then
    not active[step - 1] /\
    active[step] /\
    generation[step] = generation[step - 1] + 1 /\
    stored_value[step] = stored_value[step - 1]
  elseif step_operation[step] = 3 then
    active[step - 1] /\
    not active[step] /\
    generation[step] = generation[step - 1] /\
    stored_value[step] = stored_value[step - 1]
  elseif step_operation[step] = 2 then
    active[step - 1] /\
    active[step] /\
    generation[step] = generation[step - 1] /\
    stored_value[step] = step_value[step]
  else
    active[step - 1] /\
    active[step] /\
    generation[step] = generation[step - 1] /\
    stored_value[step] = stored_value[step - 1]
  endif
);

constraint old_slot = 1 /\ new_slot = old_slot;
constraint old_generation = generation[1];
constraint new_generation = generation[allocate_replacement];
constraint old_generation = 1 /\ new_generation = 4;
constraint expected_stale = probe_stale /\ (old_generation < new_generation);

solve satisfy;
