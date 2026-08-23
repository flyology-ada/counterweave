with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Counterweave.Artifacts;
with Counterweave.Choices;
with Counterweave.Hashes;
with Counterweave.Processes;
with Counterweave.Strings;

procedure Counterweave_Tests is

   use type Counterweave.Choices.Choice_Value;
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
        "{""format"": ""counterweave.case/1"", ""number"": -12, "
        & """flag"": true, ""nested"": {""x"": 3}}";
   begin
      Check
        (Counterweave.Strings.Find_Integer (Source, "number") = -12,
         "extract JSON integer");
      Check
        (Counterweave.Strings.Find_Boolean (Source, "flag"),
         "extract JSON Boolean");
      Check
        (Counterweave.Strings.Find_String (Source, "format")
         = "counterweave.case/1",
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
   end Test_JSON;

   procedure Test_Artifacts is
      Path : constant Counterweave.Choices.Fork_Path :=
        Counterweave.Choices.Child (Counterweave.Choices.Root, "artifact", 0);
      Tape : Counterweave.Choices.Choice_Tape;
      Drawn : Counterweave.Choices.Choice_Value;
   begin
      Counterweave.Choices.Start_Recording (Tape, 17);
      Drawn := Counterweave.Choices.Draw (Tape, Path);
      declare
         Source : constant String :=
           "{""format"":""counterweave.case/1"","
           & """pack"":{""name"":""test"",""version"":""1""},"
           & """intent"":{""kind"":""satisfy"",""target"":""unit""},"
           & """provenance"":{""counterweave_version"":""test"","
           & """choices"":"
           & Counterweave.Choices.To_JSON (Tape)
           & ",""model"":{""backend"":""minizinc"",""solver"":""test"","
           & """minizinc_version"":""test"",""model_sha256"":""test"","
           & """compiled_sha256"":""test""}"
           & "},"
           & """payload"":{""parameters"":{},""solution"":{}}}";
         Loaded : Counterweave.Choices.Choice_Tape;
      begin
         Counterweave.Artifacts.Validate_Case (Source);
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
      end;
   end Test_Artifacts;

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
      Check
        (Length = 64,
         "hash large executable on a bounded worker stack");
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
            entry Result
              (Outcome : out Counterweave.Processes.Outcome_Kind);
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
   Test_Artifacts;
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
