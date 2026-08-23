with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Counterweave.Hashes;
with Counterweave.Processes;
with Counterweave.Strings;
with GNAT.OS_Lib;

package body Counterweave.MiniZinc is

   use Ada.Strings.Unbounded;
   use type Counterweave.Processes.Outcome_Kind;
   use type Interfaces.Unsigned_64;

   protected Temporary_Names is
      procedure Next (Value : out Natural);
   private
      Serial : Natural := 0;
   end Temporary_Names;

   protected body Temporary_Names is
      procedure Next (Value : out Natural) is
      begin
         Serial := Serial + 1;
         Value := Serial;
      end Next;
   end Temporary_Names;

   function Temporary_FlatZinc_Path return String is
      Serial    : Natural;
      Directory : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
      PID       : constant String :=
        Ada.Strings.Fixed.Trim
          (Integer'Image
             (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)),
           Ada.Strings.Both);
   begin
      Temporary_Names.Next (Serial);
      return
        Ada.Directories.Compose
          (Directory,
           "counterweave-flat-"
           & PID
           & "-"
           & Ada.Strings.Fixed.Trim
               (Natural'Image (Serial), Ada.Strings.Both)
           & ".fzn");
   end Temporary_FlatZinc_Path;

   function Version
     (Executable           : String := "minizinc";
      Timeout_Milliseconds : Positive := 5_000) return String
   is
      Arguments : Counterweave.Strings.String_Vector;
      Result    : Counterweave.Processes.Process_Result;
   begin
      Arguments.Append ("--version");
      Result :=
        Counterweave.Processes.Run
          (Executable, Arguments, Timeout_Milliseconds);
      if Result.Outcome /= Counterweave.Processes.Completed then
         raise MiniZinc_Error
           with
             "could not query MiniZinc version: "
             & To_String (Result.Standard_Error);
      end if;
      declare
         Output  : constant String := To_String (Result.Standard_Output);
         Newline : constant Natural :=
           Ada.Strings.Fixed.Index (Output, String'(1 => ASCII.LF));
      begin
         return
           (if Newline = 0
            then Output
            else Output (Output'First .. Newline - 1));
      end;
   end Version;

   function Solve_One
     (Model_Path           : String;
      Data_Path            : String;
      Solver               : String;
      Random_Seed          : Interfaces.Unsigned_64;
      Timeout_Milliseconds : Positive := 30_000;
      Executable           : String := "minizinc") return Solution_Result
   is
      Arguments    : Counterweave.Strings.String_Vector;
      Process      : Counterweave.Processes.Process_Result;
      Flat_Path    : constant String := Temporary_FlatZinc_Path;
      Applied_Seed : constant Interfaces.Unsigned_64 := Random_Seed mod 2**31;
      Seed_Applied : constant Boolean :=
        Solver = "cp-sat" or else Solver = "org.minizinc.or-tools";
   begin
      Arguments.Append ("--solver");
      Arguments.Append (Solver);
      Arguments.Append ("--output-mode");
      Arguments.Append ("json");
      Arguments.Append ("--fzn");
      Arguments.Append (Flat_Path);
      if Seed_Applied then
         Arguments.Append ("--fzn-flag");
         Arguments.Append
           ("--params=random_seed:"
            & Counterweave.Strings.Compact_Image (Applied_Seed));
      end if;
      Arguments.Append (Model_Path);
      Arguments.Append (Data_Path);

      Process :=
        Counterweave.Processes.Run
          (Executable, Arguments, Timeout_Milliseconds);
      if Process.Outcome = Counterweave.Processes.Timed_Out then
         raise MiniZinc_Error with "MiniZinc exceeded its deadline";
      elsif Process.Outcome = Counterweave.Processes.Cancelled then
         raise MiniZinc_Error with "MiniZinc was cancelled";
      elsif Process.Outcome /= Counterweave.Processes.Completed then
         raise MiniZinc_Error
           with "MiniZinc failed: " & To_String (Process.Standard_Error);
      end if;

      declare
         Output : constant String := To_String (Process.Standard_Output);
      begin
         if Ada.Strings.Fixed.Index (Output, "=====UNSATISFIABLE=====") /= 0
         then
            raise MiniZinc_Error with "MiniZinc model is unsatisfiable";
         end if;
         declare
            Result : constant Solution_Result :=
              (Value_JSON      =>
                 To_Unbounded_String
                   (Counterweave.Strings.Extract_First_JSON (Output)),
               Diagnostics     => Process.Standard_Error,
               Compiled_SHA256 =>
                 To_Unbounded_String
                   (Counterweave.Hashes.SHA256_File (Flat_Path)),
               Applied_Seed    => Applied_Seed,
               Seed_Applied    => Seed_Applied);
         begin
            Ada.Directories.Delete_File (Flat_Path);
            return Result;
         end;
      end;
   exception
      when others =>
         if Ada.Directories.Exists (Flat_Path) then
            Ada.Directories.Delete_File (Flat_Path);
         end if;
         raise;
   end Solve_One;

end Counterweave.MiniZinc;
