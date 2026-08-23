with Ada.Strings.Unbounded;
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
      Solver_Seed      : Interfaces.Unsigned_64 := 0;
      Seed_Applied     : Boolean := False;
      Parameters_JSON  : Ada.Strings.Unbounded.Unbounded_String;
      Solution_JSON    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   procedure Write_Case (Path : String; Data : Case_Data);

   procedure Validate_Case (Source : String);

   function Choices_From_Case
     (Source : String) return Counterweave.Choices.Choice_Tape;

   function Executable_SHA256 (Program : String) return String;

   procedure Write_Run
     (Path      : String;
      Case_Path : String;
      Adapter   : String;
      Adapter_SHA256 : String;
      Arguments : Counterweave.Strings.String_Vector;
      Result    : Counterweave.Processes.Process_Result);

end Counterweave.Artifacts;
