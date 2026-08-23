with Ada.Strings.Unbounded;
with Counterweave.Adapter_Results;
with Counterweave.Choices;
with Counterweave.Processes;
with Counterweave.Strings;
with Interfaces;

package Counterweave.Artifacts is

   type Case_Data is record
      Pack_Name        : Ada.Strings.Unbounded.Unbounded_String;
      Pack_Version     : Ada.Strings.Unbounded.Unbounded_String;
      Intent_Kind      : Ada.Strings.Unbounded.Unbounded_String;
      Intent_Target    : Ada.Strings.Unbounded.Unbounded_String;
      Choices          : Counterweave.Choices.Choice_Tape;
      Solver           : Ada.Strings.Unbounded.Unbounded_String;
      MiniZinc_Version : Ada.Strings.Unbounded.Unbounded_String;
      Model_SHA256     : Ada.Strings.Unbounded.Unbounded_String;
      Compiled_SHA256  : Ada.Strings.Unbounded.Unbounded_String;
      Data_SHA256      : Ada.Strings.Unbounded.Unbounded_String;
      Diversity_Seed   : Interfaces.Unsigned_64 := 0;
      Solver_Seed      : Interfaces.Unsigned_64 := 0;
      Seed_Applied     : Boolean := False;
      Parameters_JSON  : Ada.Strings.Unbounded.Unbounded_String;
      Solution_JSON    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   procedure Write_Case (Path : String; Data : Case_Data);

   procedure Validate_Case (Source : String);

   procedure Case_Pack
     (Source  : String;
      Name    : out Ada.Strings.Unbounded.Unbounded_String;
      Version : out Ada.Strings.Unbounded.Unbounded_String);

   function Choices_From_Case
     (Source : String) return Counterweave.Choices.Choice_Tape;

   function Case_Replay_SHA256 (Source : String) return String;

   function Executable_SHA256 (Program : String) return String;

   procedure Write_Run
     (Path               : String;
      Case_Path          : String;
      Adapter            : String;
      Adapter_SHA256     : String;
      Arguments          : Counterweave.Strings.String_Vector;
      Process            : Counterweave.Processes.Process_Result;
      Has_Adapter_Result : Boolean;
      Adapter_Result     : Counterweave.Adapter_Results.Adapter_Result);

end Counterweave.Artifacts;
