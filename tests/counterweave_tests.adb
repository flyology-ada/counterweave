with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Counterweave.Adapter_Results;
with Counterweave.Artifacts;
with Counterweave.Campaigns;
with Counterweave.Choices;
with Counterweave.Hashes;
with Counterweave.JSON;
with Counterweave.Processes;
with Counterweave.Strings;
with GNAT.OS_Lib;

procedure Counterweave_Tests is

   use type Counterweave.Choices.Choice_Value;
   use type Counterweave.Adapter_Results.Verdict_Kind;
   use type Counterweave.Processes.Outcome_Kind;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if Condition then
         Ada.Text_IO.Put_Line ("PASS " & Name);
      else
         Ada.Text_IO.Put_Line ("FAIL " & Name);
         Failures := Failures + 1;
      end if;
   end Check;

   procedure Test_Choices is
      Path_One : constant Counterweave.Choices.Fork_Path :=
        Counterweave.Choices.Child
          (Counterweave.Choices.Child (Counterweave.Choices.Root, "case", 7),
           "actor",
           1);
      Path_Two : constant Counterweave.Choices.Fork_Path :=
        Counterweave.Choices.Child
          (Counterweave.Choices.Child (Counterweave.Choices.Root, "case", 7),
           "actor",
           2);
      First    : Counterweave.Choices.Choice_Tape;
      Second   : Counterweave.Choices.Choice_Tape;
      Ignored  : Counterweave.Choices.Choice_Value;
      Expected : Counterweave.Choices.Choice_Value;
      Actual   : Counterweave.Choices.Choice_Value;
   begin
      Counterweave.Choices.Start_Recording (First, 99);
      Ignored := Counterweave.Choices.Draw (First, Path_One);
      Expected := Counterweave.Choices.Draw (First, Path_Two);

      Counterweave.Choices.Start_Recording (Second, 99);
      Actual := Counterweave.Choices.Draw (Second, Path_Two);
      Check (Expected = Actual, "sibling fork consumption is independent");

      declare
         Session : Counterweave.Choices.Replay_Session :=
           Counterweave.Choices.Replay (First);
      begin
         Check
           (Counterweave.Choices.Draw (Session, Path_One) = Ignored,
            "replay returns recorded value");
         Check
           (Counterweave.Choices.Draw (Session, Path_Two) = Expected,
            "replay returns sibling value");
         Counterweave.Choices.Finish (Session);
      end;

      declare
         Loaded  : constant Counterweave.Choices.Choice_Tape :=
           Counterweave.Choices.From_JSON
             (Counterweave.Choices.To_JSON (First));
         Session : Counterweave.Choices.Replay_Session :=
           Counterweave.Choices.Replay (Loaded);
      begin
         Check
           (Counterweave.Choices.Draw (Session, Path_One) = Ignored,
            "artifact tape replays recorded value");
         Check
           (Counterweave.Choices.Draw (Session, Path_Two) = Expected,
            "artifact tape preserves independent forks");
         Counterweave.Choices.Finish (Session);
      end;

      declare
         Session : Counterweave.Choices.Replay_Session :=
           Counterweave.Choices.Replay (First);
         Raised  : Boolean := False;
      begin
         Ignored := Counterweave.Choices.Draw (Session, Path_One);
         begin
            Counterweave.Choices.Finish (Session);
         exception
            when Counterweave.Choices.Replay_Error =>
               Raised := True;
         end;
         Check (Raised, "replay rejects unused choices");
      end;

      declare
         Session : Counterweave.Choices.Replay_Session :=
           Counterweave.Choices.Replay (First);
         Missing : constant Counterweave.Choices.Fork_Path :=
           Counterweave.Choices.Child
             (Counterweave.Choices.Root, "missing", 0);
         Raised  : Boolean := False;
      begin
         begin
            Ignored := Counterweave.Choices.Draw (Session, Missing);
         exception
            when Counterweave.Choices.Replay_Error =>
               Raised := True;
         end;
         Check (Raised, "replay rejects missing forks");
      end;

      declare
         Session : Counterweave.Choices.Replay_Session :=
           Counterweave.Choices.Replay (First);
         Raised  : Boolean := False;
      begin
         Ignored := Counterweave.Choices.Draw (Session, Path_One);
         begin
            Ignored := Counterweave.Choices.Draw (Session, Path_One);
         exception
            when Counterweave.Choices.Replay_Error =>
               Raised := True;
         end;
         Check (Raised, "replay rejects exhausted forks");
      end;

      declare
         Multi_Segment  : constant Counterweave.Choices.Fork_Path :=
           Counterweave.Choices.Child
             (Counterweave.Choices.Child
                (Counterweave.Choices.Root, "a", 16#4141_4141_4141_4141#),
              "b",
              2);
         Single_Segment : constant Counterweave.Choices.Fork_Path :=
           Counterweave.Choices.Child
             (Counterweave.Choices.Root, "aAAAAAAAAb", 2);
         Left           : Counterweave.Choices.Choice_Tape;
         Right          : Counterweave.Choices.Choice_Tape;
      begin
         Counterweave.Choices.Start_Recording (Left, 7);
         Counterweave.Choices.Start_Recording (Right, 7);
         Check
           (Counterweave.Choices.Draw (Left, Multi_Segment)
            /= Counterweave.Choices.Draw (Right, Single_Segment),
            "fork derivation distinguishes path structure");
      end;
   end Test_Choices;

   procedure Test_JSON is
      Source : constant String :=
        "{""format"": ""example/1"", ""number"": -12, "
        & """flag"": true, ""nested"": {""x"": 3}}";
   begin
      Check
        (Counterweave.Strings.Find_Integer (Source, "number") = -12,
         "extract JSON integer");
      Check
        (Counterweave.Strings.Find_Boolean (Source, "flag"),
         "extract JSON Boolean");
      Check
        (Counterweave.Strings.Find_String (Source, "format") = "example/1",
         "extract JSON string");
      Check
        (Counterweave.Strings.Extract_First_JSON
           ("note " & Source & " trailing")
         = Source,
         "extract balanced JSON value");
      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant String :=
                 Counterweave.Strings.Extract_Only_JSON (Source & " trailing");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "reject data outside adapter JSON value");
      end;

      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant String :=
                 Counterweave.Strings.Extract_Only_JSON ("{]");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "reject mismatched JSON containers");
      end;

      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Long_Long_Integer :=
                 Counterweave.Strings.Find_Integer
                   ("{""nested"":{""number"":7}}", "number");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "JSON field lookup remains at the requested object");
      end;

      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant String :=
                 Counterweave.Strings.Extract_Only_JSON
                   ("{""field"":1,""field"":2}");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "reject duplicate JSON object members");
      end;

      declare
         Exponent     : constant String := "100000000000000000000000";
         Left_Source  : constant String :=
           "{""b"":1.00e+" & Exponent & "2," & """a"":""\u0061"",""c"":-0.0}";
         Right_Source : constant String :=
           " { ""c"" : 0, ""a"" : ""a"", "
           & """b"" : 100e"
           & Exponent
           & "0 } ";
         Left         : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (Left_Source);
         Right        : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (Right_Source);
         Left_Image   : constant String :=
           Counterweave.JSON.Canonical_Image (Left_Source, Left);
         Right_Image  : constant String :=
           Counterweave.JSON.Canonical_Image (Right_Source, Right);
      begin
         Check
           (Left_Image = Right_Image,
            "canonicalize JSON order, strings, numbers, and whitespace");
      end;
   end Test_JSON;

   procedure Test_Paths is
      Current : constant String := Ada.Directories.Current_Directory;
   begin
      Check
        (Counterweave.Strings.Same_Path
           (Current & "/counterweave-path-test",
            Current & "/./counterweave-path-test"),
         "canonicalize equivalent artifact paths");
      Check
        (not Counterweave.Strings.Same_Path
               (Current & "/counterweave-path-test-a",
                Current & "/counterweave-path-test-b"),
         "distinguish different artifact paths");
      declare
         Inputs  : Counterweave.Strings.String_Vector;
         Outputs : Counterweave.Strings.String_Vector;
         Raised  : Boolean := False;
      begin
         Inputs.Append (Current & "/counterweave-path-test");
         Outputs.Append (Current & "/./counterweave-path-test");
         begin
            Counterweave.Strings.Validate_Output_Paths
              (Inputs, Outputs, "test");
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "reject an output that aliases an input");
      end;
      declare
         Inputs  : Counterweave.Strings.String_Vector;
         Outputs : Counterweave.Strings.String_Vector;
         Raised  : Boolean := False;
      begin
         Outputs.Append (Current & "/counterweave-path-test");
         Outputs.Append (Current & "/./counterweave-path-test");
         begin
            Counterweave.Strings.Validate_Output_Paths
              (Inputs, Outputs, "test");
         exception
            when Counterweave.Strings.Format_Error =>
               Raised := True;
         end;
         Check (Raised, "reject aliased sibling outputs");
      end;
   end Test_Paths;

   procedure Test_CLI_Path_Safety is
      PID       : constant String :=
        Counterweave.Strings.Compact_Image
          (Long_Long_Integer
             (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)));
      Path      : constant String :=
        "/tmp/counterweave-cli-path-test-" & PID & ".json";
      Run_Path  : constant String := Path & ".run";
      Log_Path  : constant String := Path & ".campaign";
      Program   : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Containing_Directory
             (Ada.Command_Line.Command_Name),
           "counterweave");
      Arguments : Counterweave.Strings.String_Vector;
   begin
      Counterweave.Strings.Write_File_Atomically (Path, "retained input");
      declare
         Before : constant String := Counterweave.Strings.Read_File (Path);
      begin
         Arguments.Append ("execute");
         Arguments.Append ("--case");
         Arguments.Append (Path);
         Arguments.Append ("--adapter");
         Arguments.Append ("/usr/bin/false");
         Arguments.Append ("--output");
         Arguments.Append (Path);
         declare
            Result : constant Counterweave.Processes.Process_Result :=
              Counterweave.Processes.Run (Program, Arguments, 1_000);
         begin
            Check
              (Result.Outcome = Counterweave.Processes.Failed,
               "CLI rejects an output that aliases its case input");
            Check
              (Counterweave.Strings.Read_File (Path) = Before,
               "CLI path rejection preserves its input bytes");
            Check
              (Ada.Strings.Fixed.Index
                 (Ada.Strings.Unbounded.To_String (Result.Standard_Error),
                  "output aliases an input")
               /= 0,
               "CLI reports the path collision before decoding the case");
         end;

         Arguments.Clear;
         Arguments.Append ("search");
         Arguments.Append ("--model");
         Arguments.Append (Path);
         Arguments.Append ("--adapter");
         Arguments.Append ("/usr/bin/false");
         Arguments.Append ("--pack");
         Arguments.Append ("test");
         Arguments.Append ("--case-output");
         Arguments.Append (Path);
         Arguments.Append ("--run-output");
         Arguments.Append (Run_Path);
         Arguments.Append ("--campaign-output");
         Arguments.Append (Log_Path);
         declare
            Result : constant Counterweave.Processes.Process_Result :=
              Counterweave.Processes.Run (Program, Arguments, 1_000);
         begin
            Check
              (Result.Outcome = Counterweave.Processes.Failed,
               "search rejects an output that aliases its model input");
            Check
              (Counterweave.Strings.Read_File (Path) = Before,
               "search path rejection preserves its model bytes");
            Check
              (not Ada.Directories.Exists (Run_Path)
               and then not Ada.Directories.Exists (Log_Path),
               "search rejects collisions before creating evidence");
         end;
      end;
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         if Ada.Directories.Exists (Run_Path) then
            Ada.Directories.Delete_File (Run_Path);
         end if;
         if Ada.Directories.Exists (Log_Path) then
            Ada.Directories.Delete_File (Log_Path);
         end if;
         raise;
   end Test_CLI_Path_Safety;

   procedure Test_Adapter_Results is
      Violation_JSON : constant String :=
        "{""format"":""counterweave.adapter-result/1"","
        & """pack"":{""name"":""ledger"",""version"":""1""},"
        & """verdict"":""property-violation"","
        & """property"":""transfers-are-idempotent"","
        & """fingerprint"":""duplicate-credit"","
        & """observations"":{""credited_twice"":true}}";
      Parsed         : constant Counterweave.Adapter_Results.Adapter_Result :=
        Counterweave.Adapter_Results.Parse (Violation_JSON, "ledger", "1");
   begin
      Check
        (Parsed.Verdict = Counterweave.Adapter_Results.Property_Violation,
         "parse semantic adapter verdict independently of process exit");
      Check
        (Ada.Strings.Unbounded.To_String (Parsed.Failure_Fingerprint)
         = "duplicate-credit",
         "preserve stable failure fingerprint");
      declare
         Round_Trip : constant Counterweave.Adapter_Results.Adapter_Result :=
           Counterweave.Adapter_Results.Parse
             (Counterweave.Adapter_Results.To_JSON (Parsed), "ledger", "1");
      begin
         Check
           (Round_Trip.Verdict
            = Counterweave.Adapter_Results.Property_Violation,
            "round-trip canonical adapter result");
      end;

      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored :
                 constant Counterweave.Adapter_Results.Adapter_Result :=
                   Counterweave.Adapter_Results.Parse
                     (Violation_JSON, "another-pack", "1");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Adapter_Results.Protocol_Error =>
               Raised := True;
         end;
         Check (Raised, "reject adapter result for a different model pack");
      end;

      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored :
                 constant Counterweave.Adapter_Results.Adapter_Result :=
                   Counterweave.Adapter_Results.Parse
                     ("{""format"":""counterweave.adapter-result/1"","
                      & """pack"":{""name"":""ledger"",""version"":""1""},"
                      & """verdict"":""property-violation"","
                      & """property"":""transfers-are-idempotent"","
                      & """fingerprint"":null,""observations"":{}}",
                      "ledger",
                      "1");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Counterweave.Adapter_Results.Protocol_Error =>
               Raised := True;
         end;
         Check (Raised, "reject property violation without a fingerprint");
      end;
   end Test_Adapter_Results;

   procedure Test_Artifacts is
      Path  : constant Counterweave.Choices.Fork_Path :=
        Counterweave.Choices.Child (Counterweave.Choices.Root, "artifact", 0);
      Tape  : Counterweave.Choices.Choice_Tape;
      Drawn : Counterweave.Choices.Choice_Value;
   begin
      Counterweave.Choices.Start_Recording (Tape, 17);
      Drawn := Counterweave.Choices.Draw (Tape, Path);
      declare
         Source     : constant String :=
           "{""format"":""counterweave.case/2"","
           & """pack"":{""name"":""test"",""version"":""1""},"
           & """intent"":{""kind"":""satisfy"",""target"":""unit""},"
           & """provenance"":{""counterweave_version"":""test"","
           & """choices"":"
           & Counterweave.Choices.To_JSON (Tape)
           & ",""model"":{""backend"":""minizinc"",""solver"":""test"","
           & """minizinc_version"":""test"",""model_sha256"":""test"","
           & """compiled_sha256"":""test"","
           & """diversity_seed"":""17""}"
           & "},"
           & """payload"":{""parameters"":{""b"":1.00,""a"":""\u0061""},"
           & """solution"":{""nested"":{""z"":100,""y"":-0.0}}}}";
         Equivalent : constant String :=
           " { ""payload"" : {"
           & """solution"":{""nested"":{""y"":0,""z"":1e2}},"
           & """parameters"":{""a"":""a"",""b"":1e0}},"
           & """provenance"":{""model"":{""diversity_seed"":""17"","
           & """compiled_sha256"":""different-diagnostic-hash"","
           & """model_sha256"":""test"",""minizinc_version"":""test"","
           & """solver"":""test"",""backend"":""minizinc""},"
           & """choices"":"
           & Counterweave.Choices.To_JSON (Tape)
           & ",""counterweave_version"":""another-diagnostic-version""},"
           & """intent"":{""target"":""unit"",""kind"":""satisfy""},"
           & """pack"":{""version"":""1"",""name"":""test""},"
           & """format"":""counterweave.case/2"" } ";
         Loaded     : Counterweave.Choices.Choice_Tape;
      begin
         Counterweave.Artifacts.Validate_Case (Source);
         Counterweave.Artifacts.Validate_Case (Equivalent);
         Loaded := Counterweave.Artifacts.Choices_From_Case (Source);
         declare
            Session : Counterweave.Choices.Replay_Session :=
              Counterweave.Choices.Replay (Loaded);
         begin
            Check
              (Counterweave.Choices.Draw (Session, Path) = Drawn,
               "validated case restores its choice tape");
            Counterweave.Choices.Finish (Session);
         end;
         Check
           (Counterweave.Artifacts.Case_Replay_SHA256 (Source)
            = Counterweave.Artifacts.Case_Replay_SHA256 (Equivalent),
            "semantic case hash ignores JSON and diagnostic spelling");
         declare
            Different : String := Equivalent;
            Position  : constant Natural :=
              Ada.Strings.Fixed.Index (Different, "1e2");
         begin
            Check (Position /= 0, "semantic hash fixture contains its value");
            if Position /= 0 then
               Different (Position + 2) := '3';
               Check
                 (Counterweave.Artifacts.Case_Replay_SHA256 (Source)
                  /= Counterweave.Artifacts.Case_Replay_SHA256 (Different),
                  "semantic case hash retains distinct payload values");
            end if;
         end;
      end;
   end Test_Artifacts;

   procedure Test_Run_Classification is
      Path           : constant String :=
        "/tmp/counterweave-run-test-"
        & Counterweave.Strings.Compact_Image
            (Long_Long_Integer
               (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)))
        & ".json";
      Arguments      : Counterweave.Strings.String_Vector;
      Process        : constant Counterweave.Processes.Process_Result :=
        (Outcome              => Counterweave.Processes.Failed,
         Standard_Output      =>
           Ada.Strings.Unbounded.To_Unbounded_String
             ("{""verdict"":""property-violation""}"),
         Standard_Error       =>
           Ada.Strings.Unbounded.To_Unbounded_String ("adapter crashed"),
         Elapsed_Milliseconds => 1);
      Adapter_Result : Counterweave.Adapter_Results.Adapter_Result;
   begin
      Counterweave.Artifacts.Write_Run
        (Path               => Path,
         Case_Path          => Ada.Command_Line.Command_Name,
         Adapter            => "failing-adapter",
         Adapter_SHA256     => "",
         Arguments          => Arguments,
         Process            => Process,
         Has_Adapter_Result => False,
         Adapter_Result     => Adapter_Result);
      declare
         Source : constant String := Counterweave.Strings.Read_File (Path);
      begin
         Check
           (Counterweave.Strings.Find_String (Source, "outcome")
            = "adapter-error",
            "adapter process failure is not a property violation");
      end;
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_Run_Classification;

   procedure Test_Campaign_Replay is
      Original : constant String :=
        "{""format"":""counterweave.campaign/2"","
        & """root_seed"":""42"",""maximum_trials"":2,"
        & """status"":""property-violation"",""attempts"":["
        & "{""index"":1,""seed"":""7"",""outcome"":""pass"","
        & """property"":""transfers-are-idempotent"","
        & """failure_fingerprint"":null,""case_replay_sha256"":""a""},"
        & "{""index"":2,""seed"":""8"","
        & """outcome"":""property-violation"","
        & """property"":""transfers-are-idempotent"","
        & """failure_fingerprint"":""duplicate-credit"","
        & """case_replay_sha256"":""b""}]}";
   begin
      Counterweave.Campaigns.Verify_Replay (Original, Original);
      Check (True, "verify equivalent campaign replay");
      declare
         Changed : String := Original;
         Raised  : Boolean := False;
      begin
         for Index in reverse Changed'Range loop
            if Changed (Index) = 'b' then
               Changed (Index) := 'c';
               exit;
            end if;
         end loop;
         begin
            Counterweave.Campaigns.Verify_Replay (Original, Changed);
         exception
            when Counterweave.Campaigns.Campaign_Error =>
               Raised := True;
         end;
         Check (Raised, "reject replay with a different semantic case");
      end;
      declare
         Changed : String := Original;
         First   : constant Positive :=
           Ada.Strings.Fixed.Index (Changed, "transfers-are-idempotent");
         Raised  : Boolean := False;
      begin
         Changed (First) := 'x';
         begin
            Counterweave.Campaigns.Verify_Replay (Original, Changed);
         exception
            when Counterweave.Campaigns.Campaign_Error =>
               Raised := True;
         end;
         Check (Raised, "reject replay with a different property identity");
      end;
   end Test_Campaign_Replay;

   procedure Test_Streaming_Hash is
      task type Hash_Worker with Storage_Size => 256 * 1_024 is
         entry Result (Length : out Natural);
      end Hash_Worker;

      task body Hash_Worker is
         Digest : constant String :=
           Counterweave.Hashes.SHA256_File (Ada.Command_Line.Command_Name);
      begin
         accept Result (Length : out Natural) do
            Length := Digest'Length;
         end Result;
      end Hash_Worker;

      Worker : Hash_Worker;
      Length : Natural;
   begin
      Worker.Result (Length);
      Check (Length = 64, "hash large executable on a bounded worker stack");
   end Test_Streaming_Hash;

   procedure Test_Processes is
      Arguments : Counterweave.Strings.String_Vector;
   begin
      Arguments.Append ("-c");
      Arguments.Append ("printf '{""ok"":true}'");
      declare
         Result : constant Counterweave.Processes.Process_Result :=
           Counterweave.Processes.Run ("/bin/sh", Arguments, 1_000);
      begin
         Check
           (Result.Outcome = Counterweave.Processes.Completed,
            "capture successful subprocess");
      end;

      Arguments.Clear;
      Arguments.Append ("-c");
      Arguments.Append ("sleep 1");
      declare
         Result : constant Counterweave.Processes.Process_Result :=
           Counterweave.Processes.Run ("/bin/sh", Arguments, 20);
      begin
         Check
           (Result.Outcome = Counterweave.Processes.Timed_Out,
            "bound subprocess deadline");
      end;

      Arguments.Clear;
      Arguments.Append ("-c");
      Arguments.Append
        ("while :; do printf '012345678901234567890123456789'; done");
      declare
         Result : constant Counterweave.Processes.Process_Result :=
           Counterweave.Processes.Run
             ("/bin/sh", Arguments, 1_000, Maximum_Output_Bytes => 1_024);
      begin
         Check
           (Result.Outcome = Counterweave.Processes.Output_Limit,
            "bound subprocess output");
      end;

      Arguments.Clear;
      Arguments.Append ("-c");
      Arguments.Append
        ("i=0; while [ $i -lt 100 ]; do printf '01234567890123456789'; "
         & "i=$((i+1)); done");
      declare
         Result : constant Counterweave.Processes.Process_Result :=
           Counterweave.Processes.Run
             ("/bin/sh", Arguments, 1_000, Maximum_Output_Bytes => 1_024);
      begin
         Check
           (Result.Outcome = Counterweave.Processes.Output_Limit,
            "classify fast subprocess output overflow");
      end;

      Arguments.Clear;
      Arguments.Append ("-c");
      Arguments.Append ("sleep 5");
      declare
         task Runner is
            entry Result (Outcome : out Counterweave.Processes.Outcome_Kind);
         end Runner;

         task body Runner is
            Process : Counterweave.Processes.Process_Result;
         begin
            Process :=
              Counterweave.Processes.Run ("/bin/sh", Arguments, 2_000);
            accept Result
              (Outcome : out Counterweave.Processes.Outcome_Kind)
            do
               Outcome := Process.Outcome;
            end Result;
         end Runner;

         Outcome : Counterweave.Processes.Outcome_Kind;
      begin
         delay 0.05;
         Counterweave.Processes.Request_Cancel;
         Runner.Result (Outcome);
         Check
           (Outcome = Counterweave.Processes.Cancelled,
            "cancel active subprocess ("
            & Counterweave.Processes.Outcome_Kind'Image (Outcome)
            & ")");
      end;
   end Test_Processes;

begin
   Test_Choices;
   Test_JSON;
   Test_Paths;
   Test_CLI_Path_Safety;
   Test_Adapter_Results;
   Test_Artifacts;
   Test_Run_Classification;
   Test_Campaign_Replay;
   Test_Streaming_Hash;
   Test_Processes;
   if Failures /= 0 then
      Ada.Text_IO.Put_Line (Natural'Image (Failures) & " test(s) failed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "counterweave_tests: "
         & Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Counterweave_Tests;
