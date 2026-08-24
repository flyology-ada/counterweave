with Ada.Directories;
with Counterweave.Hashes;
with Counterweave.JSON;
with GNAT.OS_Lib;

package body Counterweave.Artifacts is

   use Ada.Strings.Unbounded;
   use type Counterweave.JSON.Value_Kind;
   use type GNAT.OS_Lib.String_Access;

   function Outcome_Image
     (Outcome : Counterweave.Processes.Outcome_Kind) return String is
   begin
      case Outcome is
         when Counterweave.Processes.Completed      =>
            return "completed";

         when Counterweave.Processes.Failed         =>
            return "adapter-error";

         when Counterweave.Processes.Timed_Out      =>
            return "timeout";

         when Counterweave.Processes.Cancelled      =>
            return "cancelled";

         when Counterweave.Processes.Output_Limit   =>
            return "output-limit";

         when Counterweave.Processes.Spawn_Error    =>
            return "spawn-error";

         when Counterweave.Processes.Protocol_Error =>
            return "protocol-error";
      end case;
   end Outcome_Image;

   function Optional_Hash (Value : Unbounded_String) return String
   is (if Length (Value) = 0
       then "null"
       else Counterweave.Strings.JSON_String (To_String (Value)));

   function Arguments_JSON
     (Arguments : Counterweave.Strings.String_Vector) return String
   is
      Result : Unbounded_String := To_Unbounded_String ("[");
      First  : Boolean := True;
   begin
      for Argument of Arguments loop
         if First then
            First := False;
         else
            Append (Result, ",");
         end if;
         Append (Result, Counterweave.Strings.JSON_String (Argument));
      end loop;
      Append (Result, "]");
      return To_String (Result);
   end Arguments_JSON;

   function Executable_Path (Program : String) return String is
      Located : GNAT.OS_Lib.String_Access := null;
   begin
      if Ada.Directories.Exists (Program) then
         return GNAT.OS_Lib.Normalize_Pathname (Program);
      end if;
      Located := GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      if Located = null then
         return "";
      end if;
      declare
         Result : constant String :=
           GNAT.OS_Lib.Normalize_Pathname (Located.all);
      begin
         GNAT.OS_Lib.Free (Located);
         return Result;
      end;
   exception
      when others =>
         GNAT.OS_Lib.Free (Located);
         return "";
   end Executable_Path;

   function Executable_SHA256 (Program : String) return String is
      Path : constant String := Executable_Path (Program);
   begin
      if Path'Length = 0 then
         return "";
      end if;
      return Counterweave.Hashes.SHA256_File (Path);
   exception
      when others =>
         return "";
   end Executable_SHA256;

   procedure Write_Case (Path : String; Data : Case_Data) is
      Solver_Seed : constant String :=
        (if Data.Seed_Applied
         then
           Counterweave.Strings.JSON_String
             (Counterweave.Strings.Compact_Image (Data.Solver_Seed))
         else "null");
      Content     : constant String :=
        "{"
        & ASCII.LF
        & "  ""format"": ""counterweave.case/2"","
        & ASCII.LF
        & "  ""pack"": {""name"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Pack_Name))
        & ", ""version"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Pack_Version))
        & "},"
        & ASCII.LF
        & "  ""intent"": {""kind"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Intent_Kind))
        & ", ""target"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Intent_Target))
        & "},"
        & ASCII.LF
        & "  ""provenance"": {"
        & ASCII.LF
        & "    ""counterweave_version"": "
        & Counterweave.Strings.JSON_String (Counterweave.Version)
        & ","
        & ASCII.LF
        & "    ""choices"": "
        & Counterweave.Choices.To_JSON (Data.Choices)
        & ","
        & ASCII.LF
        & "    ""model"": {""backend"": ""minizinc"", ""solver"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Solver))
        & ", ""minizinc_version"": "
        & Counterweave.Strings.JSON_String (To_String (Data.MiniZinc_Version))
        & ", ""model_sha256"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Model_SHA256))
        & ", ""compiled_sha256"": "
        & Counterweave.Strings.JSON_String (To_String (Data.Compiled_SHA256))
        & ", ""data_sha256"": "
        & Optional_Hash (Data.Data_SHA256)
        & ", ""diversity_seed"": "
        & Counterweave.Strings.JSON_String
            (Counterweave.Strings.Compact_Image (Data.Diversity_Seed))
        & ", ""solver_seed"": "
        & Solver_Seed
        & "}"
        & ASCII.LF
        & "  },"
        & ASCII.LF
        & "  ""payload"": {""parameters"": "
        & To_String (Data.Parameters_JSON)
        & ", ""solution"": "
        & To_String (Data.Solution_JSON)
        & "}"
        & ASCII.LF
        & "}"
        & ASCII.LF;
   begin
      declare
         Parameters : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (To_String (Data.Parameters_JSON));
         Solution   : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (To_String (Data.Solution_JSON));
      begin
         pragma Unreferenced (Parameters, Solution);
      end;
      Counterweave.Strings.Write_File_Atomically (Path, Content);
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Counterweave.Strings.Format_Error
           with "case payload contains invalid JSON";
   end Write_Case;

   function Choices_From_Case
     (Source : String) return Counterweave.Choices.Choice_Tape
   is
      Root       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Provenance : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "provenance");
      Choices    : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Provenance, "choices");
   begin
      return
        Counterweave.Choices.From_JSON
          (Counterweave.JSON.Image (Source, Choices));
   end Choices_From_Case;

   function Case_Replay_SHA256 (Source : String) return String is
      Root        : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Pack        : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "pack");
      Intent      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "intent");
      Provenance  : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "provenance");
      Choices     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Provenance, "choices");
      Model       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Provenance, "model");
      Payload     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "payload");
      Stable_View : constant String :=
        "{""pack"":"
        & Counterweave.JSON.Canonical_Image (Source, Pack)
        & ",""intent"":"
        & Counterweave.JSON.Canonical_Image (Source, Intent)
        & ",""choices"":"
        & Counterweave.JSON.Canonical_Image (Source, Choices)
        & ",""model_sha256"":"
        & Counterweave.JSON.Canonical_Image
            (Source, Counterweave.JSON.Member (Source, Model, "model_sha256"))
        & ",""diversity_seed"":"
        & Counterweave.JSON.Canonical_Image
            (Source,
             Counterweave.JSON.Member (Source, Model, "diversity_seed"))
        & ",""payload"":"
        & Counterweave.JSON.Canonical_Image (Source, Payload)
        & "}";
   begin
      return Counterweave.Hashes.SHA256 (Stable_View);
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Counterweave.Strings.Format_Error
           with "malformed case replay identity";
   end Case_Replay_SHA256;

   procedure Case_Pack
     (Source  : String;
      Name    : out Unbounded_String;
      Version : out Unbounded_String)
   is
      Root : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Pack : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "pack");
   begin
      Name :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name"));
      Version :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version"));
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Counterweave.Strings.Format_Error
           with "malformed case pack identity";
   end Case_Pack;

   procedure Validate_Case (Source : String) is
      Root       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Pack       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "pack");
      Intent     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "intent");
      Provenance : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "provenance");
      Model      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Provenance, "model");
      Payload    : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "payload");
      Format     : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "format")));
      Ignored    : Unbounded_String;
   begin
      if Format /= "counterweave.case/2" then
         raise Counterweave.Strings.Format_Error
           with "unsupported case artifact format";
      elsif Counterweave.JSON.Kind (Pack) /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Intent)
                /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Provenance)
                /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Model)
                /= Counterweave.JSON.Object_Value
        or else Counterweave.JSON.Kind (Payload)
                /= Counterweave.JSON.Object_Value
      then
         raise Counterweave.Strings.Format_Error
           with "case artifact envelope has invalid types";
      end if;
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Intent, "kind"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Intent, "target"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source,
           Counterweave.JSON.Member
             (Source, Provenance, "counterweave_version"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "backend"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "solver"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source,
           Counterweave.JSON.Member (Source, Model, "minizinc_version"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "model_sha256"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source,
           Counterweave.JSON.Member (Source, Model, "compiled_sha256"));
      Ignored :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "diversity_seed"));
      declare
         Tape : constant Counterweave.Choices.Choice_Tape :=
           Choices_From_Case (Source);
      begin
         pragma Unreferenced (Tape);
      end;
      if not Counterweave.JSON.Has_Member (Source, Payload, "parameters")
        or else not Counterweave.JSON.Has_Member (Source, Payload, "solution")
      then
         raise Counterweave.Strings.Format_Error
           with "case artifact payload is incomplete";
      end if;
   exception
      when Counterweave.JSON.JSON_Error | Counterweave.Choices.Choice_Error =>
         raise Counterweave.Strings.Format_Error
           with "malformed case artifact";
   end Validate_Case;

   procedure Write_Run
     (Path               : String;
      Case_Path          : String;
      Adapter            : String;
      Adapter_SHA256     : String;
      Arguments          : Counterweave.Strings.String_Vector;
      Process            : Counterweave.Processes.Process_Result;
      Has_Adapter_Result : Boolean;
      Adapter_Result     : Counterweave.Adapter_Results.Adapter_Result)
   is
      Standard_Output : constant String := To_String (Process.Standard_Output);
      Run_Outcome     : constant String :=
        (if Has_Adapter_Result
         then Counterweave.Adapter_Results.Image (Adapter_Result.Verdict)
         else Outcome_Image (Process.Outcome));
      Content         : constant String :=
        "{"
        & ASCII.LF
        & "  ""format"": ""counterweave.run/2"","
        & ASCII.LF
        & "  ""case_sha256"": "
        & Counterweave.Strings.JSON_String
            (Counterweave.Hashes.SHA256_File (Case_Path))
        & ","
        & ASCII.LF
        & "  ""counterweave_version"": "
        & Counterweave.Strings.JSON_String (Counterweave.Version)
        & ","
        & ASCII.LF
        & "  ""adapter"": "
        & Counterweave.Strings.JSON_String (Adapter)
        & ","
        & ASCII.LF
        & "  ""adapter_sha256"": "
        & (if Adapter_SHA256'Length = 0
           then "null"
           else Counterweave.Strings.JSON_String (Adapter_SHA256))
        & ","
        & ASCII.LF
        & "  ""arguments"": "
        & Arguments_JSON (Arguments)
        & ","
        & ASCII.LF
        & "  ""outcome"": "
        & Counterweave.Strings.JSON_String (Run_Outcome)
        & ","
        & ASCII.LF
        & "  ""process"": {""outcome"": "
        & Counterweave.Strings.JSON_String (Outcome_Image (Process.Outcome))
        & ", ""stdout"": "
        & Counterweave.Strings.JSON_String (Standard_Output)
        & ", ""stderr"": "
        & Counterweave.Strings.JSON_String (To_String (Process.Standard_Error))
        & ", ""duration_ms"": "
        & Counterweave.Strings.Compact_Image
            (Long_Long_Integer (Process.Elapsed_Milliseconds))
        & "},"
        & ASCII.LF
        & "  ""adapter_result"": "
        & (if Has_Adapter_Result
           then Counterweave.Adapter_Results.To_JSON (Adapter_Result)
           else "null")
        & ASCII.LF
        & "}"
        & ASCII.LF;
   begin
      Counterweave.Strings.Write_File_Atomically (Path, Content);
   end Write_Run;

end Counterweave.Artifacts;
