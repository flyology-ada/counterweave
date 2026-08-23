include "all_different.mzn";

int: actors;
int: capacity;

array[1..actors] of var 1..capacity: allocation;

constraint all_different(allocation);

solve satisfy;
