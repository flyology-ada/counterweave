with Counterweave.JSON;
with Counterweave.Strings;

package body Counterweave.Adapter_Results is

   use Ada.Strings.Unbounded;
   use type Counterweave.JSON.Value_Kind;

   function Image (Verdict : Verdict_Kind) return String
   is (case Verdict is
         when Passed             => "pass",
         when Property_Violation => "property-violation",
         when Invalid_Case       => "invalid-case");

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
      Result        : Adapter_Result;
   begin
      if Counterweave.JSON.Kind (Root) /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Pack) /= Counterweave.JSON.Object_Value
      then
         raise Protocol_Error with "adapter result envelope has invalid types";
      elsif Format /= "counterweave.adapter-result/1" then
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
      return Result;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Protocol_Error with "malformed adapter result";
   end Parse;

   function To_JSON (Item : Adapter_Result) return String is
      Fingerprint : constant String :=
        (if Item.Verdict = Property_Violation
         then
           Counterweave.Strings.JSON_String
             (To_String (Item.Failure_Fingerprint))
         else "null");
   begin
      return
        "{""format"":""counterweave.adapter-result/1"",""pack"":{""name"":"
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
        & "}";
   end To_JSON;

end Counterweave.Adapter_Results;
