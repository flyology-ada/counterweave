with Ada.Strings.Unbounded;

package Counterweave.Adapter_Results is

   type Verdict_Kind is (Passed, Property_Violation, Invalid_Case);

   type Adapter_Result is record
      Verdict             : Verdict_Kind := Invalid_Case;
      Pack_Name           : Ada.Strings.Unbounded.Unbounded_String;
      Pack_Version        : Ada.Strings.Unbounded.Unbounded_String;
      Property_Name       : Ada.Strings.Unbounded.Unbounded_String;
      Failure_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Observations_JSON   : Ada.Strings.Unbounded.Unbounded_String;
      Conformance_JSON    : Ada.Strings.Unbounded.Unbounded_String;
      Trace_JSON          : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Parse
     (Source                : String;
      Expected_Pack_Name    : String;
      Expected_Pack_Version : String) return Adapter_Result;

   function To_JSON (Item : Adapter_Result) return String;

   function Has_Trace (Item : Adapter_Result) return Boolean;

   procedure Evidence_From_Run
     (Source           : String;
      Trace_JSON       : out Ada.Strings.Unbounded.Unbounded_String;
      Conformance_JSON : out Ada.Strings.Unbounded.Unbounded_String);

   function Image (Verdict : Verdict_Kind) return String;

   Protocol_Error : exception;

end Counterweave.Adapter_Results;
