with Ada.Strings.Unbounded;
with Interfaces;

package Counterweave.MiniZinc is

   type Solution_Result is record
      Value_JSON   : Ada.Strings.Unbounded.Unbounded_String;
      Diagnostics  : Ada.Strings.Unbounded.Unbounded_String;
      Compiled_SHA256 : Ada.Strings.Unbounded.Unbounded_String;
      Applied_Seed : Interfaces.Unsigned_64 := 0;
      Seed_Applied : Boolean := False;
   end record;

   function Version
     (Executable           : String := "minizinc";
      Timeout_Milliseconds : Positive := 5_000) return String;

   function Solve_One
     (Model_Path           : String;
      Data_Path            : String;
      Solver               : String;
      Random_Seed          : Interfaces.Unsigned_64;
      Timeout_Milliseconds : Positive := 30_000;
      Executable           : String := "minizinc") return Solution_Result;

   MiniZinc_Error : exception;

end Counterweave.MiniZinc;
