private package Counterweave.Reduction_Engine is

   procedure Reduce
     (Campaign_Path : String;
      Executable    : String;
      Case_Output   : String;
      Run_Output    : String;
      Report_Output : String);

   Reduction_Error : exception;

end Counterweave.Reduction_Engine;
