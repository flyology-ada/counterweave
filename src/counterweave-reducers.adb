with Ada.Exceptions;
with Counterweave.Reduction_Engine;

package body Counterweave.Reducers is

   procedure Reduce
     (Campaign_Path    : String;
      Executable       : String;
      Case_Output      : String;
      Run_Output       : String;
      Report_Output    : String;
      Maximum_Attempts : Positive := 1_000;
      Progress         : access procedure (Update : Reduction_Update) := null;
      Stop             : access function return Boolean := null) is
   begin
      Counterweave.Reduction_Engine.Reduce
        (Campaign_Path,
         Executable,
         Case_Output,
         Run_Output,
         Report_Output,
         Maximum_Attempts,
         Progress,
         Stop);
   exception
      when Error : Counterweave.Reduction_Engine.Reduction_Error =>
         raise Reduction_Error with Ada.Exceptions.Exception_Message (Error);
   end Reduce;

end Counterweave.Reducers;
