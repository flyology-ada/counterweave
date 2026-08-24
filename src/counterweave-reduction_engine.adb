with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Counterweave.Adapter_Results;
with Counterweave.Artifacts;
with Counterweave.Campaigns;
with Counterweave.Choices;
with Counterweave.Hashes;
with Counterweave.JSON;
with Counterweave.Processes;
with Counterweave.Strings;
with Counterweave.Traces;
with GNAT.OS_Lib;
with Interfaces;

package body Counterweave.Reduction_Engine is

   use Ada.Strings.Unbounded;
   use type Counterweave.Adapter_Results.Verdict_Kind;
   use type Counterweave.Choices.Shrink_Stop_Reason;
   use type Counterweave.JSON.Value_Kind;
   use type Counterweave.Processes.Outcome_Kind;
   use type Interfaces.Unsigned_64;

   type Evaluation_Kind is
     (Preserved, Different_Result, Invalid_Candidate, Infrastructure_Error);

   type Evaluation is record
      Outcome : Evaluation_Kind := Infrastructure_Error;
      Detail  : Unbounded_String;
   end record;

   procedure Reduce
     (Campaign_Path    : String;
      Executable       : String;
      Case_Output      : String;
      Run_Output       : String;
      Report_Output    : String;
      Maximum_Attempts : Positive;
      Progress         :
        access procedure (Update : Counterweave.Reducers.Reduction_Update);
      Stop             : access function return Boolean)
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

      function Temporary_Choice_Path return String is
         Directory : constant String :=
           (if Ada.Environment_Variables.Exists ("TMPDIR")
            then Ada.Environment_Variables.Value ("TMPDIR")
            else "/tmp");
         PID       : constant String :=
           Counterweave.Strings.Compact_Image
             (Long_Long_Integer
                (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)));
      begin
         return
           Ada.Directories.Compose
             (Directory, "counterweave-reduction-choices-" & PID & ".json");
      end Temporary_Choice_Path;

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
      Choice_Path          : constant String := Temporary_Choice_Path;
      Retained_Case_Source : constant String :=
        Counterweave.Strings.Read_File (Retained_Case_Path);
      Retained_Root        : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Retained_Case_Source);
      Retained_Payload     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Root, "payload");
      Retained_Provenance  : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Root, "provenance");
      Retained_Model       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Provenance, "model");
      Original_Parameters  : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member
          (Retained_Case_Source, Retained_Payload, "parameters");
      Original_Tape        : constant Counterweave.Choices.Choice_Tape :=
        Counterweave.Artifacts.Choices_From_Case (Retained_Case_Source);
      Reduced_Tape         : Counterweave.Choices.Choice_Tape;
      Failure_Seed         : Unbounded_String;
      Failure_Property     : Unbounded_String;
      Failure_Fingerprint  : Unbounded_String;
      Failure_Case_Hash    : Unbounded_String;
      Draw_Arguments       : Counterweave.Strings.String_Vector;
      Adapter_Arguments    : Counterweave.Strings.String_Vector;
      Attempts_JSON        : Unbounded_String := To_Unbounded_String ("[");
      First_Attempt        : Boolean := True;
      Reduction_Attempts   : Natural := 0;
      Accepted_Attempts    : Natural := 0;
      Last_Update          : Counterweave.Reducers.Reduction_Update;
      Original_Repro       : Unbounded_String;
      Original_Trace       : Unbounded_String;
      Best_Repro           : Unbounded_String;
      Best_Trace           : Unbounded_String;
      Last_Evaluated_Repro : Unbounded_String;
      Last_Evaluated_Trace : Unbounded_String;
      Last_Candidate_Repro : Unbounded_String;
      Last_Candidate_Trace : Unbounded_String;
      Final_Trace          : Unbounded_String;
      Stop_Reason          : Counterweave.Choices.Shrink_Stop_Reason :=
        Counterweave.Choices.Fixed_Point;

      function Trace_Summary
        (Source : Unbounded_String) return Unbounded_String is
      begin
         if Length (Source) = 0 then
            return Null_Unbounded_String;
         end if;
         return Counterweave.Traces.Parse (To_String (Source)).Summary;
      end Trace_Summary;

      function Short_Hash (Value : String) return String
      is (if Value'Length <= 12
          then Value
          else Value (Value'First .. Value'First + 11));

      Model_Backend : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Retained_Case_Source,
              Counterweave.JSON.Member
                (Retained_Case_Source, Retained_Model, "backend")));
      Model_SHA256  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Retained_Case_Source,
              Counterweave.JSON.Member
                (Retained_Case_Source, Retained_Model, "model_sha256")));
      Pack_Label    : constant Unbounded_String :=
        To_Unbounded_String (Pack & "/" & Pack_Version);
      Model_Label   : constant Unbounded_String :=
        To_Unbounded_String
          (Model_Backend
           & " "
           & Solver
           & " | model "
           & Short_Hash (Model_SHA256));

      function Choice_Hash
        (Tape : Counterweave.Choices.Choice_Tape) return String
      is (Counterweave.Hashes.SHA256 (Counterweave.Choices.To_JSON (Tape)));

      function Stop_Image
        (Reason : Counterweave.Choices.Shrink_Stop_Reason) return String
      is (case Reason is
            when Counterweave.Choices.Fixed_Point   => "fixed-point",
            when Counterweave.Choices.Attempt_Limit => "attempt-limit",
            when Counterweave.Choices.Cancelled     => "cancelled");

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
        (Current   : Counterweave.Choices.Choice_Tape;
         Candidate : Counterweave.Choices.Choice_Tape;
         Strategy  : Counterweave.Choices.Shrink_Strategy;
         Location  : String;
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
            "{""strategy"":"
            & Counterweave.Strings.JSON_String
                (Counterweave.Choices.Image (Strategy))
            & ",""location"":"
            & Counterweave.Strings.JSON_String (Location)
            & ",""from_choices_sha256"":"
            & Counterweave.Strings.JSON_String (Choice_Hash (Current))
            & ",""candidate_choices_sha256"":"
            & Counterweave.Strings.JSON_String (Choice_Hash (Candidate))
            & ",""candidate_fork_count"":"
            & Counterweave.Strings.Compact_Image
                (Long_Long_Integer
                   (Counterweave.Choices.Fork_Count (Candidate)))
            & ",""candidate_value_count"":"
            & Counterweave.Strings.Compact_Image
                (Long_Long_Integer
                   (Counterweave.Choices.Value_Count (Candidate)))
            & ",""outcome"":"
            & Counterweave.Strings.JSON_String
                (case Result.Outcome is
                   when Preserved            => "preserved",
                   when Different_Result     => "different-result",
                   when Invalid_Candidate    => "invalid-candidate",
                   when Infrastructure_Error => "infrastructure-error")
            & ",""detail"":"
            & Counterweave.Strings.JSON_String (To_String (Result.Detail))
            & ",""case_replay_sha256"":"
            & Current_Case_Replay_Hash
            & ",""run_sha256"":"
            & Current_Run_Hash
            & "}");
      end Record_Attempt;

      procedure Publish
        (Current   : Counterweave.Choices.Choice_Tape;
         Candidate : Counterweave.Choices.Choice_Tape;
         Strategy  : Counterweave.Choices.Shrink_Strategy;
         Location  : String;
         Result    : Evaluation)
      is
         Update : constant Counterweave.Reducers.Reduction_Update :=
           (Attempt             => Reduction_Attempts,
            Maximum_Attempts    => Maximum_Attempts,
            Accepted            => Accepted_Attempts,
            Current_Forks       => Counterweave.Choices.Fork_Count (Current),
            Current_Values      => Counterweave.Choices.Value_Count (Current),
            Candidate_Forks     => Counterweave.Choices.Fork_Count (Candidate),
            Candidate_Values    =>
              Counterweave.Choices.Value_Count (Candidate),
            Outcome             =>
              (case Result.Outcome is
                 when Preserved            => Counterweave.Reducers.Preserved,
                 when Different_Result     =>
                   Counterweave.Reducers.Different_Result,
                 when Invalid_Candidate    =>
                   Counterweave.Reducers.Invalid_Candidate,
                 when Infrastructure_Error =>
                   Counterweave.Reducers.Infrastructure_Error),
            Strategy            =>
              To_Unbounded_String (Counterweave.Choices.Image (Strategy)),
            Location            => To_Unbounded_String (Location),
            Detail              => Result.Detail,
            Pack_Label          => Pack_Label,
            Model_Label         => Model_Label,
            Property_Name       => Failure_Property,
            Failure_Fingerprint => Failure_Fingerprint,
            Original_Repro      => Original_Repro,
            Current_Repro       => Best_Repro,
            Original_Trace_JSON => Original_Trace,
            Current_Trace_JSON  => Best_Trace,
            Retained            => False);
      begin
         Last_Candidate_Repro := Last_Evaluated_Repro;
         Last_Candidate_Trace := Last_Evaluated_Trace;
         Last_Update := Update;
         if Progress /= null then
            Progress (Update);
         end if;
      end Publish;

      function Evaluate
        (Candidate : in out Counterweave.Choices.Choice_Tape) return Evaluation
      is
         Generate_Arguments : Counterweave.Strings.String_Vector;
      begin
         Last_Evaluated_Repro := Null_Unbounded_String;
         Last_Evaluated_Trace := Null_Unbounded_String;
         if Ada.Directories.Exists (Case_Output) then
            Ada.Directories.Delete_File (Case_Output);
         end if;
         if Ada.Directories.Exists (Run_Output) then
            Ada.Directories.Delete_File (Run_Output);
         end if;
         Counterweave.Strings.Write_File_Atomically
           (Choice_Path, Counterweave.Choices.To_JSON (Candidate));

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
         Generate_Arguments.Append ("--choice-tape");
         Generate_Arguments.Append (Choice_Path);
         Generate_Arguments.Append ("--solver-timeout-ms");
         Generate_Arguments.Append
           (Counterweave.Strings.Compact_Image
              (Long_Long_Integer (Solver_Timeout)));
         for Draw of Draw_Arguments loop
            Generate_Arguments.Append ("--draw");
            Generate_Arguments.Append (Draw);
         end loop;
         Generate_Arguments.Append ("--output");
         Generate_Arguments.Append (Case_Output);
         declare
            Generated : constant Counterweave.Processes.Process_Result :=
              Counterweave.Processes.Run
                (Executable, Generate_Arguments, Solver_Timeout + 5_000);
         begin
            if Generated.Outcome /= Counterweave.Processes.Completed then
               declare
                  Detail  : constant String :=
                    To_String (Generated.Standard_Error);
                  Invalid : constant Boolean :=
                    Ada.Strings.Fixed.Index (Detail, "choice fork is missing")
                    /= 0
                    or else Ada.Strings.Fixed.Index
                              (Detail, "choice fork is exhausted")
                            /= 0
                    or else Ada.Strings.Fixed.Index
                              (Detail, "MiniZinc model is unsatisfiable")
                            /= 0;
               begin
                  return
                    (Outcome =>
                       (if Invalid
                        then Invalid_Candidate
                        else Infrastructure_Error),
                     Detail  => Generated.Standard_Error);
               end;
            end if;
         end;

         Candidate :=
           Counterweave.Artifacts.Choices_From_Case
             (Counterweave.Strings.Read_File (Case_Output));

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
            if Outcome = "pass" then
               return
                 (Outcome => Different_Result,
                  Detail  => To_Unbounded_String (Outcome));
            elsif Outcome = "invalid-case" then
               return
                 (Outcome => Invalid_Candidate,
                  Detail  => To_Unbounded_String (Outcome));
            elsif Outcome /= "property-violation" then
               return
                 (Outcome => Infrastructure_Error,
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
               if Counterweave.Adapter_Results.Has_Trace (Protocol) then
                  Last_Evaluated_Trace := Protocol.Trace_JSON;
                  Last_Evaluated_Repro := Trace_Summary (Last_Evaluated_Trace);
               end if;
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
           Error :
             Counterweave.Choices.Choice_Error
             | Counterweave.Choices.Replay_Error
         =>
            return
              (Outcome => Invalid_Candidate,
               Detail  =>
                 To_Unbounded_String
                   (Ada.Exceptions.Exception_Message (Error)));
         when
           Error :
             Counterweave.JSON.JSON_Error
             | Counterweave.Adapter_Results.Protocol_Error
             | Counterweave.Strings.Format_Error
         =>
            return
              (Outcome => Infrastructure_Error,
               Detail  =>
                 To_Unbounded_String
                   (Ada.Exceptions.Exception_Message (Error)));
      end Evaluate;

      procedure Evaluate_Candidate
        (Current      : Counterweave.Choices.Choice_Tape;
         Candidate    : in out Counterweave.Choices.Choice_Tape;
         Strategy     : Counterweave.Choices.Shrink_Strategy;
         Location     : String;
         Is_Preserved : out Boolean)
      is
         Result : constant Evaluation := Evaluate (Candidate);
      begin
         Is_Preserved := Result.Outcome = Preserved;
         Record_Attempt (Current, Candidate, Strategy, Location, Result);
         Publish (Current, Candidate, Strategy, Location, Result);
      end Evaluate_Candidate;

      procedure On_Retained is
      begin
         Accepted_Attempts := Accepted_Attempts + 1;
         Best_Repro := Last_Candidate_Repro;
         Best_Trace := Last_Candidate_Trace;
         Last_Update.Accepted := Accepted_Attempts;
         Last_Update.Current_Forks := Last_Update.Candidate_Forks;
         Last_Update.Current_Values := Last_Update.Candidate_Values;
         Last_Update.Current_Repro := Best_Repro;
         Last_Update.Current_Trace_JSON := Best_Trace;
         Last_Update.Retained := True;
         if Progress /= null then
            Progress (Last_Update);
         end if;
      end On_Retained;

      procedure On_Stop (Reason : Counterweave.Choices.Shrink_Stop_Reason) is
      begin
         Stop_Reason := Reason;
      end On_Stop;

      procedure Minimize is new
        Counterweave.Choices.Shrink (Evaluate => Evaluate_Candidate);

      function Current_Parameters return String is
         Source  : constant String :=
           Counterweave.Strings.Read_File (Case_Output);
         Root    : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (Source);
         Payload : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Member (Source, Root, "payload");
      begin
         return
           Counterweave.JSON.Canonical_Image
             (Source,
              Counterweave.JSON.Member (Source, Payload, "parameters"));
      end Current_Parameters;

      procedure Delete_Temporary_Choices is
      begin
         if Ada.Directories.Exists (Choice_Path) then
            Ada.Directories.Delete_File (Choice_Path);
         end if;
      end Delete_Temporary_Choices;
   begin
      declare
         Inputs  : Counterweave.Strings.String_Vector;
         Outputs : Counterweave.Strings.String_Vector;
      begin
         Inputs.Append (Campaign_Path);
         Inputs.Append (Counterweave.Artifacts.Executable_Path (Executable));
         Inputs.Append (Counterweave.Artifacts.Executable_Path ("minizinc"));
         Inputs.Append (Retained_Case_Path);
         Inputs.Append (Retained_Run_Path);
         Outputs.Append (Case_Output);
         Outputs.Append (Run_Output);
         Outputs.Append (Report_Output);
         Outputs.Append (Choice_Path);
         Counterweave.Strings.Validate_Output_Paths
           (Inputs, Outputs, "reduction");
      exception
         when Counterweave.Strings.Format_Error =>
            raise Reduction_Error
              with "reduction output aliases retained input";
      end;
      declare
         Ignored : constant Counterweave.Strings.String_Vector :=
           Counterweave.Campaigns.Replay_Arguments
             (Source          => Campaign_Source,
              Case_Output     => Case_Output,
              Run_Output      => Run_Output,
              Campaign_Output => Report_Output);
      begin
         pragma Unreferenced (Ignored);
      end;
      if Ada.Directories.Exists (Report_Output) then
         Ada.Directories.Delete_File (Report_Output);
      end if;
      Delete_Temporary_Choices;
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
      elsif Counterweave.Choices.Seed (Original_Tape)
        /= Interfaces.Unsigned_64'Value (To_String (Failure_Seed))
      then
         raise Reduction_Error
           with "retained choice tape seed does not match the campaign";
      end if;

      for Index in 0 .. Counterweave.JSON.Length (Campaign_Source, Draw_Nodes)
      loop
         exit when
           Index = Counterweave.JSON.Length (Campaign_Source, Draw_Nodes);
         Draw_Arguments.Append
           (To_String
              (Counterweave.JSON.As_String
                 (Campaign_Source,
                  Counterweave.JSON.Element
                    (Campaign_Source, Draw_Nodes, Index))));
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
         Baseline_Tape : Counterweave.Choices.Choice_Tape := Original_Tape;
         Baseline      : constant Evaluation := Evaluate (Baseline_Tape);
      begin
         if Baseline.Outcome /= Preserved then
            if Stop /= null and then Stop.all then
               raise Reduction_Error with "reduction cancelled";
            else
               raise Reduction_Error
                 with "retained failure does not reproduce before reduction";
            end if;
         end if;
         Original_Repro := Last_Evaluated_Repro;
         Original_Trace := Last_Evaluated_Trace;
         Best_Repro := Original_Repro;
         Best_Trace := Original_Trace;
         Last_Update.Maximum_Attempts := Maximum_Attempts;
         Last_Update.Current_Forks :=
           Counterweave.Choices.Fork_Count (Original_Tape);
         Last_Update.Current_Values :=
           Counterweave.Choices.Value_Count (Original_Tape);
         Last_Update.Candidate_Forks := Last_Update.Current_Forks;
         Last_Update.Candidate_Values := Last_Update.Current_Values;
         Last_Update.Outcome := Counterweave.Reducers.Preserved;
         Last_Update.Pack_Label := Pack_Label;
         Last_Update.Model_Label := Model_Label;
         Last_Update.Property_Name := Failure_Property;
         Last_Update.Failure_Fingerprint := Failure_Fingerprint;
         Last_Update.Original_Repro := Original_Repro;
         Last_Update.Current_Repro := Best_Repro;
         Last_Update.Original_Trace_JSON := Original_Trace;
         Last_Update.Current_Trace_JSON := Best_Trace;
         if Progress /= null then
            Progress (Last_Update);
         end if;
      end;

      Minimize
        (Original_Tape,
         Reduced_Tape,
         Maximum_Attempts => Maximum_Attempts,
         Should_Stop      => Stop,
         Stopped          => On_Stop'Access,
         Retained         => On_Retained'Access);

      if Stop_Reason = Counterweave.Choices.Cancelled then
         raise Reduction_Error with "reduction cancelled";
      end if;

      declare
         Final_Result : constant Evaluation := Evaluate (Reduced_Tape);
      begin
         if Final_Result.Outcome /= Preserved then
            if Stop /= null and then Stop.all then
               raise Reduction_Error with "reduction cancelled";
            else
               raise Reduction_Error
                 with "final reduced tape lost the failure fingerprint";
            end if;
         end if;
         Final_Trace := Last_Evaluated_Trace;
      end;
      Append (Attempts_JSON, "]");
      Counterweave.Strings.Write_File_Atomically
        (Report_Output,
         "{"
         & ASCII.LF
         & "  ""format"": ""counterweave.reduction/3"","
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
         & Counterweave.JSON.Canonical_Image
             (Retained_Case_Source, Original_Parameters)
         & ","
         & ASCII.LF
         & "  ""original_trace"": "
         & (if Length (Original_Trace) = 0
            then "null"
            else To_String (Original_Trace))
         & ","
         & ASCII.LF
         & "  ""original_case_replay_sha256"": "
         & Counterweave.Strings.JSON_String (To_String (Failure_Case_Hash))
         & ","
         & ASCII.LF
         & "  ""original_choices_sha256"": "
         & Counterweave.Strings.JSON_String (Choice_Hash (Original_Tape))
         & ","
         & ASCII.LF
         & "  ""original_choices"": "
         & Counterweave.Choices.To_JSON (Original_Tape)
         & ","
         & ASCII.LF
         & "  ""attempt_count"": "
         & Counterweave.Strings.Compact_Image
             (Long_Long_Integer (Reduction_Attempts))
         & ","
         & ASCII.LF
         & "  ""maximum_attempts"": "
         & Counterweave.Strings.Compact_Image
             (Long_Long_Integer (Maximum_Attempts))
         & ","
         & ASCII.LF
         & "  ""accepted_attempt_count"": "
         & Counterweave.Strings.Compact_Image
             (Long_Long_Integer (Accepted_Attempts))
         & ","
         & ASCII.LF
         & "  ""stop_reason"": "
         & Counterweave.Strings.JSON_String (Stop_Image (Stop_Reason))
         & ","
         & ASCII.LF
         & "  ""attempts"": "
         & To_String (Attempts_JSON)
         & ","
         & ASCII.LF
         & "  ""final_parameters"": "
         & Current_Parameters
         & ","
         & ASCII.LF
         & "  ""final_trace"": "
         & (if Length (Final_Trace) = 0
            then "null"
            else To_String (Final_Trace))
         & ","
         & ASCII.LF
         & "  ""final_choices_sha256"": "
         & Counterweave.Strings.JSON_String (Choice_Hash (Reduced_Tape))
         & ","
         & ASCII.LF
         & "  ""final_choices"": "
         & Counterweave.Choices.To_JSON (Reduced_Tape)
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
      Delete_Temporary_Choices;
   exception
      when
        Counterweave.Campaigns.Campaign_Error
        | Counterweave.JSON.JSON_Error
        | Counterweave.Strings.Format_Error
        | Counterweave.Choices.Choice_Error
      =>
         Delete_Temporary_Choices;
         raise Reduction_Error with "campaign reduction input is malformed";
      when others =>
         Delete_Temporary_Choices;
         raise;
   end Reduce;

end Counterweave.Reduction_Engine;
