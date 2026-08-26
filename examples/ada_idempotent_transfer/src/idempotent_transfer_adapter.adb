with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Buggy_Transfer_Ledger;
with Counterweave.Adapter_Results;
with Counterweave.Artifacts;
with Counterweave.Hashes;
with Counterweave.JSON;
with Counterweave.Strings;
with Flyology_TLA.Codecs;
with Flyology_TLA.Replay;
with Flyology_TLA.Reporting;
with Flyology_TLA.Traces;

procedure Idempotent_Transfer_Adapter is

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
      raise Constraint_Error
        with "usage: idempotent_transfer_adapter --case PATH";
   end Case_Path;

   Source       : constant String :=
     Counterweave.Strings.Read_File (Case_Path);
   Root         : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Parse (Source);
   Pack         : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "pack");
   Provenance   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "provenance");
   Model        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Provenance, "model");
   Payload      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "payload");
   Parameters   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "parameters");
   Solution     : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "solution");
   Operations   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_operation");
   Transactions : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_transaction");
   Sources      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_source");
   Destinations : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_destination");
   Amounts      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_amount");
   Expectations : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_expectation");
   Balances     : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "balance");
   Case_Format  : constant String :=
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

   Pack_Name           : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name")));
   Pack_Version        : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version")));
   Model_SHA256        : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "model_sha256")));
   Data_SHA256         : constant String := Configuration_SHA256;
   MiniZinc_Version    : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source,
           Counterweave.JSON.Member (Source, Model, "minizinc_version")));
   Solver              : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Model, "solver")));
   Account_Count       : constant Positive :=
     Positive
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "account_count")));
   Initial_Balance     : constant Natural :=
     Natural
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "initial_balance")));
   Declared_Step_Count : constant Positive :=
     Positive
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "step_count")));
   Step_Count          : constant Positive :=
     Positive (Counterweave.JSON.Length (Source, Operations));
   --  Preserve Counterweave's 1 MiB process-output and 4,096-step bounds;
   --  the remaining dimensions follow flyology_tla's reviewed Ada consumer.
   Limits              : constant Flyology_TLA.Traces.Load_Limits :=
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

   function Expected_Balance
     (State_Index : Natural; Account : Positive) return Natural
   is
      Row : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Element (Source, Balances, State_Index);
   begin
      return
        Natural
          (Counterweave.JSON.As_Integer
             (Source, Counterweave.JSON.Element (Source, Row, Account - 1)));
   end Expected_Balance;

   function Expected_State_JSON (State_Index : Natural) return String is
      Result : Unbounded_String := To_Unbounded_String ("{""balances"":[");
   begin
      for Account in 1 .. Account_Count loop
         if Account > 1 then
            Append (Result, ",");
         end if;
         Append
           (Result,
            Counterweave.Strings.Compact_Image
              (Long_Long_Integer (Expected_Balance (State_Index, Account))));
      end loop;
      Append (Result, "]}");
      return To_String (Result);
   end Expected_State_JSON;

   function Input_JSON
     (Transaction, Source_Account, Target_Account, Value : Integer)
      return String
   is ("{""transaction"":"
       & Counterweave.Strings.Compact_Image (Long_Long_Integer (Transaction))
       & ",""source"":"
       & Counterweave.Strings.Compact_Image
           (Long_Long_Integer (Source_Account))
       & ",""destination"":"
       & Counterweave.Strings.Compact_Image
           (Long_Long_Integer (Target_Account))
       & ",""amount"":"
       & Counterweave.Strings.Compact_Image (Long_Long_Integer (Value))
       & "}");

   function Build_Trace return Flyology_TLA.Traces.Trace is
      Result : Flyology_TLA.Traces.Trace;
   begin
      Result.Model :=
        (Module_Name          => To_Unbounded_String ("TransferLedger"),
         Configuration        =>
           To_Unbounded_String (Pack_Name & "/" & Pack_Version),
         Source_SHA256        => To_Unbounded_String (Model_SHA256),
         Configuration_SHA256 => To_Unbounded_String (Data_SHA256),
         Toolchain_Identity   =>
           To_Unbounded_String
             ("minizinc " & MiniZinc_Version & "; solver " & Solver));
      Result.Initial_State_JSON :=
        To_Unbounded_String (Expected_State_JSON (0));
      for Offset in 0 .. Step_Count - 1 loop
         declare
            Operation      : constant Integer :=
              Integer_At (Operations, Offset);
            Transaction    : constant Integer :=
              Integer_At (Transactions, Offset);
            Source_Account : constant Integer := Integer_At (Sources, Offset);
            Target_Account : constant Integer :=
              Integer_At (Destinations, Offset);
            Value          : constant Integer := Integer_At (Amounts, Offset);
            Expected       : constant Boolean :=
              Integer_At (Expectations, Offset) = 1;
            Name           : constant String :=
              (if Operation = 1 then "Deposit" else "Transfer");
            Action         : constant String := "TransferLedger!" & Name;
            Role           : constant String :=
              (if Operation = 1
               then "deposit"
               elsif Expected
               then "transfer"
               else "duplicate-transfer-retry");
         begin
            if Operation not in 1 .. 2 then
               raise Constraint_Error with "unknown generated operation";
            end if;
            Result.Steps.Append
              (Flyology_TLA.Traces.Trace_Step'
                 (Index                 => Offset + 1,
                  Action                => To_Unbounded_String (Action),
                  Role                  => To_Unbounded_String (Role),
                  Input_JSON            =>
                    To_Unbounded_String
                      (Input_JSON
                         (Transaction, Source_Account, Target_Account, Value)),
                  Expected_Outcome_JSON =>
                    To_Unbounded_String
                      ("{""applied"":"
                       & (if Expected then "true" else "false")
                       & ",""error"":null}"),
                  Expected_State_JSON   =>
                    To_Unbounded_String (Expected_State_JSON (Offset + 1)),
                  Model_Source          => To_Unbounded_String (Action)));
         end;
      end loop;
      return Result;
   end Build_Trace;

   package Implementation is

      type Transfer_Adapter is new Flyology_TLA.Replay.Adapter with record
         System            :
           Buggy_Transfer_Ledger.Ledger
             (Account_Count => Account_Count,
              Transaction_Capacity => Step_Count);
         Observations      : Unbounded_String := To_Unbounded_String ("[");
         First_Observation : Boolean := True;
         Duplicate_Steps   : Natural := 0;
      end record;

      overriding
      procedure Reset
        (Self                : in out Transfer_Adapter;
         Observed_State_JSON : out Unbounded_String;
         Outcome             : out Flyology_TLA.Replay.Adapter_Outcome);

      overriding
      procedure Apply
        (Self                  : in out Transfer_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Observed_Outcome_JSON : out Unbounded_String;
         Observed_State_JSON   : out Unbounded_String;
         Outcome               : out Flyology_TLA.Replay.Adapter_Outcome);

      overriding
      procedure Compare_Step
        (Self                  : in out Transfer_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Expected_Outcome_JSON : String;
         Expected_State_JSON   : String;
         Observed_Outcome_JSON : String;
         Observed_State_JSON   : String;
         Limits                : Flyology_TLA.Traces.Load_Limits;
         Result                : out Flyology_TLA.Replay.Comparison);

   end Implementation;

   package body Implementation is

      function State_JSON (Self : Transfer_Adapter) return String is
         Result : Unbounded_String := To_Unbounded_String ("{""balances"":[");
      begin
         for Account in 1 .. Account_Count loop
            if Account > 1 then
               Append (Result, ",");
            end if;
            Append
              (Result,
               Counterweave.Strings.Compact_Image
                 (Long_Long_Integer
                    (Buggy_Transfer_Ledger.Balance (Self.System, Account))));
         end loop;
         Append (Result, "]}");
         return To_String (Result);
      end State_JSON;

      procedure Reset
        (Self                : in out Transfer_Adapter;
         Observed_State_JSON : out Unbounded_String;
         Outcome             : out Flyology_TLA.Replay.Adapter_Outcome) is
      begin
         Buggy_Transfer_Ledger.Initialize (Self.System, Initial_Balance);
         Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
         Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
      end Reset;

      procedure Apply
        (Self                  : in out Transfer_Adapter;
         Command               : Flyology_TLA.Replay.Replay_Command;
         Observed_Outcome_JSON : out Unbounded_String;
         Observed_State_JSON   : out Unbounded_String;
         Outcome               : out Flyology_TLA.Replay.Adapter_Outcome)
      is
         Input          : constant String := To_String (Command.Input_JSON);
         Transaction    : constant Integer :=
           Integer
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member
                   (Input, "transaction", Limits)));
         Source_Account : constant Positive :=
           Positive
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member (Input, "source", Limits)));
         Target_Account : constant Positive :=
           Positive
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member
                   (Input, "destination", Limits)));
         Value          : constant Positive :=
           Positive
             (Flyology_TLA.Codecs.Decode_Integer
                (Flyology_TLA.Codecs.Object_Member (Input, "amount", Limits)));
         Applied        : Boolean := False;
         Error_Text     : Unbounded_String;
      begin
         if Self.First_Observation then
            Self.First_Observation := False;
         else
            Append (Self.Observations, ",");
         end if;
         Append
           (Self.Observations,
            "{""index"":"
            & Counterweave.Strings.Compact_Image
                (Long_Long_Integer (Command.Index))
            & ",""operation"":"
            & Counterweave.Strings.JSON_String (To_String (Command.Action)));

         if To_String (Command.Action) = "TransferLedger!Deposit" then
            Buggy_Transfer_Ledger.Deposit (Self.System, Target_Account, Value);
            Applied := True;
         elsif To_String (Command.Action) = "TransferLedger!Transfer" then
            if To_String (Command.Role) = "duplicate-transfer-retry" then
               Self.Duplicate_Steps := Self.Duplicate_Steps + 1;
            end if;
            begin
               Buggy_Transfer_Ledger.Transfer
                 (Item        => Self.System,
                  Transaction => Transaction,
                  Source      => Source_Account,
                  Destination => Target_Account,
                  Value       => Value,
                  Applied     => Applied);
            exception
               when Buggy_Transfer_Ledger.Insufficient_Funds =>
                  Error_Text := To_Unbounded_String ("insufficient-funds");
            end;
         else
            raise Constraint_Error with "unsupported modeled action";
         end if;

         Observed_Outcome_JSON :=
           To_Unbounded_String
             ("{""applied"":"
              & (if Applied then "true" else "false")
              & ",""error"":"
              & (if Length (Error_Text) = 0
                 then "null"
                 else
                   Counterweave.Strings.JSON_String (To_String (Error_Text)))
              & "}");
         Observed_State_JSON := To_Unbounded_String (State_JSON (Self));
         Append
           (Self.Observations,
            ",""applied"":"
            & (if Applied then "true" else "false")
            & ",""state"":"
            & State_JSON (Self)
            & "}");
         Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
      exception
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
        (Self                  : in out Transfer_Adapter;
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
            if To_String (Command.Role) = "duplicate-transfer-retry" then
               Result.Fingerprint :=
                 To_Unbounded_String ("duplicate-transfer-not-ignored");
               Result.Detail :=
                 To_Unbounded_String
                   ("a repeated transaction changed ledger state");
            else
               Result.Fingerprint :=
                 To_Unbounded_String ("modeled-ledger-state-diverged");
            end if;
         end if;
      end Compare_Step;

   end Implementation;

begin
   if Pack_Name /= "ada-idempotent-transfer" or else Pack_Version /= "1" then
      raise Constraint_Error with "unsupported model pack";
   elsif Declared_Step_Count /= Step_Count
     or else Counterweave.JSON.Length (Source, Transactions) /= Step_Count
     or else Counterweave.JSON.Length (Source, Sources) /= Step_Count
     or else Counterweave.JSON.Length (Source, Destinations) /= Step_Count
     or else Counterweave.JSON.Length (Source, Amounts) /= Step_Count
     or else Counterweave.JSON.Length (Source, Expectations) /= Step_Count
     or else Counterweave.JSON.Length (Source, Balances) /= Step_Count + 1
   then
      raise Constraint_Error
        with "generated step arrays have different lengths";
   end if;

   declare
      Trace      : constant Flyology_TLA.Traces.Trace := Build_Trace;
      Trace_JSON : constant String :=
        Flyology_TLA.Traces.Image (Trace, Natural (Trace.Steps.Length));
      Trace_Hash : constant String := Counterweave.Hashes.SHA256 (Trace_JSON);
      Adapter    : Implementation.Transfer_Adapter;
      Replay     : Flyology_TLA.Replay.Replay_Result;
   begin
      Flyology_TLA.Replay.Run (Adapter, Trace, Limits, Replay);
      Replay.Property_Name := To_Unbounded_String ("transfers-are-idempotent");
      if Replay.Status
         in Flyology_TLA.Replay.Adapter_Error
          | Flyology_TLA.Replay.Invalid_Trace
      then
         raise Constraint_Error with To_String (Replay.Detail);
      end if;
      Append (Adapter.Observations, "]");
      declare
         Observation_Object : constant String :=
           "{""step_count"":"
           & Positive'Image (Step_Count)
           & ",""duplicate_steps"":"
           & Natural'Image (Adapter.Duplicate_Steps)
           & ",""steps"":"
           & To_String (Adapter.Observations)
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
         "idempotent_transfer_adapter: "
         & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Idempotent_Transfer_Adapter;
