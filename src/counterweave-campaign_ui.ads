with Ada.Strings.Unbounded;
with Interfaces;

package Counterweave.Campaign_UI is

   type Attempt_Outcome is (Passed, Found, Cancelled, Errored);

   type Attempt_Result is record
      Outcome             : Attempt_Outcome := Errored;
      Attempt             : Natural := 0;
      Seed                : Interfaces.Unsigned_64 := 0;
      Detail              : Ada.Strings.Unbounded.Unbounded_String;
      Property_Name       : Ada.Strings.Unbounded.Unbounded_String;
      Failure_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Interactive return Boolean;

   generic
      Title : String;
      Maximum_Attempts : Positive;
      Root_Seed : Interfaces.Unsigned_64;
      with procedure Attempt (Index : Positive; Result : out Attempt_Result);
   package Runs is

      procedure Run
        (Final_Result : out Attempt_Result; Attempts : out Natural);

   end Runs;

end Counterweave.Campaign_UI;
