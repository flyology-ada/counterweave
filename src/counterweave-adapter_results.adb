with Counterweave.JSON;
with Counterweave.Strings;
with Flyology_TLA.Replay;
with Flyology_TLA.Reporting;
with Flyology_TLA.Traces;

package body Counterweave.Adapter_Results is

   use Ada.Strings.Unbounded;
   use type Counterweave.JSON.Value_Kind;
   use type Flyology_TLA.Replay.Verdict;

   --  Preserve Counterweave's 1 MiB process-output and 4,096-step bounds;
   --  the remaining dimensions follow flyology_tla's reviewed Ada consumer.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_048_576,
      Maximum_Steps        => 4_096,
      Maximum_JSON_Depth   => 64,
      Maximum_Object_Names => 10_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 1_048_576);

   function Image (Verdict : Verdict_Kind) return String
   is (case Verdict is
         when Passed             => "pass",
         when Property_Violation => "property-violation",
         when Invalid_Case       => "invalid-case");

   function Has_Trace (Item : Adapter_Result) return Boolean
   is (Length (Item.Trace_JSON) > 0
       and then Length (Item.Conformance_JSON) > 0);

   function Parse
     (Source                : String;
      Expected_Pack_Name    : String;
      Expected_Pack_Version : String) return Adapter_Result
   is
      Root          : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Pack          : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "pack");
      Format        : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "format")));
      Pack_Name     : constant Unbounded_String :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name"));
      Pack_Version  : constant Unbounded_String :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version"));
      Verdict_Text  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "verdict")));
      Property_Name : constant Unbounded_String :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Root, "property"));
      Fingerprint   : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "fingerprint");
      Observations  : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "observations");
      Conformance   : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "conformance");
      Trace_Node    : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "trace");
      Result        : Adapter_Result;
   begin
      if Counterweave.JSON.Kind (Root) /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Pack) /= Counterweave.JSON.Object_Value
      then
         raise Protocol_Error with "adapter result envelope has invalid types";
      elsif Format /= "counterweave.adapter-result/2" then
         raise Protocol_Error with "unsupported adapter result format";
      elsif To_String (Pack_Name) /= Expected_Pack_Name
        or else To_String (Pack_Version) /= Expected_Pack_Version
      then
         raise Protocol_Error
           with "adapter result pack identity does not match the case";
      elsif Length (Property_Name) = 0 then
         raise Protocol_Error with "adapter result property is empty";
      end if;

      if Verdict_Text = "pass" then
         Result.Verdict := Passed;
      elsif Verdict_Text = "property-violation" then
         Result.Verdict := Property_Violation;
      elsif Verdict_Text = "invalid-case" then
         Result.Verdict := Invalid_Case;
      else
         raise Protocol_Error with "unknown adapter verdict";
      end if;

      if Counterweave.JSON.Kind (Fingerprint) = Counterweave.JSON.Null_Value
      then
         if Result.Verdict = Property_Violation then
            raise Protocol_Error
              with "property violation has no failure fingerprint";
         end if;
      elsif Counterweave.JSON.Kind (Fingerprint)
        = Counterweave.JSON.String_Value
      then
         Result.Failure_Fingerprint :=
           Counterweave.JSON.As_String (Source, Fingerprint);
         if Result.Verdict /= Property_Violation
           or else Length (Result.Failure_Fingerprint) = 0
         then
            raise Protocol_Error
              with "failure fingerprint does not match the verdict";
         end if;
      else
         raise Protocol_Error
           with "adapter result fingerprint has invalid type";
      end if;

      Result.Pack_Name := Pack_Name;
      Result.Pack_Version := Pack_Version;
      Result.Property_Name := Property_Name;
      Result.Observations_JSON :=
        To_Unbounded_String (Counterweave.JSON.Image (Source, Observations));

      if Counterweave.JSON.Kind (Conformance) = Counterweave.JSON.Null_Value
        and then Counterweave.JSON.Kind (Trace_Node)
                 = Counterweave.JSON.Null_Value
      then
         if Result.Verdict /= Invalid_Case then
            raise Protocol_Error
              with "semantic adapter result has no conformance evidence";
         end if;
         return Result;
      elsif Counterweave.JSON.Kind (Conformance)
        /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Trace_Node)
                /= Counterweave.JSON.Object_Value
      then
         raise Protocol_Error
           with "adapter conformance evidence has invalid types";
      end if;

      Result.Conformance_JSON :=
        To_Unbounded_String (Counterweave.JSON.Image (Source, Conformance));
      Result.Trace_JSON :=
        To_Unbounded_String (Counterweave.JSON.Image (Source, Trace_Node));
      declare
         Trace_SHA256  : Unbounded_String;
         Result_SHA256 : Unbounded_String;
         Trace         : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Traces.Parse
             (To_String (Result.Trace_JSON), Limits, Trace_SHA256);
         Shared_Result : constant Flyology_TLA.Replay.Replay_Result :=
           Flyology_TLA.Reporting.Parse_JSON
             (To_String (Result.Conformance_JSON), Limits, Result_SHA256);
      begin
         if Trace_SHA256 /= Result_SHA256 then
            raise Protocol_Error
              with "conformance result does not identify the attached trace";
         elsif Shared_Result.Compared_Steps > Natural (Trace.Steps.Length)
           or else Shared_Result.Failure_Step > Natural (Trace.Steps.Length)
         then
            raise Protocol_Error
              with "conformance result exceeds the attached trace";
         elsif Shared_Result.Status = Flyology_TLA.Replay.Conformant
           and then Shared_Result.Compared_Steps
                    /= Natural (Trace.Steps.Length)
         then
            raise Protocol_Error
              with "conformance result does not cover the attached trace";
         elsif Shared_Result.Status = Flyology_TLA.Replay.Diverged
           and then Shared_Result.Compared_Steps /= Shared_Result.Failure_Step
         then
            raise Protocol_Error
              with "conformance failure step does not match compared steps";
         elsif Shared_Result.Status = Flyology_TLA.Replay.Conformant
           and then Result.Verdict /= Passed
         then
            raise Protocol_Error
              with "conformance verdict does not match adapter verdict";
         elsif Shared_Result.Status = Flyology_TLA.Replay.Diverged
           and then Result.Verdict /= Property_Violation
         then
            raise Protocol_Error
              with "conformance verdict does not match adapter verdict";
         elsif Shared_Result.Status
               in Flyology_TLA.Replay.Adapter_Error
                | Flyology_TLA.Replay.Invalid_Trace
         then
            raise Protocol_Error
              with
                "infrastructure conformance outcome used as semantic result";
         elsif Result.Verdict = Invalid_Case then
            raise Protocol_Error
              with "invalid case unexpectedly carries conformance evidence";
         elsif Shared_Result.Status = Flyology_TLA.Replay.Diverged
           and then (Shared_Result.Property_Name /= Result.Property_Name
                     or else Shared_Result.Fingerprint
                             /= Result.Failure_Fingerprint)
         then
            raise Protocol_Error
              with
                "conformance failure identity does not match adapter result";
         end if;
      end;
      return Result;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Protocol_Error with "malformed adapter result";
      when Flyology_TLA.Traces.Trace_Error =>
         raise Protocol_Error with "malformed Flyology TLA+ trace";
      when Flyology_TLA.Reporting.Result_Error =>
         raise Protocol_Error with "malformed Flyology TLA+ result";
   end Parse;

   function To_JSON (Item : Adapter_Result) return String is
      Fingerprint : constant String :=
        (if Item.Verdict = Property_Violation
         then
           Counterweave.Strings.JSON_String
             (To_String (Item.Failure_Fingerprint))
         else "null");
   begin
      if (Length (Item.Trace_JSON) = 0) /= (Length (Item.Conformance_JSON) = 0)
      then
         raise Protocol_Error with "incomplete conformance evidence";
      elsif not Has_Trace (Item) and then Item.Verdict /= Invalid_Case then
         raise Protocol_Error
           with "semantic adapter result has no conformance evidence";
      end if;
      return
        "{""format"":""counterweave.adapter-result/2"",""pack"":{""name"":"
        & Counterweave.Strings.JSON_String (To_String (Item.Pack_Name))
        & ",""version"":"
        & Counterweave.Strings.JSON_String (To_String (Item.Pack_Version))
        & "},""verdict"":"
        & Counterweave.Strings.JSON_String (Image (Item.Verdict))
        & ",""property"":"
        & Counterweave.Strings.JSON_String (To_String (Item.Property_Name))
        & ",""fingerprint"":"
        & Fingerprint
        & ",""observations"":"
        & To_String (Item.Observations_JSON)
        & ",""conformance"":"
        & (if Has_Trace (Item)
           then To_String (Item.Conformance_JSON)
           else "null")
        & ",""trace"":"
        & (if Has_Trace (Item) then To_String (Item.Trace_JSON) else "null")
        & "}";
   end To_JSON;

   procedure Evidence_From_Run
     (Source           : String;
      Trace_JSON       : out Unbounded_String;
      Conformance_JSON : out Unbounded_String)
   is
      Root    : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Format  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "format")));
      Adapter : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "adapter_result");
   begin
      Trace_JSON := Null_Unbounded_String;
      Conformance_JSON := Null_Unbounded_String;
      if Format /= "counterweave.run/3" then
         raise Protocol_Error with "unsupported run artifact format";
      elsif Counterweave.JSON.Kind (Adapter) = Counterweave.JSON.Null_Value
      then
         return;
      elsif Counterweave.JSON.Kind (Adapter) /= Counterweave.JSON.Object_Value
      then
         raise Protocol_Error with "run adapter result has invalid type";
      end if;
      declare
         Adapter_Source : constant String :=
           Counterweave.JSON.Image (Source, Adapter);
         Adapter_Root   : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (Adapter_Source);
         Pack           : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Member (Adapter_Source, Adapter_Root, "pack");
         Name           : constant String :=
           To_String
             (Counterweave.JSON.As_String
                (Adapter_Source,
                 Counterweave.JSON.Member (Adapter_Source, Pack, "name")));
         Version        : constant String :=
           To_String
             (Counterweave.JSON.As_String
                (Adapter_Source,
                 Counterweave.JSON.Member (Adapter_Source, Pack, "version")));
         Result         : constant Adapter_Result :=
           Parse (Adapter_Source, Name, Version);
      begin
         Trace_JSON := Result.Trace_JSON;
         Conformance_JSON := Result.Conformance_JSON;
      end;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Protocol_Error with "malformed run artifact";
   end Evidence_From_Run;

end Counterweave.Adapter_Results;
