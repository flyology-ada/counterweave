with Ada.Strings.Unbounded;
with Counterweave.Strings;

package Counterweave.Processes is

   type Outcome_Kind is
     (Completed,
      Failed,
      Timed_Out,
      Cancelled,
      Output_Limit,
      Spawn_Error,
      Protocol_Error);

   type Process_Result is record
      Outcome              : Outcome_Kind := Spawn_Error;
      Standard_Output      : Ada.Strings.Unbounded.Unbounded_String;
      Standard_Error       : Ada.Strings.Unbounded.Unbounded_String;
      Elapsed_Milliseconds : Natural := 0;
   end record;

   function Run
     (Program              : String;
      Arguments            : Counterweave.Strings.String_Vector;
      Timeout_Milliseconds : Positive;
      Maximum_Output_Bytes : Positive := 1_048_576) return Process_Result;

   procedure Request_Cancel;

end Counterweave.Processes;
