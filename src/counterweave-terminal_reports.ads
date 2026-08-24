with Counterweave.Campaign_UI;
with Counterweave.Reducers;
with Interfaces;

package Counterweave.Terminal_Reports is

   procedure Render_Search_Result
     (Result           : Counterweave.Campaign_UI.Attempt_Result;
      Attempts         : Natural;
      Maximum_Attempts : Positive;
      Root_Seed        : Interfaces.Unsigned_64;
      Campaign_Path    : String;
      Case_Path        : String;
      Run_Path         : String);

   procedure Render_Reduction_Result
     (Update      : Counterweave.Reducers.Reduction_Update;
      Report_Path : String;
      Case_Path   : String;
      Run_Path    : String);

end Counterweave.Terminal_Reports;
