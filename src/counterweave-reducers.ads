with Ada.Strings.Unbounded;

package Counterweave.Reducers is

   type Reduction_Outcome is
     (Preserved, Different_Result, Invalid_Candidate, Infrastructure_Error);

   type Reduction_Update is record
      Attempt             : Natural := 0;
      Maximum_Attempts    : Positive := 1;
      Accepted            : Natural := 0;
      Current_Forks       : Natural := 0;
      Current_Values      : Natural := 0;
      Candidate_Forks     : Natural := 0;
      Candidate_Values    : Natural := 0;
      Outcome             : Reduction_Outcome := Infrastructure_Error;
      Strategy            : Ada.Strings.Unbounded.Unbounded_String;
      Location            : Ada.Strings.Unbounded.Unbounded_String;
      Detail              : Ada.Strings.Unbounded.Unbounded_String;
      Pack_Label          : Ada.Strings.Unbounded.Unbounded_String;
      Model_Label         : Ada.Strings.Unbounded.Unbounded_String;
      Property_Name       : Ada.Strings.Unbounded.Unbounded_String;
      Failure_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Original_Repro      : Ada.Strings.Unbounded.Unbounded_String;
      Current_Repro       : Ada.Strings.Unbounded.Unbounded_String;
      Original_Trace_JSON : Ada.Strings.Unbounded.Unbounded_String;
      Current_Trace_JSON  : Ada.Strings.Unbounded.Unbounded_String;
      Retained            : Boolean := False;
   end record;

   procedure Reduce
     (Campaign_Path    : String;
      Executable       : String;
      Case_Output      : String;
      Run_Output       : String;
      Report_Output    : String;
      Maximum_Attempts : Positive := 1_000;
      Progress         : access procedure (Update : Reduction_Update) := null;
      Stop             : access function return Boolean := null);

   Reduction_Error : exception;

end Counterweave.Reducers;
