with Counterweave.Reducers;

private package Counterweave.Reduction_Engine is

   procedure Reduce
     (Campaign_Path    : String;
      Executable       : String;
      Case_Output      : String;
      Run_Output       : String;
      Report_Output    : String;
      Maximum_Attempts : Positive;
      Progress         :
        access procedure (Update : Counterweave.Reducers.Reduction_Update);
      Stop             : access function return Boolean);

   Reduction_Error : exception;

end Counterweave.Reduction_Engine;
