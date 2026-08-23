with Ada.Strings.Unbounded;
with Counterweave.Strings;
with Interfaces;

package Counterweave.Campaigns is

   type Campaign_Log is limited private;

   procedure Start
     (Log               : out Campaign_Log;
      Root_Seed         : Interfaces.Unsigned_64;
      Maximum_Trials    : Positive;
      Model_Path        : String;
      Data_Path         : String;
      Solver            : String;
      Pack_Name         : String;
      Pack_Version      : String;
      Intent            : String;
      Target            : String;
      Adapter           : String;
      Draws             : Counterweave.Strings.String_Vector;
      Adapter_Arguments : Counterweave.Strings.String_Vector;
      Solver_Timeout    : Positive;
      Adapter_Timeout   : Positive;
      Case_Output       : String;
      Run_Output        : String);

   procedure Append_Attempt
     (Log                 : in out Campaign_Log;
      Index               : Positive;
      Seed                : Interfaces.Unsigned_64;
      Outcome             : String;
      Detail              : String;
      Property_Name       : String;
      Failure_Fingerprint : String;
      Case_Path           : String;
      Run_Path            : String);

   procedure Set_Status (Log : in out Campaign_Log; Status : String);

   procedure Write (Path : String; Log : Campaign_Log);

   function Replay_Arguments
     (Source          : String;
      Case_Output     : String;
      Run_Output      : String;
      Campaign_Output : String) return Counterweave.Strings.String_Vector;

   procedure Verify_Replay (Original : String; Replayed : String);

   Campaign_Error : exception;

private

   use Ada.Strings.Unbounded;

   type Campaign_Log is limited record
      Root_Seed         : Interfaces.Unsigned_64 := 0;
      Maximum_Trials    : Positive := 1;
      Model_Path        : Unbounded_String;
      Model_SHA256      : Unbounded_String;
      Data_Path         : Unbounded_String;
      Data_SHA256       : Unbounded_String;
      Solver            : Unbounded_String;
      Pack_Name         : Unbounded_String;
      Pack_Version      : Unbounded_String;
      Intent            : Unbounded_String;
      Target            : Unbounded_String;
      Adapter           : Unbounded_String;
      Adapter_SHA256    : Unbounded_String;
      Draws             : Counterweave.Strings.String_Vector;
      Adapter_Arguments : Counterweave.Strings.String_Vector;
      Solver_Timeout    : Positive := 1;
      Adapter_Timeout   : Positive := 1;
      Case_Output       : Unbounded_String;
      Run_Output        : Unbounded_String;
      Status            : Unbounded_String;
      Attempts_JSON     : Unbounded_String;
      First_Attempt     : Boolean := True;
   end record;

end Counterweave.Campaigns;
