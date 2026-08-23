with Ada.Calendar;
with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Counterweave.Artifacts;
with Counterweave.Campaign_UI;
with Counterweave.Choices;
with Counterweave.Hashes;
with Counterweave.MiniZinc;
with Counterweave.Processes;
with Counterweave.Strings;
with Counterweave.Terminal_UI;
with Counterweave.Terminal_Reports;
with GNAT.OS_Lib;
with Interfaces;

procedure Counterweave_Main is

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;
   use type Counterweave.Processes.Outcome_Kind;
   use type Interfaces.Unsigned_64;

   Interactive_Status : Boolean := False;
   Deferred_Status    : Unbounded_String;

   procedure Status_Line (Value : String) is
   begin
      if Interactive_Status then
         Append (Deferred_Status, Value & ASCII.LF);
      else
         Ada.Text_IO.Put_Line (Value);
      end if;
   end Status_Line;

   procedure Flush_Status is
   begin
      if Length (Deferred_Status) > 0 then
         Ada.Text_IO.Put (To_String (Deferred_Status));
         Deferred_Status := Null_Unbounded_String;
      end if;
   end Flush_Status;

   type Draw_Spec is record
      Name    : Unbounded_String;
      Minimum : Long_Long_Integer;
      Maximum : Long_Long_Integer;
   end record;

   package Draw_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Draw_Spec);

   function Value_After
     (Position : in out Positive; Option : String) return String is
   begin
      if Position = Ada.Command_Line.Argument_Count then
         raise Constraint_Error with "missing value after " & Option;
      end if;
      Position := Position + 1;
      return Ada.Command_Line.Argument (Position);
   end Value_After;

   function Parse_Draw (Value : String) return Draw_Spec is
      Equals : constant Natural := Ada.Strings.Fixed.Index (Value, "=");
      Dots   : constant Natural :=
        Ada.Strings.Fixed.Index (Value, "..", From => Equals + 1);
   begin
      if Equals <= Value'First or else Dots = 0 or else Dots + 1 >= Value'Last
      then
         raise Constraint_Error with "expected NAME=MIN..MAX";
      end if;
      declare
         Result : constant Draw_Spec :=
           (Name    => To_Unbounded_String (Value (Value'First .. Equals - 1)),
            Minimum =>
              Long_Long_Integer'Value (Value (Equals + 1 .. Dots - 1)),
            Maximum =>
              Long_Long_Integer'Value (Value (Dots + 2 .. Value'Last)));
      begin
         if Result.Minimum > Result.Maximum then
            raise Constraint_Error with "draw minimum exceeds maximum";
         end if;
         return Result;
      end;
   end Parse_Draw;

   function Entropy_Seed return Interfaces.Unsigned_64 is
      Epoch : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (2000, 1, 1);
      Span  : constant Duration := Ada.Calendar.Clock - Epoch;
      Pid   : constant Integer :=
        GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id);
   begin
      return
        Interfaces.Unsigned_64 (Long_Long_Integer (Span * 1_000_000.0))
        xor Interfaces.Unsigned_64 (Pid);
   end Entropy_Seed;

   function Range_Width
     (Minimum : Long_Long_Integer; Maximum : Long_Long_Integer)
      return Interfaces.Unsigned_64 is
   begin
      if Minimum >= 0 or else Maximum < 0 then
         return Interfaces.Unsigned_64 (Maximum - Minimum);
      end if;
      return
        Interfaces.Unsigned_64 (-(Minimum + 1))
        + 1
        + Interfaces.Unsigned_64 (Maximum);
   end Range_Width;

   function Add_Offset
     (Minimum : Long_Long_Integer; Offset : Interfaces.Unsigned_64)
      return Long_Long_Integer is
   begin
      if Minimum >= 0 then
         return Minimum + Long_Long_Integer (Offset);
      end if;
      declare
         Zero_Offset : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (-(Minimum + 1)) + 1;
      begin
         if Offset < Zero_Offset then
            return Minimum + Long_Long_Integer (Offset);
         end if;
         return Long_Long_Integer (Offset - Zero_Offset);
      end;
   end Add_Offset;

   function Temporary_Data_Path return String is
      PID       : constant String :=
        Ada.Strings.Fixed.Trim
          (Integer'Image
             (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)),
           Ada.Strings.Both);
      Directory : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
   begin
      return
        Ada.Directories.Compose
          (Directory, "counterweave-data-" & PID & ".dzn");
   end Temporary_Data_Path;

   procedure Usage is
   begin
      Ada.Text_IO.Put_Line
        ("counterweave generate --model MODEL --draw NAME=MIN..MAX ... "
         & "--pack PACK --output CASE");
      Ada.Text_IO.Put_Line
        ("counterweave execute --case CASE --adapter PROGRAM "
         & "--output RUN [--adapter-arg ARG]");
      Ada.Text_IO.Put_Line
        ("counterweave search --model MODEL --adapter PROGRAM --draw ... "
         & "--case-output CASE --run-output RUN");
      Ada.Text_IO.Put_Line ("counterweave inspect CASE");
   end Usage;

   procedure Generate is
      Model_Path     : Unbounded_String;
      Base_Data_Path : Unbounded_String;
      Solver         : Unbounded_String := To_Unbounded_String ("cp-sat");
      Pack           : Unbounded_String;
      Pack_Version   : Unbounded_String := To_Unbounded_String ("1");
      Intent         : Unbounded_String := To_Unbounded_String ("satisfy");
      Target         : Unbounded_String := To_Unbounded_String ("default");
      Output_Path    : Unbounded_String;
      Seed_Value     : Interfaces.Unsigned_64 := 0;
      Seed_Was_Set   : Boolean := False;
      Solver_Timeout : Positive := 30_000;
      Draws          : Draw_Vectors.Vector;
      Position       : Positive := 2;
   begin
      while Position <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Position);
         begin
            if Argument = "--model" then
               Model_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--data" then
               Base_Data_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--solver" then
               Solver :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--pack" then
               Pack := To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--pack-version" then
               Pack_Version :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--intent" then
               Intent :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--target" then
               Target :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--output" then
               Output_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--seed" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Seed_Value := Interfaces.Unsigned_64'Value (Text);
                  Seed_Was_Set := True;
               end;
            elsif Argument = "--solver-timeout-ms" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Solver_Timeout := Positive'Value (Text);
               end;
            elsif Argument = "--draw" then
               declare
                  Draw : constant Draw_Spec :=
                    Parse_Draw (Value_After (Position, Argument));
               begin
                  for Existing of Draws loop
                     if Existing.Name = Draw.Name then
                        raise Constraint_Error
                          with
                            "duplicate draw parameter: "
                            & To_String (Draw.Name);
                     end if;
                  end loop;
                  Draws.Append (Draw);
               end;
            else
               raise Constraint_Error
                 with "unknown generate option: " & Argument;
            end if;
            Position := Position + 1;
         end;
      end loop;

      if Length (Model_Path) = 0
        or else Length (Pack) = 0
        or else Length (Output_Path) = 0
      then
         raise Constraint_Error
           with "generate requires --model, --pack, and --output";
      end if;
      if not Seed_Was_Set then
         Seed_Value := Entropy_Seed;
      end if;

      declare
         Tape            : Counterweave.Choices.Choice_Tape;
         Data_Path       : constant String := Temporary_Data_Path;
         Data_Content    : Unbounded_String;
         Parameters_JSON : Unbounded_String := To_Unbounded_String ("{");
         First           : Boolean := True;
      begin
         Counterweave.Choices.Start_Recording (Tape, Seed_Value);
         if Length (Base_Data_Path) > 0 then
            Append
              (Data_Content,
               Counterweave.Strings.Read_File (To_String (Base_Data_Path)));
            Append (Data_Content, ASCII.LF);
         end if;

         for Draw of Draws loop
            declare
               Width  : constant Interfaces.Unsigned_64 :=
                 Range_Width (Draw.Minimum, Draw.Maximum);
               Path   : constant Counterweave.Choices.Fork_Path :=
                 Counterweave.Choices.Child
                   (Counterweave.Choices.Child
                      (Counterweave.Choices.Root, "parameter", 0),
                    To_String (Draw.Name),
                    0);
               Offset : constant Interfaces.Unsigned_64 :=
                 Counterweave.Choices.Draw_Bounded (Tape, Path, Width);
               Value  : constant Long_Long_Integer :=
                 Add_Offset (Draw.Minimum, Offset);
               Image  : constant String :=
                 Counterweave.Strings.Compact_Image (Value);
            begin
               Append
                 (Data_Content,
                  To_String (Draw.Name) & " = " & Image & ";" & ASCII.LF);
               if First then
                  First := False;
               else
                  Append (Parameters_JSON, ",");
               end if;
               Append
                 (Parameters_JSON,
                  Counterweave.Strings.JSON_String (To_String (Draw.Name))
                  & ":"
                  & Image);
            end;
         end loop;
         Append (Parameters_JSON, "}");
         Counterweave.Strings.Write_File_Atomically
           (Data_Path, To_String (Data_Content));

         declare
            Seed_Path  : constant Counterweave.Choices.Fork_Path :=
              Counterweave.Choices.Child
                (Counterweave.Choices.Root, "completion", 0);
            Raw_Seed   : constant Interfaces.Unsigned_64 :=
              Counterweave.Choices.Draw (Tape, Seed_Path);
            Solution   : constant Counterweave.MiniZinc.Solution_Result :=
              Counterweave.MiniZinc.Solve_One
                (Model_Path           => To_String (Model_Path),
                 Data_Path            => Data_Path,
                 Solver               => To_String (Solver),
                 Random_Seed          => Raw_Seed,
                 Timeout_Milliseconds => Solver_Timeout);
            Case_Value : constant Counterweave.Artifacts.Case_Data :=
              (Pack_Name        => Pack,
               Pack_Version     => Pack_Version,
               Intent_Kind      => Intent,
               Intent_Target    => Target,
               Choices          => Tape,
               Solver           => Solver,
               MiniZinc_Version =>
                 To_Unbounded_String (Counterweave.MiniZinc.Version),
               Model_SHA256     =>
                 To_Unbounded_String
                   (Counterweave.Hashes.SHA256_File (To_String (Model_Path))),
               Compiled_SHA256  => Solution.Compiled_SHA256,
               Data_SHA256      =>
                 (if Length (Base_Data_Path) = 0
                  then Null_Unbounded_String
                  else
                    To_Unbounded_String
                      (Counterweave.Hashes.SHA256_File
                         (To_String (Base_Data_Path)))),
               Solver_Seed      => Solution.Applied_Seed,
               Seed_Applied     => Solution.Seed_Applied,
               Parameters_JSON  => Parameters_JSON,
               Solution_JSON    => Solution.Value_JSON);
         begin
            Counterweave.Artifacts.Write_Case
              (To_String (Output_Path), Case_Value);
            Status_Line ("generated " & To_String (Output_Path));
            Status_Line
              ("seed: " & Counterweave.Strings.Compact_Image (Seed_Value));
            if Length (Solution.Diagnostics) > 0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  To_String (Solution.Diagnostics));
            end if;
         end;
         Ada.Directories.Delete_File (Data_Path);
      exception
         when others =>
            if Ada.Directories.Exists (Data_Path) then
               Ada.Directories.Delete_File (Data_Path);
            end if;
            raise;
      end;
   end Generate;

   procedure Execute is
      Case_Path   : Unbounded_String;
      Adapter     : Unbounded_String;
      Output_Path : Unbounded_String;
      Timeout     : Positive := 5_000;
      Arguments   : Counterweave.Strings.String_Vector;
      Position    : Positive := 2;
   begin
      while Position <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Position);
         begin
            if Argument = "--case" then
               Case_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--adapter" then
               Adapter :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--output" then
               Output_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--timeout-ms" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Timeout := Positive'Value (Text);
               end;
            elsif Argument = "--adapter-arg" then
               Arguments.Append (Value_After (Position, Argument));
            else
               raise Constraint_Error
                 with "unknown execute option: " & Argument;
            end if;
            Position := Position + 1;
         end;
      end loop;
      if Length (Case_Path) = 0
        or else Length (Adapter) = 0
        or else Length (Output_Path) = 0
      then
         raise Constraint_Error
           with "execute requires --case, --adapter, and --output";
      end if;
      Counterweave.Artifacts.Validate_Case
        (Counterweave.Strings.Read_File (To_String (Case_Path)));
      Arguments.Prepend (To_String (Case_Path));
      Arguments.Prepend ("--case");
      declare
         Adapter_Hash : constant String :=
           Counterweave.Artifacts.Executable_SHA256 (To_String (Adapter));
         Result : Counterweave.Processes.Process_Result :=
           Counterweave.Processes.Run
             (To_String (Adapter), Arguments, Timeout);
      begin
         if Result.Outcome
           in Counterweave.Processes.Completed | Counterweave.Processes.Failed
         then
            begin
               declare
                  Observation : constant String :=
                    Counterweave.Strings.Extract_Only_JSON
                      (To_String (Result.Standard_Output));
               begin
                  if Observation'Length = 0 then
                     Result.Outcome := Counterweave.Processes.Protocol_Error;
                  end if;
               end;
            exception
               when Counterweave.Strings.Format_Error =>
                  Result.Outcome := Counterweave.Processes.Protocol_Error;
            end;
         end if;
         declare
            After_Hash : constant String :=
              Counterweave.Artifacts.Executable_SHA256 (To_String (Adapter));
         begin
            if Adapter_Hash'Length > 0 and then After_Hash /= Adapter_Hash then
               Result.Outcome := Counterweave.Processes.Protocol_Error;
               Append
                 (Result.Standard_Error,
                  "adapter executable changed during execution");
            end if;
         end;
         Counterweave.Artifacts.Write_Run
           (Path      => To_String (Output_Path),
            Case_Path => To_String (Case_Path),
            Adapter   => To_String (Adapter),
            Adapter_SHA256 => Adapter_Hash,
            Arguments => Arguments,
            Result    => Result);
         Status_Line
           ("wrote "
            & To_String (Output_Path)
            & " ("
            & Counterweave.Processes.Outcome_Kind'Image (Result.Outcome)
            & ")");
         if Result.Outcome /= Counterweave.Processes.Completed then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;
   end Execute;

   procedure Search is
      Model_Path      : Unbounded_String;
      Base_Data_Path  : Unbounded_String;
      Solver          : Unbounded_String := To_Unbounded_String ("cp-sat");
      Pack            : Unbounded_String;
      Pack_Version    : Unbounded_String := To_Unbounded_String ("1");
      Intent          : Unbounded_String := To_Unbounded_String ("explore");
      Target          : Unbounded_String := To_Unbounded_String ("default");
      Adapter         : Unbounded_String;
      Case_Output     : Unbounded_String;
      Run_Output      : Unbounded_String;
      Seed_Value      : Interfaces.Unsigned_64 := 0;
      Seed_Was_Set    : Boolean := False;
      Maximum_Trials  : Positive := 64;
      Solver_Timeout  : Positive := 30_000;
      Adapter_Timeout : Positive := 5_000;
      Draw_Arguments  : Counterweave.Strings.String_Vector;
      Adapter_Args    : Counterweave.Strings.String_Vector;
      Position        : Positive := 2;

      function Process_Detail
        (Result : Counterweave.Processes.Process_Result) return String is
      begin
         if Length (Result.Standard_Error) > 0 then
            return To_String (Result.Standard_Error);
         elsif Length (Result.Standard_Output) > 0 then
            return To_String (Result.Standard_Output);
         else
            return Counterweave.Processes.Outcome_Kind'Image (Result.Outcome);
         end if;
      end Process_Detail;
   begin
      while Position <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Position);
         begin
            if Argument = "--model" then
               Model_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--data" then
               Base_Data_Path :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--solver" then
               Solver :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--pack" then
               Pack := To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--pack-version" then
               Pack_Version :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--intent" then
               Intent := To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--target" then
               Target := To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--adapter" then
               Adapter := To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--case-output" then
               Case_Output :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--run-output" then
               Run_Output :=
                 To_Unbounded_String (Value_After (Position, Argument));
            elsif Argument = "--seed" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Seed_Value := Interfaces.Unsigned_64'Value (Text);
                  Seed_Was_Set := True;
               end;
            elsif Argument = "--trials" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Maximum_Trials := Positive'Value (Text);
               end;
            elsif Argument = "--solver-timeout-ms" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Solver_Timeout := Positive'Value (Text);
               end;
            elsif Argument = "--adapter-timeout-ms" then
               declare
                  Text : constant String := Value_After (Position, Argument);
               begin
                  Adapter_Timeout := Positive'Value (Text);
               end;
            elsif Argument = "--draw" then
               declare
                  Value : constant String := Value_After (Position, Argument);
                  Check : constant Draw_Spec := Parse_Draw (Value);
               begin
                  pragma Unreferenced (Check);
                  Draw_Arguments.Append (Value);
               end;
            elsif Argument = "--adapter-arg" then
               Adapter_Args.Append (Value_After (Position, Argument));
            else
               raise Constraint_Error
                 with "unknown search option: " & Argument;
            end if;
            Position := Position + 1;
         end;
      end loop;

      if Length (Model_Path) = 0
        or else Length (Pack) = 0
        or else Length (Adapter) = 0
        or else Length (Case_Output) = 0
        or else Length (Run_Output) = 0
      then
         raise Constraint_Error
           with
             "search requires --model, --pack, --adapter, --case-output, "
             & "and --run-output";
      end if;
      if not Seed_Was_Set then
         Seed_Value := Entropy_Seed;
      end if;

      declare
         Campaign_Tape : Counterweave.Choices.Choice_Tape;

         procedure Attempt
           (Index  : Positive;
            Result : out Counterweave.Campaign_UI.Attempt_Result)
         is
            Path       : constant Counterweave.Choices.Fork_Path :=
              Counterweave.Choices.Child
                (Counterweave.Choices.Child
                   (Counterweave.Choices.Root, "campaign", 0),
                 "trial",
                 Interfaces.Unsigned_64 (Index - 1));
            Trial_Seed : constant Interfaces.Unsigned_64 :=
              Counterweave.Choices.Draw (Campaign_Tape, Path);
            Generate_Arguments : Counterweave.Strings.String_Vector;
         begin
            Result :=
              (Outcome => Counterweave.Campaign_UI.Errored,
               Attempt => Index,
               Seed    => Trial_Seed,
               Detail  => Null_Unbounded_String);

            Generate_Arguments.Append ("generate");
            Generate_Arguments.Append ("--model");
            Generate_Arguments.Append (To_String (Model_Path));
            if Length (Base_Data_Path) > 0 then
               Generate_Arguments.Append ("--data");
               Generate_Arguments.Append (To_String (Base_Data_Path));
            end if;
            Generate_Arguments.Append ("--solver");
            Generate_Arguments.Append (To_String (Solver));
            Generate_Arguments.Append ("--pack");
            Generate_Arguments.Append (To_String (Pack));
            Generate_Arguments.Append ("--pack-version");
            Generate_Arguments.Append (To_String (Pack_Version));
            Generate_Arguments.Append ("--intent");
            Generate_Arguments.Append (To_String (Intent));
            Generate_Arguments.Append ("--target");
            Generate_Arguments.Append (To_String (Target));
            Generate_Arguments.Append ("--seed");
            Generate_Arguments.Append
              (Counterweave.Strings.Compact_Image (Trial_Seed));
            Generate_Arguments.Append ("--solver-timeout-ms");
            Generate_Arguments.Append
              (Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (Solver_Timeout)));
            for Draw of Draw_Arguments loop
               Generate_Arguments.Append ("--draw");
               Generate_Arguments.Append (Draw);
            end loop;
            Generate_Arguments.Append ("--output");
            Generate_Arguments.Append (To_String (Case_Output));

            declare
               Generated : constant Counterweave.Processes.Process_Result :=
                 Counterweave.Processes.Run
                   (Ada.Command_Line.Command_Name,
                    Generate_Arguments,
                    Solver_Timeout + 5_000);
            begin
               if Generated.Outcome = Counterweave.Processes.Cancelled then
                  Result.Outcome := Counterweave.Campaign_UI.Cancelled;
                  Result.Detail := To_Unbounded_String ("generation cancelled");
                  return;
               elsif Generated.Outcome /= Counterweave.Processes.Completed then
                  Result.Detail :=
                    To_Unbounded_String
                      ("generation failed: " & Process_Detail (Generated));
                  return;
               end if;
            end;

            if Ada.Directories.Exists (To_String (Run_Output)) then
               Ada.Directories.Delete_File (To_String (Run_Output));
            end if;
            declare
               Execute_Arguments : Counterweave.Strings.String_Vector;
            begin
               Execute_Arguments.Append ("execute");
               Execute_Arguments.Append ("--case");
               Execute_Arguments.Append (To_String (Case_Output));
               Execute_Arguments.Append ("--adapter");
               Execute_Arguments.Append (To_String (Adapter));
               Execute_Arguments.Append ("--timeout-ms");
               Execute_Arguments.Append
                 (Counterweave.Strings.Compact_Image
                    (Long_Long_Integer (Adapter_Timeout)));
               for Item of Adapter_Args loop
                  Execute_Arguments.Append ("--adapter-arg");
                  Execute_Arguments.Append (Item);
               end loop;
               Execute_Arguments.Append ("--output");
               Execute_Arguments.Append (To_String (Run_Output));

               declare
                  Executed : constant Counterweave.Processes.Process_Result :=
                    Counterweave.Processes.Run
                      (Ada.Command_Line.Command_Name,
                       Execute_Arguments,
                       Adapter_Timeout + 5_000);
               begin
                  if Executed.Outcome = Counterweave.Processes.Cancelled then
                     Result.Outcome := Counterweave.Campaign_UI.Cancelled;
                     Result.Detail := To_Unbounded_String ("execution cancelled");
                     return;
                  elsif Executed.Outcome
                    not in Counterweave.Processes.Completed
                           | Counterweave.Processes.Failed
                  then
                     Result.Detail :=
                       To_Unbounded_String
                         ("execution failed: " & Process_Detail (Executed));
                     return;
                  elsif not Ada.Directories.Exists (To_String (Run_Output)) then
                     Result.Detail :=
                       To_Unbounded_String
                         ("execution produced no run artifact");
                     return;
                  end if;

                  declare
                     Run_Outcome : constant String :=
                       Counterweave.Strings.Find_String
                         (Counterweave.Strings.Read_File
                            (To_String (Run_Output)),
                          "outcome");
                  begin
                     if Executed.Outcome = Counterweave.Processes.Completed
                       and then Run_Outcome = "completed"
                     then
                        Result.Outcome := Counterweave.Campaign_UI.Passed;
                        Result.Detail :=
                          To_Unbounded_String ("property held");
                     elsif Executed.Outcome = Counterweave.Processes.Failed
                       and then Run_Outcome = "failed"
                     then
                        Result.Outcome := Counterweave.Campaign_UI.Found;
                        Result.Detail :=
                          To_Unbounded_String ("property violation retained");
                     else
                        Result.Detail :=
                          To_Unbounded_String
                            ("run ended with " & Run_Outcome);
                     end if;
                  end;
               end;
            end;
         end Attempt;

         package Campaign is new
           Counterweave.Campaign_UI.Runs
             (Title            => "Exploring system-valid Ada histories",
              Maximum_Attempts => Maximum_Trials,
              Attempt          => Attempt);

         Final_Result : Counterweave.Campaign_UI.Attempt_Result;
         Attempts     : Natural;
      begin
         Counterweave.Choices.Start_Recording (Campaign_Tape, Seed_Value);
         Campaign.Run (Final_Result, Attempts);
         if Counterweave.Campaign_UI.Interactive then
            Counterweave.Terminal_Reports.Render_Search_Result
              (Result           => Final_Result,
               Attempts         => Attempts,
               Maximum_Attempts => Maximum_Trials,
               Case_Path        => To_String (Case_Output),
               Run_Path         => To_String (Run_Output),
               Adapter          => To_String (Adapter));
         end if;
         case Final_Result.Outcome is
            when Counterweave.Campaign_UI.Found =>
               if not Counterweave.Campaign_UI.Interactive then
                  Ada.Text_IO.Put_Line
                    ("found property violation after "
                     & Counterweave.Strings.Compact_Image
                         (Long_Long_Integer (Attempts))
                     & " constraint-valid trials");
                  Ada.Text_IO.Put_Line
                    ("case: " & To_String (Case_Output));
                  Ada.Text_IO.Put_Line
                    ("run:  " & To_String (Run_Output));
                  Ada.Text_IO.Put_Line
                    ("replay: "
                     & Ada.Command_Line.Command_Name
                     & " execute --case "
                     & To_String (Case_Output)
                     & " --adapter "
                     & To_String (Adapter)
                     & " --output "
                     & To_String (Run_Output));
               end if;
            when Counterweave.Campaign_UI.Passed =>
               if not Counterweave.Campaign_UI.Interactive then
                  Ada.Text_IO.Put_Line
                    ("no property violation found in "
                     & Counterweave.Strings.Compact_Image
                         (Long_Long_Integer (Attempts))
                     & " constraint-valid trials");
               end if;
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            when Counterweave.Campaign_UI.Cancelled =>
               if not Counterweave.Campaign_UI.Interactive then
                  Ada.Text_IO.Put_Line ("search cancelled");
               end if;
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            when Counterweave.Campaign_UI.Errored =>
               if not Counterweave.Campaign_UI.Interactive then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "search stopped: " & To_String (Final_Result.Detail));
               end if;
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end case;
      end;
   end Search;

begin
   if Ada.Command_Line.Argument_Count = 0 then
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   elsif Ada.Command_Line.Argument (1) = "generate" then
      declare
         package UI is new
           Counterweave.Terminal_UI
             (Title => "Generating a constraint-valid case", Action => Generate);
      begin
         Interactive_Status := UI.Interactive;
         UI.Run;
         Flush_Status;
      end;
   elsif Ada.Command_Line.Argument (1) = "execute" then
      declare
         package UI is new
           Counterweave.Terminal_UI
             (Title => "Executing generated Ada steps", Action => Execute);
      begin
         Interactive_Status := UI.Interactive;
         UI.Run;
         Flush_Status;
      end;
   elsif Ada.Command_Line.Argument (1) = "search" then
      Search;
   elsif Ada.Command_Line.Argument (1) = "inspect" then
      if Ada.Command_Line.Argument_Count /= 2 then
         raise Constraint_Error with "inspect requires one case path";
      end if;
      declare
         Content : constant String :=
           Counterweave.Strings.Read_File (Ada.Command_Line.Argument (2));
      begin
         Counterweave.Artifacts.Validate_Case (Content);
         Ada.Text_IO.Put (Content);
      end;
   elsif Ada.Command_Line.Argument (1) = "--version" then
      Ada.Text_IO.Put_Line (Counterweave.Version);
   else
      Usage;
      raise Constraint_Error
        with "unknown command: " & Ada.Command_Line.Argument (1);
   end if;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "counterweave: " & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Counterweave_Main;
