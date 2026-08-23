with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Buggy_Transfer_Ledger;
with Counterweave.Adapter_Results;
with Counterweave.JSON;
with Counterweave.Strings;

procedure Idempotent_Transfer_Adapter is

   use Ada.Strings.Unbounded;

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

   Source              : constant String :=
     Counterweave.Strings.Read_File (Case_Path);
   Root                : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Parse (Source);
   Pack                : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "pack");
   Payload             : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "payload");
   Parameters          : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "parameters");
   Solution            : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "solution");
   Operations          : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_operation");
   Transactions        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_transaction");
   Sources             : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_source");
   Destinations        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_destination");
   Amounts             : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_amount");
   Expectations        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_expectation");
   Balances            : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "balance");
   Pack_Name           : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name")));
   Pack_Version        : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version")));
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

   System              :
     Buggy_Transfer_Ledger.Ledger
       (Account_Count => Account_Count, Transaction_Capacity => Step_Count);
   Observations        : Unbounded_String := To_Unbounded_String ("[");
   First_Observation   : Boolean := True;
   Violated            : Boolean := False;
   Failure_Fingerprint : Unbounded_String;
   Duplicate_Steps     : Natural := 0;

   function Integer_At
     (Items : Counterweave.JSON.Value; Index : Natural) return Integer
   is (Integer
         (Counterweave.JSON.As_Integer
            (Source, Counterweave.JSON.Element (Source, Items, Index))));

   function Expected_Balance
     (Step : Natural; Account : Positive) return Natural
   is
      Row : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Element (Source, Balances, Step);
   begin
      return
        Natural
          (Counterweave.JSON.As_Integer
             (Source, Counterweave.JSON.Element (Source, Row, Account - 1)));
   end Expected_Balance;

   procedure Mark_Violation (Fingerprint : String) is
   begin
      if not Violated then
         Failure_Fingerprint := To_Unbounded_String (Fingerprint);
      end if;
      Violated := True;
   end Mark_Violation;

   procedure Begin_Observation (Step : Natural; Operation : String) is
   begin
      if First_Observation then
         First_Observation := False;
      else
         Append (Observations, ",");
      end if;
      Append
        (Observations,
         "{""index"":"
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Step + 1))
         & ",""operation"":"
         & Counterweave.Strings.JSON_String (Operation));
   end Begin_Observation;

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

   Buggy_Transfer_Ledger.Initialize (System, Initial_Balance);
   for Step in 0 .. Step_Count - 1 loop
      declare
         Operation        : constant Integer := Integer_At (Operations, Step);
         Transaction      : constant Integer :=
           Integer_At (Transactions, Step);
         Source_Account   : constant Positive := Integer_At (Sources, Step);
         Target_Account   : constant Positive :=
           Integer_At (Destinations, Step);
         Value            : constant Positive := Integer_At (Amounts, Step);
         Expectation      : constant Integer :=
           Integer_At (Expectations, Step);
         Expected_Applied : constant Boolean := Expectation = 1;
         Actual_Applied   : Boolean := False;
         Raised           : Boolean := False;
      begin
         if Expectation not in 0 .. 1 then
            raise Constraint_Error with "unknown generated expectation";
         end if;
         Begin_Observation
           (Step, (if Operation = 1 then "deposit" else "transfer"));
         if Operation = 1 then
            Buggy_Transfer_Ledger.Deposit (System, Target_Account, Value);
            Actual_Applied := True;
         elsif Operation = 2 and then Transaction > 0 then
            begin
               Buggy_Transfer_Ledger.Transfer
                 (Item        => System,
                  Transaction => Transaction,
                  Source      => Source_Account,
                  Destination => Target_Account,
                  Value       => Value,
                  Applied     => Actual_Applied);
            exception
               when Buggy_Transfer_Ledger.Insufficient_Funds =>
                  Raised := True;
            end;
            if not Expected_Applied then
               Duplicate_Steps := Duplicate_Steps + 1;
            end if;
         else
            raise Constraint_Error with "unknown generated operation";
         end if;

         if Raised or else Actual_Applied /= Expected_Applied then
            if not Expected_Applied then
               Mark_Violation ("duplicate-transfer-not-ignored");
            else
               Mark_Violation ("modeled-ledger-state-diverged");
            end if;
         end if;

         Append
           (Observations,
            ",""transaction"":"
            & Integer'Image (Transaction)
            & ",""source"":"
            & Positive'Image (Source_Account)
            & ",""destination"":"
            & Positive'Image (Target_Account)
            & ",""amount"":"
            & Positive'Image (Value)
            & ",""expected_applied"":"
            & (if Expected_Applied then "true" else "false")
            & ",""actual"":"
            & Counterweave.Strings.JSON_String
                (if Raised
                 then "insufficient-funds"
                 elsif Actual_Applied
                 then "applied"
                 else "ignored"));

         for Account in 1 .. Account_Count loop
            if Buggy_Transfer_Ledger.Balance (System, Account)
              /= Expected_Balance (Step + 1, Account)
            then
               if not Expected_Applied then
                  Mark_Violation ("duplicate-transfer-not-ignored");
               else
                  Mark_Violation ("modeled-ledger-state-diverged");
               end if;
            end if;
         end loop;
         Append (Observations, "}");
      end;
   end loop;
   Append (Observations, "]");

   declare
      Observation_Object : constant String :=
        "{""step_count"":"
        & Positive'Image (Step_Count)
        & ",""duplicate_steps"":"
        & Natural'Image (Duplicate_Steps)
        & ",""steps"":"
        & To_String (Observations)
        & "}";
      Result             :
        constant Counterweave.Adapter_Results.Adapter_Result :=
          (Verdict             =>
             (if Violated
              then Counterweave.Adapter_Results.Property_Violation
              else Counterweave.Adapter_Results.Passed),
           Pack_Name           => To_Unbounded_String (Pack_Name),
           Pack_Version        => To_Unbounded_String (Pack_Version),
           Property_Name       =>
             To_Unbounded_String ("transfers-are-idempotent"),
           Failure_Fingerprint => Failure_Fingerprint,
           Observations_JSON   => To_Unbounded_String (Observation_Object));
   begin
      Ada.Text_IO.Put_Line (Counterweave.Adapter_Results.To_JSON (Result));
   end;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "idempotent_transfer_adapter: "
         & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Idempotent_Transfer_Adapter;
