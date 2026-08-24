with Ada.Strings.Unbounded;
with Counterweave.Reducers;

package Counterweave.Reduction_UI is

   type Completion_Result is record
      Last      : Counterweave.Reducers.Reduction_Update;
      Succeeded : Boolean := False;
      Detail    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Interactive return Boolean;

   procedure Run
     (Title            : String;
      Case_Path        : String;
      Run_Path         : String;
      Report_Path      : String;
      Maximum_Attempts : Positive;
      Action           :
        not null access procedure
          (Progress :
             access procedure
               (Update : Counterweave.Reducers.Reduction_Update);
           Stop     : access function return Boolean);
      Result           : out Completion_Result);

   Action_Error : exception;

end Counterweave.Reduction_UI;
