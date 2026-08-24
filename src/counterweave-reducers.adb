with Ada.Exceptions;
with Counterweave.Reduction_Engine;

package body Counterweave.Reducers is

   procedure Reduce
     (Campaign_Path : String;
      Executable    : String;
      Case_Output   : String;
      Run_Output    : String;
      Report_Output : String) is
   begin
      Counterweave.Reduction_Engine.Reduce
        (Campaign_Path, Executable, Case_Output, Run_Output, Report_Output);
   exception
      when Error : Counterweave.Reduction_Engine.Reduction_Error =>
         raise Reduction_Error with Ada.Exceptions.Exception_Message (Error);
   end Reduce;

end Counterweave.Reducers;
