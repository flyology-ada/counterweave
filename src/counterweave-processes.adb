with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with GNAT.OS_Lib;

package body Counterweave.Processes is

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Size;
   use type Ada.Real_Time.Time;
   use type GNAT.OS_Lib.Process_Id;
   use type GNAT.OS_Lib.String_Access;

   Serial : Natural := 0;

   protected Process_Gate is
      entry Acquire;
      procedure Release;
   private
      Busy : Boolean := False;
   end Process_Gate;

   protected body Process_Gate is
      entry Acquire when not Busy is
      begin
         Busy := True;
      end Acquire;

      procedure Release is
      begin
         Busy := False;
      end Release;
   end Process_Gate;

   protected Cancellation is
      procedure End_Run;
      procedure Request;
      function Requested return Boolean;
   private
      Is_Requested : Boolean := False;
   end Cancellation;

   protected body Cancellation is
      procedure End_Run is
      begin
         Is_Requested := False;
      end End_Run;

      procedure Request is
      begin
         Is_Requested := True;
      end Request;

      function Requested return Boolean is (Is_Requested);
   end Cancellation;

   procedure Request_Cancel is
   begin
      Cancellation.Request;
   end Request_Cancel;

   function Temporary_Path (Suffix : String) return String is
      Pid       : constant String :=
        Ada.Strings.Fixed.Trim
          (Integer'Image
             (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)),
           Ada.Strings.Both);
      Directory : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "/tmp");
   begin
      Serial := Serial + 1;
      return
        Ada.Directories.Compose
          (Directory,
           "counterweave-"
           & Pid
           & "-"
           & Ada.Strings.Fixed.Trim (Natural'Image (Serial), Ada.Strings.Both)
           & Suffix);
   end Temporary_Path;

   procedure Remove_If_Present (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove_If_Present;

   function Run_Unguarded
     (Program              : String;
      Arguments            : Counterweave.Strings.String_Vector;
      Timeout_Milliseconds : Positive;
      Maximum_Output_Bytes : Positive := 1_048_576) return Process_Result
   is
      Executable   : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      Output_Path  : constant String := Temporary_Path (".stdout");
      Error_Path   : constant String := Temporary_Path (".stderr");
      OS_Arguments :
        GNAT.OS_Lib.Argument_List (1 .. Integer (Arguments.Length));
      Child        : GNAT.OS_Lib.Process_Id := GNAT.OS_Lib.Invalid_Pid;
      Reaped       : GNAT.OS_Lib.Process_Id;
      Success      : Boolean := False;
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Deadline     : constant Ada.Real_Time.Time :=
        Started + Ada.Real_Time.Milliseconds (Timeout_Milliseconds);
      Result       : Process_Result;

      function Exceeds_Limit (Path : String) return Boolean is
        (Ada.Directories.Exists (Path)
         and then Ada.Directories.Size (Path)
           > Ada.Directories.File_Size (Maximum_Output_Bytes));
   begin
      if Executable = null then
         Result.Standard_Error :=
           To_Unbounded_String ("executable not found: " & Program);
         return Result;
      end if;

      for Index in OS_Arguments'Range loop
         OS_Arguments (Index) := new String'(Arguments (Natural (Index - 1)));
      end loop;

      Child :=
        GNAT.OS_Lib.Non_Blocking_Spawn
          (Program_Name => Executable.all,
           Args         => OS_Arguments,
           Stdout_File  => Output_Path,
           Stderr_File  => Error_Path);

      for Item of OS_Arguments loop
         GNAT.OS_Lib.Free (Item);
      end loop;
      GNAT.OS_Lib.Free (Executable);

      if Child = GNAT.OS_Lib.Invalid_Pid then
         Result.Standard_Error :=
           To_Unbounded_String ("could not spawn: " & Program);
         Remove_If_Present (Output_Path);
         Remove_If_Present (Error_Path);
         return Result;
      end if;

      loop
         GNAT.OS_Lib.Non_Blocking_Wait_Process (Reaped, Success);
         if Reaped = Child then
            Child := GNAT.OS_Lib.Invalid_Pid;
            exit;
         end if;
         if Cancellation.Requested then
            GNAT.OS_Lib.Kill_Process_Tree (Child);
            GNAT.OS_Lib.Wait_Process (Reaped, Success);
            Child := GNAT.OS_Lib.Invalid_Pid;
            Result.Outcome := Cancelled;
            exit;
         elsif Exceeds_Limit (Output_Path)
           or else Exceeds_Limit (Error_Path)
         then
            GNAT.OS_Lib.Kill_Process_Tree (Child);
            GNAT.OS_Lib.Wait_Process (Reaped, Success);
            Child := GNAT.OS_Lib.Invalid_Pid;
            Result.Outcome := Output_Limit;
            exit;
         end if;
         if Ada.Real_Time.Clock >= Deadline then
            GNAT.OS_Lib.Kill_Process_Tree (Child);
            GNAT.OS_Lib.Wait_Process (Reaped, Success);
            Child := GNAT.OS_Lib.Invalid_Pid;
            Result.Outcome := Timed_Out;
            exit;
         end if;
         delay 0.01;
      end loop;

      if Result.Outcome not in Timed_Out | Cancelled | Output_Limit then
         if Exceeds_Limit (Output_Path) or else Exceeds_Limit (Error_Path) then
            Result.Outcome := Output_Limit;
         else
            Result.Outcome := (if Success then Completed else Failed);
         end if;
      end if;
      Result.Elapsed_Milliseconds :=
        Natural
          (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started)
           * 1_000.0);
      if Result.Outcome = Output_Limit then
         Result.Standard_Error :=
           To_Unbounded_String ("subprocess output exceeded configured limit");
      elsif Ada.Directories.Exists (Output_Path) then
         Result.Standard_Output :=
           To_Unbounded_String
             (Counterweave.Strings.Read_File
                (Output_Path, Maximum_Output_Bytes));
      end if;
      if Result.Outcome /= Output_Limit
        and then Ada.Directories.Exists (Error_Path)
      then
         Result.Standard_Error :=
           To_Unbounded_String
             (Counterweave.Strings.Read_File
                (Error_Path, Maximum_Output_Bytes));
      end if;
      Remove_If_Present (Output_Path);
      Remove_If_Present (Error_Path);
      return Result;
   exception
      when others =>
         if Child /= GNAT.OS_Lib.Invalid_Pid then
            GNAT.OS_Lib.Kill_Process_Tree (Child);
         end if;
         for Item of OS_Arguments loop
            GNAT.OS_Lib.Free (Item);
         end loop;
         GNAT.OS_Lib.Free (Executable);
         Remove_If_Present (Output_Path);
         Remove_If_Present (Error_Path);
         raise;
   end Run_Unguarded;

   function Run
     (Program              : String;
      Arguments            : Counterweave.Strings.String_Vector;
      Timeout_Milliseconds : Positive;
      Maximum_Output_Bytes : Positive := 1_048_576) return Process_Result
   is
   begin
      Process_Gate.Acquire;
      declare
         Result : constant Process_Result :=
           Run_Unguarded
             (Program,
              Arguments,
              Timeout_Milliseconds,
              Maximum_Output_Bytes);
      begin
         Cancellation.End_Run;
         Process_Gate.Release;
         return Result;
      end;
   exception
      when others =>
         Cancellation.End_Run;
         Process_Gate.Release;
         raise;
   end Run;

end Counterweave.Processes;
