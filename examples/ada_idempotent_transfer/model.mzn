int: account_count;
int: initial_balance;
int: step_count;
int: max_amount;
int: counterweave_diversity_seed;

constraint account_count >= 2 /\ account_count <= 4;
constraint initial_balance >= 1;
constraint step_count >= 2 /\ step_count <= 16;
constraint max_amount >= 1;
constraint counterweave_diversity_seed >= 0;

set of int: accounts = 1..account_count;
set of int: steps = 1..step_count;
set of int: transactions = 1..step_count;
int: maximum_balance = initial_balance + step_count * max_amount;

% Operations are 1=deposit and 2=idempotent transfer.
array[steps] of var 1..2: step_operation;
array[steps] of var 0..step_count: step_transaction;
array[steps] of var accounts: step_source;
array[steps] of var accounts: step_destination;
array[steps] of var 1..max_amount: step_amount;

% Expectations are 1=applied and 0=duplicate ignored.
array[steps] of var 0..1: step_expectation;
array[0..step_count, accounts] of var 0..maximum_balance: balance;
array[0..step_count, transactions] of var bool: seen;

constraint forall (account in accounts) (
  balance[0, account] = initial_balance
);
constraint forall (transaction in transactions) (
  not seen[0, transaction]
);

constraint forall (step in steps) (
  if step_operation[step] = 1 then
    step_transaction[step] = 0 /\
    step_source[step] = step_destination[step] /\
    step_expectation[step] = 1
  else
    step_transaction[step] in transactions /\
    step_source[step] != step_destination[step] /\
    step_expectation[step] = bool2int(not seen[step - 1, step_transaction[step]]) /\
    (if not seen[step - 1, step_transaction[step]] then
       step_amount[step] <= balance[step - 1, step_source[step]]
     else
       exists (prior in 1..step - 1) (
         step_operation[prior] = 2 /\
         step_transaction[prior] = step_transaction[step] /\
         step_source[prior] = step_source[step] /\
         step_destination[prior] = step_destination[step] /\
         step_amount[prior] = step_amount[step]
       )
     endif)
  endif
);

constraint forall (step in steps, transaction in transactions) (
  seen[step, transaction] =
    (seen[step - 1, transaction] \/
     (step_operation[step] = 2 /\ step_transaction[step] = transaction))
);

constraint forall (step in steps, account in accounts) (
  balance[step, account] =
    balance[step - 1, account]
    + bool2int(step_operation[step] = 1 /\ step_destination[step] = account)
      * step_amount[step]
    - bool2int(step_operation[step] = 2 /\ step_expectation[step] = 1 /\
               step_source[step] = account) * step_amount[step]
    + bool2int(step_operation[step] = 2 /\ step_expectation[step] = 1 /\
               step_destination[step] = account) * step_amount[step]
);

constraint sum (step in steps) (bool2int(step_operation[step] = 2)) >= 1;

var 0..step_count: duplicate_count =
  sum (step in steps) (
    bool2int(step_operation[step] = 2 /\ step_expectation[step] = 0)
  );

function int: diversity_coefficient(int: index) =
  ((counterweave_diversity_seed div (index + 1) + index * 37) mod 101) - 50;

var int: diversity_score =
  diversity_coefficient(1) * 20 * duplicate_count
  + sum (step in steps) (
      diversity_coefficient(5 * step) * step_operation[step]
      + diversity_coefficient(5 * step + 1) * step_transaction[step]
      + diversity_coefficient(5 * step + 2) * step_source[step]
      + diversity_coefficient(5 * step + 3) * step_destination[step]
      + diversity_coefficient(5 * step + 4) * step_amount[step]
    );

solve maximize diversity_score;
