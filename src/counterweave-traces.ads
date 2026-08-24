with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Counterweave.Traces is

   type Step_Status is (Matched, Diverged, Violated);

   type Trace_Step is record
      Role         : Ada.Strings.Unbounded.Unbounded_String;
      Action       : Ada.Strings.Unbounded.Unbounded_String;
      Model        : Ada.Strings.Unbounded.Unbounded_String;
      Observed     : Ada.Strings.Unbounded.Unbounded_String;
      Status       : Step_Status := Matched;
      Model_Source : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Step_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Trace_Step);

   type Counterexample_Trace is record
      Summary : Ada.Strings.Unbounded.Unbounded_String;
      Basis   : Ada.Strings.Unbounded.Unbounded_String;
      Steps   : Step_Vectors.Vector;
   end record;

   function Parse (Source : String) return Counterexample_Trace;

   function Trace_JSON_From_Run
     (Source : String) return Ada.Strings.Unbounded.Unbounded_String;

   function Image (Status : Step_Status) return String;

   Trace_Error : exception;

end Counterweave.Traces;
