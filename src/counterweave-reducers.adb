with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Counterweave.Adapter_Results;
with Counterweave.Artifacts;
with Counterweave.Campaigns;
with Counterweave.Hashes;
with Counterweave.JSON;
with Counterweave.Processes;
with Counterweave.Strings;

package body Counterweave.Reducers is

   use Ada.Strings.Unbounded;
   use type Counterweave.Adapter_Results.Verdict_Kind;
   use type Counterweave.JSON.Value_Kind;
   use type Counterweave.Processes.Outcome_Kind;

   type Draw is record
      Name    : Unbounded_String;
      Minimum : Long_Long_Integer;
      Maximum : Long_Long_Integer;
      Current : Long_Long_Integer;
   end record;

   package Draw_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Draw);

   type Evaluation_Kind is (Preserved, Different_Result, Infrastructure_Error);

   type Evaluation is record
      Outcome : Evaluation_Kind := Infrastructure_Error;
      Detail  : Unbounded_String;
   end record;

   function Parse_Draw
     (Text        : String;
      Parameters  : Counterweave.JSON.Value;
      Case_Source : String) return Draw
   is
      Equals : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
      Dots   : constant Natural :=
        Ada.Strings.Fixed.Index (Text, "..", From => Equals + 1);
   begin
      if Equals <= Text'First or else Dots = 0 or else Dots + 1 >= Text'Last
      then
         raise Reduction_Error with "campaign contains malformed draw";
      end if;
      declare
         Name   : constant String := Text (Text'First .. Equals - 1);
         Result : constant Draw :=
           (Name    => To_Unbounded_String (Name),
            Minimum => Long_Long_Integer'Value (Text (Equals + 1 .. Dots - 1)),
            Maximum => Long_Long_Integer'Value (Text (Dots + 2 .. Text'Last)),
            Current =>
              Counterweave.JSON.As_Integer
                (Case_Source,
                 Counterweave.JSON.Member (Case_Source, Parameters, Name)));
      begin
         if Result.Minimum > Result.Maximum
           or else Result.Current < Result.Minimum
           or else Result.Current > Result.Maximum
         then
            raise Reduction_Error
              with "retained parameter is outside its campaign draw";
         end if;
         return Result;
      end;
   exception
      when Counterweave.JSON.JSON_Error | Constraint_Error =>
         raise Reduction_Error with "campaign draw cannot be decoded";
   end Parse_Draw;

   function Target (Item : Draw) return Long_Long_Integer
   is (if Item.Minimum <= 0 and then Item.Maximum >= 0
       then 0
       elsif Item.Maximum < 0
       then Item.Maximum
       else Item.Minimum);

   function Midpoint (Left, Right : Long_Long_Integer) return Long_Long_Integer
   is
   begin
      if (Left < 0 and then Right > 0) or else (Left > 0 and then Right < 0)
      then
         return Left / 2 + Right / 2 + (Left rem 2 + Right rem 2) / 2;
      end if;
      return Left + (Right - Left) / 2;
   end Midpoint;

   function Draw_Image (Item : Draw) return String
   is (To_String (Item.Name)
       & "="
       & Counterweave.Strings.Compact_Image (Item.Current)
       & ".."
       & Counterweave.Strings.Compact_Image (Item.Current));

   procedure Reduce
     (Campaign_Path : String;
      Executable    : String;
      Case_Output   : String;
      Run_Output    : String;
      Report_Output : String)
   is
      Campaign_Source        : constant String :=
        Counterweave.Strings.Read_File (Campaign_Path);
      Campaign_Root          : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Campaign_Source);
      Configuration          : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Campaign_Source, Campaign_Root, "configuration");
      Attempts               : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Campaign_Source, Campaign_Root, "attempts");
      Draw_Nodes             : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Campaign_Source, Configuration, "draws");
      Adapter_Argument_Nodes : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Campaign_Source, Configuration, "adapter_arguments");

      function String_Member
        (Source : String; Item : Counterweave.JSON.Value; Name : String)
         return String
      is (To_String
            (Counterweave.JSON.As_String
               (Source, Counterweave.JSON.Member (Source, Item, Name))));

      function Integer_Member
        (Item : Counterweave.JSON.Value; Name : String) return Positive
      is (Positive
            (Counterweave.JSON.As_Integer
               (Campaign_Source,
                Counterweave.JSON.Member (Campaign_Source, Item, Name))));

      Model                : constant String :=
        String_Member (Campaign_Source, Configuration, "model");
      Data_Node            : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Campaign_Source, Configuration, "data");
      Solver               : constant String :=
        String_Member (Campaign_Source, Configuration, "solver");
      Pack                 : constant String :=
        String_Member (Campaign_Source, Configuration, "pack");
      Pack_Version         : constant String :=
        String_Member (Campaign_Source, Configuration, "pack_version");
      Intent               : constant String :=
        String_Member (Campaign_Source, Configuration, "intent");
      Target_Name          : constant String :=
        String_Member (Campaign_Source, Configuration, "target");
      Adapter              : constant String :=
        String_Member (Campaign_Source, Configuration, "adapter");
      Retained_Case_Path   : constant String :=
        String_Member (Campaign_Source, Configuration, "case_output");
      Retained_Run_Path    : constant String :=
        String_Member (Campaign_Source, Configuration, "run_output");
      Solver_Timeout       : constant Positive :=
        Integer_Member (Configuration, "solver_timeout_ms");
      Adapter_Timeout      : constant Positive :=
        Integer_Member (Configuration, "adapter_timeout_ms");
      Retained_Case_Source : constant String :=
        Counterweave.Strings.Read_File (Retained_Case_Path);
      Retained_Root        : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Retained_Case_Source);
      Retained_Payload     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Root, "payload");
      Parameters           : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Payload, "parameters");
      Failure_Seed         : Unbounded_String;
      Failure_Property     : Unbounded_String;
      Failure_Fingerprint  : Unbounded_String;
      Failure_Case_Hash    : Unbounded_String;
      Draws                : Draw_Vectors.Vector;
      Adapter_Arguments    : Counterweave.Strings.String_Vector;
      Attempts_JSON        : Unbounded_String := To_Unbounded_String ("[");
      First_Attempt        : Boolean := True;
      Reduction_Attempts   : Natural := 0;

      function Current_Case_Replay_Hash return String is
      begin
         if not Ada.Directories.Exists (Case_Output) then
            return "null";
         end if;
         return
           Counterweave.Strings.JSON_String
             (Counterweave.Artifacts.Case_Replay_SHA256
                (Counterweave.Strings.Read_File (Case_Output)));
      exception
         when others =>
            return "null";
      end Current_Case_Replay_Hash;

      function Current_Run_Hash return String is
      begin
         if not Ada.Directories.Exists (Run_Output) then
            return "null";
         end if;
         return
           Counterweave.Strings.JSON_String
             (Counterweave.Hashes.SHA256_File (Run_Output));
      exception
         when others =>
            return "null";
      end Current_Run_Hash;

      procedure Record_Attempt
        (Name      : String;
         Previous  : Long_Long_Integer;
         Candidate : Long_Long_Integer;
         Result    : Evaluation) is
      begin
         if First_Attempt then
            First_Attempt := False;
         else
            Append (Attempts_JSON, ",");
         end if;
         Reduction_Attempts := Reduction_Attempts + 1;
         Append
           (Attempts_JSON,
            "{""parameter"":"
            & Counterweave.Strings.JSON_String (Name)
            & ",""from"":"
            & Counterweave.Strings.Compact_Image (Previous)
            & ",""candidate"":"
            & Counterweave.Strings.Compact_Image (Candidate)
            & ",""outcome"":"
            & Counterweave.Strings.JSON_String
                (case Result.Outcome is
                   when Preserved            => "preserved",
                   when Different_Result     => "different-result",
                   when Infrastructure_Error => "infrastructure-error")
            & ",""detail"":"
            & Counterweave.Strings.JSON_String (To_String (Result.Detail))
            & ",""case_replay_sha256"":"
            & Current_Case_Replay_Hash
            & ",""run_sha256"":"
            & Current_Run_Hash
            & "}");
      end Record_Attempt;

      function Evaluate return Evaluation is
         Generate_Arguments : Counterweave.Strings.String_Vector;
      begin
         if Ada.Directories.Exists (Case_Output) then
            Ada.Directories.Delete_File (Case_Output);
         end if;
         if Ada.Directories.Exists (Run_Output) then
            Ada.Directories.Delete_File (Run_Output);
         end if;
         Generate_Arguments.Append ("generate");
         Generate_Arguments.Append ("--model");
         Generate_Arguments.Append (Model);
         if Counterweave.JSON.Kind (Data_Node) = Counterweave.JSON.String_Value
         then
            Generate_Arguments.Append ("--data");
            Generate_Arguments.Append
              (To_String
                 (Counterweave.JSON.As_String (Campaign_Source, Data_Node)));
         end if;
         Generate_Arguments.Append ("--solver");
         Generate_Arguments.Append (Solver);
         Generate_Arguments.Append ("--pack");
         Generate_Arguments.Append (Pack);
         Generate_Arguments.Append ("--pack-version");
         Generate_Arguments.Append (Pack_Version);
         Generate_Arguments.Append ("--intent");
         Generate_Arguments.Append (Intent);
         Generate_Arguments.Append ("--target");
         Generate_Arguments.Append (Target_Name);
         Generate_Arguments.Append ("--seed");
         Generate_Arguments.Append (To_String (Failure_Seed));
         Generate_Arguments.Append ("--solver-timeout-ms");
         Generate_Arguments.Append
           (Counterweave.Strings.Compact_Image
              (Long_Long_Integer (Solver_Timeout)));
         for Item of Draws loop
            Generate_Arguments.Append ("--draw");
            Generate_Arguments.Append (Draw_Image (Item));
         end loop;
         Generate_Arguments.Append ("--output");
         Generate_Arguments.Append (Case_Output);
         declare
            Generated : constant Counterweave.Processes.Process_Result :=
              Counterweave.Processes.Run
                (Executable, Generate_Arguments, Solver_Timeout + 5_000);
         begin
            if Generated.Outcome /= Counterweave.Processes.Completed then
               return
                 (Outcome => Infrastructure_Error,
                  Detail  => Generated.Standard_Error);
            end if;
         end;

         declare
            Execute_Arguments : Counterweave.Strings.String_Vector;
         begin
            Execute_Arguments.Append ("execute");
            Execute_Arguments.Append ("--case");
            Execute_Arguments.Append (Case_Output);
            Execute_Arguments.Append ("--adapter");
            Execute_Arguments.Append (Adapter);
            Execute_Arguments.Append ("--timeout-ms");
            Execute_Arguments.Append
              (Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (Adapter_Timeout)));
            for Argument of Adapter_Arguments loop
               Execute_Arguments.Append ("--adapter-arg");
               Execute_Arguments.Append (Argument);
            end loop;
            Execute_Arguments.Append ("--output");
            Execute_Arguments.Append (Run_Output);
            declare
               Executed : constant Counterweave.Processes.Process_Result :=
                 Counterweave.Processes.Run
                   (Executable, Execute_Arguments, Adapter_Timeout + 5_000);
            begin
               if Executed.Outcome
                  not in Counterweave.Processes.Completed
                       | Counterweave.Processes.Failed
                 or else not Ada.Directories.Exists (Run_Output)
               then
                  return
                    (Outcome => Infrastructure_Error,
                     Detail  => Executed.Standard_Error);
               end if;
            end;
         end;

         declare
            Run_Source : constant String :=
              Counterweave.Strings.Read_File (Run_Output);
            Run_Root   : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Parse (Run_Source);
            Outcome    : constant String :=
              String_Member (Run_Source, Run_Root, "outcome");
         begin
            if Outcome /= "property-violation" then
               return
                 (Outcome => Different_Result,
                  Detail  => To_Unbounded_String (Outcome));
            end if;
            declare
               Adapter_Node : constant Counterweave.JSON.Value :=
                 Counterweave.JSON.Member
                   (Run_Source, Run_Root, "adapter_result");
               Protocol     :
                 constant Counterweave.Adapter_Results.Adapter_Result :=
                   Counterweave.Adapter_Results.Parse
                     (Counterweave.JSON.Image (Run_Source, Adapter_Node),
                      Pack,
                      Pack_Version);
            begin
               if Protocol.Verdict
                 = Counterweave.Adapter_Results.Property_Violation
                 and then Protocol.Property_Name = Failure_Property
                 and then Protocol.Failure_Fingerprint = Failure_Fingerprint
               then
                  return
                    (Outcome => Preserved,
                     Detail  => Protocol.Failure_Fingerprint);
               end if;
               return
                 (Outcome => Different_Result,
                  Detail  => Protocol.Failure_Fingerprint);
            end;
         end;
      exception
         when
           Counterweave.JSON.JSON_Error
           | Counterweave.Adapter_Results.Protocol_Error
           | Counterweave.Strings.Format_Error
         =>
            return
              (Outcome => Infrastructure_Error,
               Detail  =>
                 To_Unbounded_String ("malformed candidate evidence"));
      end Evaluate;

      function Parameters_JSON return String is
         Result : Unbounded_String := To_Unbounded_String ("{");
         First  : Boolean := True;
      begin
         for Item of Draws loop
            if First then
               First := False;
            else
               Append (Result, ",");
            end if;
            Append
              (Result,
               Counterweave.Strings.JSON_String (To_String (Item.Name))
               & ":"
               & Counterweave.Strings.Compact_Image (Item.Current));
         end loop;
         Append (Result, "}");
         return To_String (Result);
      end Parameters_JSON;
   begin
      if Counterweave.Strings.Same_Path (Case_Output, Campaign_Path)
        or else Counterweave.Strings.Same_Path (Run_Output, Campaign_Path)
        or else Counterweave.Strings.Same_Path (Report_Output, Campaign_Path)
        or else Counterweave.Strings.Same_Path
                  (Case_Output, Retained_Case_Path)
        or else Counterweave.Strings.Same_Path (Case_Output, Retained_Run_Path)
        or else Counterweave.Strings.Same_Path (Run_Output, Retained_Case_Path)
        or else Counterweave.Strings.Same_Path (Run_Output, Retained_Run_Path)
        or else Counterweave.Strings.Same_Path
                  (Report_Output, Retained_Case_Path)
        or else Counterweave.Strings.Same_Path
                  (Report_Output, Retained_Run_Path)
        or else Counterweave.Strings.Same_Path (Case_Output, Run_Output)
        or else Counterweave.Strings.Same_Path (Case_Output, Report_Output)
        or else Counterweave.Strings.Same_Path (Run_Output, Report_Output)
      then
         raise Reduction_Error
           with "reduction outputs must be distinct from retained evidence";
      end if;
      declare
         Ignored : constant Counterweave.Strings.String_Vector :=
           Counterweave.Campaigns.Replay_Arguments
             (Source          => Campaign_Source,
              Case_Output     => Case_Output,
              Run_Output      => Run_Output,
              Campaign_Output => Report_Output & ".campaign-check");
      begin
         pragma Unreferenced (Ignored);
      end;
      if Ada.Directories.Exists (Report_Output) then
         Ada.Directories.Delete_File (Report_Output);
      end if;
      if String_Member (Campaign_Source, Campaign_Root, "status")
        /= "property-violation"
      then
         raise Reduction_Error
           with "campaign has no retained property violation";
      end if;
      for Index in 0 .. Counterweave.JSON.Length (Campaign_Source, Attempts)
      loop
         exit when
           Index = Counterweave.JSON.Length (Campaign_Source, Attempts);
         declare
            Item : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Element (Campaign_Source, Attempts, Index);
         begin
            if String_Member (Campaign_Source, Item, "outcome")
              = "property-violation"
            then
               Failure_Seed :=
                 To_Unbounded_String
                   (String_Member (Campaign_Source, Item, "seed"));
               Failure_Fingerprint :=
                 To_Unbounded_String
                   (String_Member
                      (Campaign_Source, Item, "failure_fingerprint"));
               Failure_Property :=
                 To_Unbounded_String
                   (String_Member (Campaign_Source, Item, "property"));
               Failure_Case_Hash :=
                 To_Unbounded_String
                   (String_Member
                      (Campaign_Source, Item, "case_replay_sha256"));
               exit;
            end if;
         end;
      end loop;
      if Length (Failure_Seed) = 0
        or else Length (Failure_Property) = 0
        or else Length (Failure_Fingerprint) = 0
      then
         raise Reduction_Error with "campaign failure evidence is incomplete";
      elsif Counterweave.Artifacts.Case_Replay_SHA256 (Retained_Case_Source)
        /= To_String (Failure_Case_Hash)
      then
         raise Reduction_Error
           with "retained case does not match the campaign";
      end if;

      for Index in 0 .. Counterweave.JSON.Length (Campaign_Source, Draw_Nodes)
      loop
         exit when
           Index = Counterweave.JSON.Length (Campaign_Source, Draw_Nodes);
         declare
            Text : constant String :=
              To_String
                (Counterweave.JSON.As_String
                   (Campaign_Source,
                    Counterweave.JSON.Element
                      (Campaign_Source, Draw_Nodes, Index)));
         begin
            Draws.Append (Parse_Draw (Text, Parameters, Retained_Case_Source));
         end;
      end loop;
      for Index in
        0 .. Counterweave.JSON.Length (Campaign_Source, Adapter_Argument_Nodes)
      loop
         exit when
           Index
           = Counterweave.JSON.Length
               (Campaign_Source, Adapter_Argument_Nodes);
         Adapter_Arguments.Append
           (To_String
              (Counterweave.JSON.As_String
                 (Campaign_Source,
                  Counterweave.JSON.Element
                    (Campaign_Source, Adapter_Argument_Nodes, Index))));
      end loop;

      declare
         Baseline : constant Evaluation := Evaluate;
      begin
         if Baseline.Outcome /= Preserved then
            raise Reduction_Error
              with "retained failure does not reproduce before reduction";
         end if;
      end;

      loop
         declare
            Changed : Boolean := False;
         begin
            for Index in Draws.First_Index .. Draws.Last_Index loop
               declare
                  Item        : Draw := Draws (Index);
                  Previous    : Long_Long_Integer := Item.Current;
                  Lower_Bound : Long_Long_Integer := Target (Item);
                  Candidate   : Long_Long_Integer := Lower_Bound;
                  Result      : Evaluation;
               begin
                  if Candidate /= Item.Current then
                     Item.Current := Candidate;
                     Draws.Replace_Element (Index, Item);
                     Result := Evaluate;
                     Record_Attempt
                       (To_String (Item.Name), Previous, Candidate, Result);
                     if Result.Outcome = Preserved then
                        Previous := Candidate;
                        Changed := True;
                     else
                        Item.Current := Previous;
                        Draws.Replace_Element (Index, Item);
                        loop
                           Candidate := Midpoint (Lower_Bound, Previous);
                           exit when
                             Candidate = Lower_Bound
                             or else Candidate = Previous;
                           Item.Current := Candidate;
                           Draws.Replace_Element (Index, Item);
                           Result := Evaluate;
                           Record_Attempt
                             (To_String (Item.Name),
                              Previous,
                              Candidate,
                              Result);
                           if Result.Outcome = Preserved then
                              Previous := Candidate;
                              Changed := True;
                           else
                              Lower_Bound := Candidate;
                           end if;
                           Item.Current := Previous;
                           Draws.Replace_Element (Index, Item);
                        end loop;
                     end if;
                  end if;
               end;
            end loop;
            exit when not Changed;
         end;
      end loop;

      declare
         Final_Result : constant Evaluation := Evaluate;
      begin
         if Final_Result.Outcome /= Preserved then
            raise Reduction_Error
              with "final reduced case lost the failure fingerprint";
         end if;
      end;
      Append (Attempts_JSON, "]");
      Counterweave.Strings.Write_File_Atomically
        (Report_Output,
         "{"
         & ASCII.LF
         & "  ""format"": ""counterweave.reduction/1"","
         & ASCII.LF
         & "  ""campaign_sha256"": "
         & Counterweave.Strings.JSON_String
             (Counterweave.Hashes.SHA256_File (Campaign_Path))
         & ","
         & ASCII.LF
         & "  ""property"": "
         & Counterweave.Strings.JSON_String (To_String (Failure_Property))
         & ","
         & ASCII.LF
         & "  ""failure_fingerprint"": "
         & Counterweave.Strings.JSON_String (To_String (Failure_Fingerprint))
         & ","
         & ASCII.LF
         & "  ""original_parameters"": "
         & Counterweave.JSON.Image (Retained_Case_Source, Parameters)
         & ","
         & ASCII.LF
         & "  ""original_case_replay_sha256"": "
         & Counterweave.Strings.JSON_String (To_String (Failure_Case_Hash))
         & ","
         & ASCII.LF
         & "  ""attempt_count"": "
         & Counterweave.Strings.Compact_Image
             (Long_Long_Integer (Reduction_Attempts))
         & ","
         & ASCII.LF
         & "  ""attempts"": "
         & To_String (Attempts_JSON)
         & ","
         & ASCII.LF
         & "  ""final_parameters"": "
         & Parameters_JSON
         & ","
         & ASCII.LF
         & "  ""case_sha256"": "
         & Counterweave.Strings.JSON_String
             (Counterweave.Hashes.SHA256_File (Case_Output))
         & ","
         & ASCII.LF
         & "  ""case_replay_sha256"": "
         & Counterweave.Strings.JSON_String
             (Counterweave.Artifacts.Case_Replay_SHA256
                (Counterweave.Strings.Read_File (Case_Output)))
         & ","
         & ASCII.LF
         & "  ""run_sha256"": "
         & Counterweave.Strings.JSON_String
             (Counterweave.Hashes.SHA256_File (Run_Output))
         & ASCII.LF
         & "}"
         & ASCII.LF);
   exception
      when
        Counterweave.Campaigns.Campaign_Error
        | Counterweave.JSON.JSON_Error
        | Counterweave.Strings.Format_Error
      =>
         raise Reduction_Error with "campaign reduction input is malformed";
   end Reduce;

end Counterweave.Reducers;
