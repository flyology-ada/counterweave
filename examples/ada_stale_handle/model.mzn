int: capacity;
int: old_value;
int: new_value;
int: scenario;
int: counterweave_diversity_seed;

constraint capacity >= 1 /\ capacity <= 8;
constraint old_value != new_value;
constraint scenario >= 0 /\ scenario <= 31;

int: step_count = 8;
array[0..step_count] of var bool: active;
array[0..step_count] of var 0..16: generation;
array[1..step_count] of var 1..4: step_operation;
array[1..step_count] of var 1..2: step_handle;
array[1..step_count] of var 0..200: step_value;
array[1..step_count] of var 0..1: step_expectation;

var 1..capacity: old_slot;
var 1..capacity: new_slot;
var 1..16: old_generation;
var 1..16: new_generation;
var bool: expected_stale;
var bool: probe_stale;

%  Every scenario is a valid history. Most inspect the live replacement handle;
%  one scenario probes the released handle and can expose generation bugs.
%  Operations are 1=allocate, 2=write, 3=release, and 4=read.
%  Expectations are 0=success and 1=stale-handle rejection.
constraint probe_stale = (scenario = 23);
constraint step_operation = [1, 2, 4, 3, 1, 2, 4, 3];
constraint step_handle =
  [1, 1, 1, 1, 2, 2, if probe_stale then 1 else 2 endif, 2];
constraint step_value = [0, old_value, 0, 0, 0, new_value, 0, 0];
constraint step_expectation =
  [0, 0, 0, 0, 0, 0, if probe_stale then 1 else 0 endif, 0];

constraint not active[0] /\ generation[0] = 0;
constraint active[1] /\ generation[1] = 1;
constraint active[2] = active[1] /\ generation[2] = generation[1];
constraint active[3] = active[2] /\ generation[3] = generation[2];
constraint not active[4] /\ generation[4] = generation[3];
constraint active[5] /\ generation[5] = generation[4] + 1;
constraint active[6] = active[5] /\ generation[6] = generation[5];
constraint active[7] = active[6] /\ generation[7] = generation[6];
constraint not active[8] /\ generation[8] = generation[7];

%  First-fit allocation deliberately reuses the released slot.
constraint old_slot = 1 /\ new_slot = old_slot;
constraint old_generation = generation[1];
constraint new_generation = generation[5];
constraint expected_stale = probe_stale /\ (old_generation < new_generation);

solve satisfy;
