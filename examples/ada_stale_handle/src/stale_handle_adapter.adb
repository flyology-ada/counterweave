with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Buggy_Handle_Pool;
with Counterweave.Adapter_Results;
with Counterweave.Artifacts;
with Counterweave.Hashes;
with Counterweave.JSON;
with Counterweave.Strings;
with Flyology_TLA.Codecs;
with Flyology_TLA.Replay;
with Flyology_TLA.Reporting;
with Flyology_TLA.Traces;

procedure Stale_Handle_Adapter is

   use Ada.Strings.Unbounded;
   use type Counterweave.JSON.Value_Kind;
   use type Flyology_TLA.Replay.Verdict;

   function Case_Path return String is
   begin
      if Ada.Command_Line.Argument_Count = 2
        and then Ada.Command_Line.Argument (1) = "--case"
      then
         return Ada.Command_Line.Argument (2);
      end if;
      raise Constraint_Error with "usage: stale_handle_adapter --case PATH";
   end Case_Path;

   Source        : constant String :=
     Counterweave.Strings.Read_File (Case_Path);
   Root          : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Parse (Source);
   Pack          : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "pack");
   Provenance    : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "provenance");
   Model         : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Provenance, "model");
   Payload       : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "payload");
   Parameters    : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "parameters");
   Solution      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "solution");
   Operations    : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_operation");
   Handles       : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_handle");
   Values        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_value");
   Expectations  : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_expectation");
   Active        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "active");
   Stored_Values : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "stored_value");
   Case_Format   : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Root, "format")));

   function Configuration_SHA256 return String is
      Node : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Model, "data_sha256");
   begin
      if Case_Format = "counterweave.case/3"
        and then Counterweave.JSON.Kind (Node) = Counterweave.JSON.String_Value
      then
         return To_String (Counterweave.JSON.As_String (Source, Node));
      elsif Case_Format = "counterweave.case/2" then
         return Counterweave.Artifacts.Case_Replay_SHA256 (Source);
      end if;
      raise Constraint_Error with "case configuration identity is invalid";
   end Configuration_SHA256;

   Pack_Name        : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name")));
   Pack_Version     : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version")));
   Model_SHA256     : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "model_sha256")));
   Data_SHA256      : constant String := Configuration_SHA256;
   MiniZinc_Version : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source,
           Counterweave.JSON.Member (Source, Model, "minizinc_version")));
   Solver           : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "solver")));
   Capacity         : constant Buggy_Handle_Pool.Slot_Number :=
     Buggy_Handle_Pool.Slot_Number
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "capacity")));
   History_Shape    : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "history_shape")));
   Scenario         : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "scenario")));
   Step_Count       : constant Natural :=
     Counterweave.JSON.Length (Source, Operations);
   --  Preserve Counterweave's 1 MiB process-output and 4,096-step bounds;
   --  the remaining dimensions follow flyology_tla's reviewed Ada consumer.
   Limits           : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_048_576,
      Maximum_Steps        => 4_096,
      Maximum_JSON_Depth   => 64,
      Maximum_Object_Names => 10_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 1_048_576);

   function Integer_At
     (Items : Counterweave.JSON.Value; Index : Natural) return Integer
   is (Integer
         (Counterweave.JSON.As_Integer
            (Source, Counterweave.JSON.Element (Source, Items, Index))));

   function Boolean_At
     (Items : Counterweave.JSON.Value; Index : Natural) return Boolean
   is (Counterweave.JSON.As_Boolean
         (Source, Counterweave.JSON.Element (Source, Items, Index)));

   function Operation_Name (Operation : Integer) return String is
   begin
      case Operation is
         when 1      =>
            return "Allocate";

         when 2      =>
            return "Write";

         when 3      =>
            return "Release";

         when 4      =>
            return "Read";

         when others =>
            raise Constraint_Error with "unknown generated operation";
      end case;
   end Operation_Name;

   function Role_Name
     (Operation, Handle_Id, Expectation : Integer) return String
   is (if Expectation = 1
       then "stale-probe"
       elsif Operation = 1
       then
         (case Handle_Id is
            when 1      => "allocate-original",
            when 2 | 3  => "allocate-intermediate",
            when 4      => "allocate-replacement",
            when others => "allocate-generated")
       elsif Operation = 3
       then "release-generation"
       elsif Operation = 2 and then Handle_Id = 4
       then "write-replacement"
       elsif Operation = 2
       then "live-write"
       else "live-probe");

   function State_JSON (State_Index : Natural) return String
   is ("{""active"":"
       & (if Boolean_At (Active, State_Index) then "true" else "false")
       & ",""stored_value"":"
       & Counterweave.Strings.Compact_Image
           (Long_Long_Integer (Integer_At (Stored_Values, State_Index)))
       & "}");

   function Input_JSON (Handle_Id, Value : Integer) return String
   is ("{""handle"":"
       & Counterweave.Strings.Compact_Image (Long_Long_Integer (Handle_Id))
       & ",""value"":"
       & Counterweave.Strings.Compact_Image (Long_Long_Integer (Value))
       & "}");

   function Expected_Outcome_JSON
     (Operation, Expectation, State_Index : Integer) return String
   is (if Expectation = 1
       then "{""status"":""stale""}"
       elsif Operation = 1
       then "{""status"":""allocated""}"
       elsif Operation = 2
       then "{""status"":""written""}"
       elsif Operation = 3
       then "{""status"":""released""}"
       else
         "{""status"":""value"",""value"":"
         & Counterweave.Strings.Compact_Image
             (Long_Long_Integer (Integer_At (Stored_Values, State_Index)))
         & "}");

   function Build_Trace return Flyology_TLA.Traces.Trace is
      Result : Flyology_TLA.Traces.Trace;
   begin
      Result.Model :=
        (Module_Name          => To_Unbounded_String ("StaleHandle"),
         Configuration        =>
           To_Unbounded_String (Pack_Name & "/" & Pack_Version),
         Source_SHA256        => To_Unbounded_String (Model_SHA256),
         Configuration_SHA256 => To_Unbounded_String (Data_SHA256),
         Toolchain_Identity   =>
           To_Unbounded_String
             ("minizinc " & MiniZinc_Version & "; solver " & Solver));
      Result.Initial_State_JSON := To_Unbounded_String (State_JSON (0));
      for Offset in 0 .. Step_Count loop
         exit when Offset = Step_Count;
         declare
            Operation   : constant Integer := Integer_At (Operations, Offset);
            Handle_Id   : constant Integer := Integer_At (Handles, Offset);
            Value       : constant Integer := Integer_At (Values, Offset);
            Expectation : constant Integer :=
              Integer_At (Expectations, Offset);
            Action      : constant String :=
              "StaleHandle!" & Operation_Name (Operation);
         begin
            Result.Steps.Append
              (Flyology_TLA.Traces.Trace_Step'
                 (Index                 => Offset + 1,
                  Action                => To_Unbounded_String (Action),
                  Role                  =>
                    To_Unbounded_String
                      (Role_Name (Operation, Handle_Id, Expectation)),
                  Input_JSON            =>
                    To_Unbounded_String (Input_JSON (Handle_Id, Value)),
                  Expected_Outcome_JSON =>
                    To_Unbounded_String
                      (Expected_Outcome_JSON
                         (Operation, Expectation, Offset + 1)),
                  Expected_State_JSON   =>
                    To_Unbounded_String (State_JSON (Offset + 1)),
                  Model_Source          => To_Unbounded_String (Action)));
         end;
      end loop;
      return Result;
   end Build_Trace;

   package Implementation is

      type Handle_State is record
         Bound : Boolean := False;
         Value : Buggy_Handle_Pool.Handle;
      end record;

      type Handle_Table is array (Positive range 1 .. 4) of Handle_State;

      type Stale_Adapter is new Flyology_TLA.Replay.Adapter with record
         Container         : Buggy_Handle_Pool.Pool (Capacity);
         Bound_Handles     : Handle_Table;
         Active            : Boolean := False;
         Stored_Value      : Integer := 0;
         Observations      : Unbounded_String := To_Unbounded_String ("[");
         First_Observation : Boolean := True;
         Observed_Value    : Integer := 0;
      end record;

      overriding
      procedure Reset
        (Self                : in out Stale_Adapter;
         Observed_State_JSON : out Unbounded_String;
         Outcome             : out Flyology_TLA.Replay.Adapter_Outcome);

      overriding
      procedure Apply
        (Self                  : in out Stale_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Observed_Outcome_JSON : out Unbounded_String;
         Observed_State_JSON   : out Unbounded_String;
         Outcome               : out Flyology_TLA.Replay.Adapter_Outcome);

      overriding
      procedure Compare_Step
        (Self                  : in out Stale_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Expected_Outcome_JSON : String;
         Expected_State_JSON   : String;
         Observed_Outcome_JSON : String;
         Observed_State_JSON   : String;
         Limits                : Flyology_TLA.Traces.Load_Limits;
         Result                : out Flyology_TLA.Replay.Comparison);

   end Implementation;

   package body Implementation is

      function State_JSON (Self : Stale_Adapter) return String
      is ("{""active"":"
          & (if Self.Active then "true" else "false")
          & ",""stored_value"":"
          & Counterweave.Strings.Compact_Image
              (Long_Long_Integer (Self.Stored_Value))
          & "}");

      procedure Begin_Observation
        (Self : in out Stale_Adapter; Index : Positive; Operation : String) is
      begin
         if Self.First_Observation then
            Self.First_Observation := False;
         else
            Append (Self.Observations, ",");
         end if;
         Append
           (Self.Observations,
            "{""index"":"
            & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index))
            & ",""operation"":"
            & Counterweave.Strings.JSON_String (Operation));
      end Begin_Observation;

      procedure Reset
        (Self                : in out Stale_Adapter;
         Observed_State_JSON : out Unbounded_String;
         Outcome             : out Flyology_TLA.Replay.Adapter_Outcome) is
      begin
         Buggy_Handle_Pool.Initialize (Self.Container);
         Self.Bound_Handles := [others => <>];
         Self.Active := False;
         Self.Stored_Value := 0;
         Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
         Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
      end Reset;

      procedure Apply
        (Self                  : in out Stale_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Observed_Outcome_JSON : out Unbounded_String;
         Observed_State_JSON   : out Unbounded_String;
         Outcome               : out Flyology_TLA.Replay.Adapter_Outcome)
      is
         Input     : constant String := To_String (Command.Input_JSON);
         Handle_Id : constant Positive :=
           Positive
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member (Input, "handle", Limits)));
         Value     : constant Integer :=
           Integer
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member (Input, "value", Limits)));
         Action    : constant String := To_String (Command.Action);

         procedure Record_Result (Status : String) is
         begin
            Append
              (Self.Observations,
               ",""status"":"
               & Counterweave.Strings.JSON_String (Status)
               & "}");
         end Record_Result;
      begin
         Begin_Observation (Self, Command.Index, Action);
         if Action = "StaleHandle!Allocate" then
            Self.Bound_Handles (Handle_Id) :=
              (Bound => True,
               Value => Buggy_Handle_Pool.Allocate (Self.Container));
            Self.Active := True;
            Observed_Outcome_JSON :=
              To_Unbounded_String ("{""status"":""allocated""}");
            Record_Result ("allocated");
         elsif Action = "StaleHandle!Write" then
            Buggy_Handle_Pool.Write
              (Self.Container, Self.Bound_Handles (Handle_Id).Value, Value);
            Self.Stored_Value := Value;
            Observed_Outcome_JSON :=
              To_Unbounded_String ("{""status"":""written""}");
            Record_Result ("written");
         elsif Action = "StaleHandle!Release" then
            Buggy_Handle_Pool.Release
              (Self.Container, Self.Bound_Handles (Handle_Id).Value);
            Self.Active := False;
            Observed_Outcome_JSON :=
              To_Unbounded_String ("{""status"":""released""}");
            Record_Result ("released");
         elsif Action = "StaleHandle!Read" then
            Self.Observed_Value :=
              Buggy_Handle_Pool.Read
                (Self.Container, Self.Bound_Handles (Handle_Id).Value);
            Observed_Outcome_JSON :=
              To_Unbounded_String
                ("{""status"":""value"",""value"":"
                 & Counterweave.Strings.Compact_Image
                     (Long_Long_Integer (Self.Observed_Value))
                 & "}");
            Record_Result ("value");
         else
            raise Constraint_Error with "unsupported modeled action";
         end if;
         Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
         Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
      exception
         when Buggy_Handle_Pool.Stale_Handle =>
            Observed_Outcome_JSON :=
              To_Unbounded_String ("{""status"":""stale""}");
            Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
            Record_Result ("stale");
            Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
         when Buggy_Handle_Pool.Pool_Exhausted =>
            Observed_Outcome_JSON :=
              To_Unbounded_String ("{""status"":""pool-exhausted""}");
            Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
            Record_Result ("pool-exhausted");
            Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
         when Error : others =>
            Observed_Outcome_JSON := Null_Unbounded_String;
            Observed_State_JSON := Null_Unbounded_String;
            Outcome :=
              (Succeeded => False,
               Detail    =>
                 To_Unbounded_String
                   (Ada.Exceptions.Exception_Message (Error)));
      end Apply;

      procedure Compare_Step
        (Self                  : in out Stale_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Expected_Outcome_JSON : String;
         Expected_State_JSON   : String;
         Observed_Outcome_JSON : String;
         Observed_State_JSON   : String;
         Limits                : Flyology_TLA.Traces.Load_Limits;
         Result                : out Flyology_TLA.Replay.Comparison) is
      begin
         Flyology_TLA.Replay.Compare_Step
           (Flyology_TLA.Replay.Adapter (Self),
            Command,
            Expected_Outcome_JSON,
            Expected_State_JSON,
            Observed_Outcome_JSON,
            Observed_State_JSON,
            Limits,
            Result);
         if not Result.Equivalent then
            if To_String (Command.Role) = "stale-probe" then
               Result.Fingerprint :=
                 To_Unbounded_String ("stale-read-accepted");
               Result.Detail :=
                 To_Unbounded_String
                   ("a released handle read the replacement value");
            else
               Result.Fingerprint :=
                 To_Unbounded_String ("modeled-handle-state-diverged");
            end if;
         end if;
      end Compare_Step;

   end Implementation;

begin
   if Pack_Name /= "ada-stale-handle" or else Pack_Version /= "1" then
      raise Constraint_Error
        with "unsupported model pack: " & Pack_Name & "/" & Pack_Version;
   elsif Counterweave.JSON.Length (Source, Handles) /= Step_Count
     or else Counterweave.JSON.Length (Source, Values) /= Step_Count
     or else Counterweave.JSON.Length (Source, Expectations) /= Step_Count
     or else Counterweave.JSON.Length (Source, Active) /= Step_Count + 1
     or else Counterweave.JSON.Length (Source, Stored_Values) /= Step_Count + 1
   then
      raise Constraint_Error with "model arrays have different lengths";
   end if;

   declare
      Trace      : constant Flyology_TLA.Traces.Trace := Build_Trace;
      Trace_JSON : constant String :=
        Flyology_TLA.Traces.Image (Trace, Natural (Trace.Steps.Length));
      Trace_Hash : constant String := Counterweave.Hashes.SHA256 (Trace_JSON);
      Adapter    : Implementation.Stale_Adapter;
      Replay     : Flyology_TLA.Replay.Replay_Result;
   begin
      Flyology_TLA.Replay.Run (Adapter, Trace, Limits, Replay);
      Replay.Property_Name :=
        To_Unbounded_String ("released-handles-stay-stale");
      if Replay.Status
         in Flyology_TLA.Replay.Adapter_Error
          | Flyology_TLA.Replay.Invalid_Trace
      then
         raise Constraint_Error with To_String (Replay.Detail);
      end if;
      Append (Adapter.Observations, "]");
      declare
         Observation_Object : constant String :=
           "{""steps"":"
           & To_String (Adapter.Observations)
           & ",""scenario"":"
           & Integer'Image (Scenario)
           & ",""history_shape"":"
           & Integer'Image (History_Shape)
           & ",""observed_value"":"
           & Integer'Image (Adapter.Observed_Value)
           & ",""old_generation"":"
           & Natural'Image (Adapter.Bound_Handles (1).Value.Generation)
           & ",""new_generation"":"
           & Natural'Image (Adapter.Bound_Handles (4).Value.Generation)
           & "}";
         Result             :
           constant Counterweave.Adapter_Results.Adapter_Result :=
             (Verdict             =>
                (if Replay.Status = Flyology_TLA.Replay.Diverged
                 then Counterweave.Adapter_Results.Property_Violation
                 else Counterweave.Adapter_Results.Passed),
              Pack_Name           => To_Unbounded_String (Pack_Name),
              Pack_Version        => To_Unbounded_String (Pack_Version),
              Property_Name       => Replay.Property_Name,
              Failure_Fingerprint => Replay.Fingerprint,
              Observations_JSON   => To_Unbounded_String (Observation_Object),
              Conformance_JSON    =>
                To_Unbounded_String
                  (Flyology_TLA.Reporting.JSON_Image (Replay, Trace_Hash)),
              Trace_JSON          => To_Unbounded_String (Trace_JSON));
      begin
         Ada.Text_IO.Put_Line (Counterweave.Adapter_Results.To_JSON (Result));
      end;
   end;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "stale_handle_adapter: " & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Stale_Handle_Adapter;
