with Counterweave.Campaign_UI;

package Counterweave.Terminal_Reports is

   procedure Render_Search_Result
     (Result           : Counterweave.Campaign_UI.Attempt_Result;
      Attempts         : Natural;
      Maximum_Attempts : Positive;
      Campaign_Path    : String;
      Case_Path        : String;
      Run_Path         : String;
      Adapter          : String);

end Counterweave.Terminal_Reports;
