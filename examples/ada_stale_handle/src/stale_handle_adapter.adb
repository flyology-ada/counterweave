with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Buggy_Handle_Pool;
with Counterweave.Adapter_Results;
with Counterweave.JSON;
with Counterweave.Strings;
with Counterweave.Traces;

procedure Stale_Handle_Adapter is

   use Ada.Strings.Unbounded;
   use type Counterweave.Traces.Step_Status;

   function Case_Path return String is
   begin
      if Ada.Command_Line.Argument_Count = 2
        and then Ada.Command_Line.Argument (1) = "--case"
      then
         return Ada.Command_Line.Argument (2);
      end if;
      raise Constraint_Error with "usage: stale_handle_adapter --case PATH";
   end Case_Path;

   Source         : constant String :=
     Counterweave.Strings.Read_File (Case_Path);
   Root           : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Parse (Source);
   Pack           : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "pack");
   Payload        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "payload");
   Parameters     : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "parameters");
   Solution       : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "solution");
   Operations     : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_operation");
   Handles        : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_handle");
   Values         : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_value");
   Expectations   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_expectation");
   Pack_Name      : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name")));
   Pack_Version   : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "version")));
   Capacity       : constant Buggy_Handle_Pool.Slot_Number :=
     Buggy_Handle_Pool.Slot_Number
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "capacity")));
   Old_Value      : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "old_value")));
   New_Value      : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "new_value")));
   History_Shape  : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Parameters, "history_shape")));
   Scenario       : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "scenario")));
   Step_Count     : constant Natural :=
     Counterweave.JSON.Length (Source, Operations);
   Old_Slot       : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Solution, "old_slot")));
   New_Slot       : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Solution, "new_slot")));
   Old_Generation : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Solution, "old_generation")));
   New_Generation : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source,
           Counterweave.JSON.Member (Source, Solution, "new_generation")));

   type Handle_State is record
      Bound : Boolean := False;
      Value : Buggy_Handle_Pool.Handle;
   end record;

   type Handle_Table is array (Positive range 1 .. 4) of Handle_State;

   Container           : Buggy_Handle_Pool.Pool (Capacity);
   Bound_Handles       : Handle_Table;
   Observations        : Unbounded_String := To_Unbounded_String ("[");
   Trace_Steps         : Unbounded_String := To_Unbounded_String ("[");
   First_Observation   : Boolean := True;
   First_Trace_Step    : Boolean := True;
   Failed              : Boolean := False;
   Expected_Stale      : Boolean := False;
   Stale_Read_Accepted : Boolean := False;
   Observed_Value      : Integer := 0;

   function Integer_At
     (Items : Counterweave.JSON.Value; Index : Natural) return Integer
   is (Integer
         (Counterweave.JSON.As_Integer
            (Source, Counterweave.JSON.Element (Source, Items, Index))));

   procedure Begin_Observation (Index : Natural; Operation : String) is
   begin
      if First_Observation then
         First_Observation := False;
      else
         Append (Observations, ",");
      end if;
      Append
        (Observations,
         "{""index"":"
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index + 1))
         & ",""operation"":"
         & Counterweave.Strings.JSON_String (Operation));
   end Begin_Observation;

   procedure Finish_Observation is
   begin
      Append (Observations, "}");
   end Finish_Observation;

   procedure Append_Trace_Step
     (Role         : String;
      Action       : String;
      Model        : String;
      Observed     : String;
      Status       : Counterweave.Traces.Step_Status;
      Model_Source : String) is
   begin
      if First_Trace_Step then
         First_Trace_Step := False;
      else
         Append (Trace_Steps, ",");
      end if;
      Append
        (Trace_Steps,
         "{""role"":"
         & Counterweave.Strings.JSON_String (Role)
         & ",""action"":"
         & Counterweave.Strings.JSON_String (Action)
         & ",""model"":"
         & Counterweave.Strings.JSON_String (Model)
         & ",""observed"":"
         & Counterweave.Strings.JSON_String (Observed)
         & ",""status"":"
         & Counterweave.Strings.JSON_String
             (Counterweave.Traces.Image (Status))
         & ",""model_source"":"
         & Counterweave.Strings.JSON_String (Model_Source)
         & "}");
   end Append_Trace_Step;

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

   function Model_Source_Name
     (Index, Operation, Handle_Id, Expectation : Integer) return String
   is (if Expectation = 1
       then
         "expected_stale, step_expectation["
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index + 1))
         & "]"
       elsif Operation = 1 and then Handle_Id = 1
       then "generation[1], old_generation"
       elsif Operation = 1 and then Handle_Id = 4
       then
         "generation["
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index + 1))
         & "], new_generation"
       else
         "step_operation["
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index + 1))
         & "], step_expectation["
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index + 1))
         & "]");

   function Operation_Name (Operation : Integer) return String is
   begin
      case Operation is
         when 1      =>
            return "allocate";

         when 2      =>
            return "write";

         when 3      =>
            return "release";

         when 4      =>
            return "read";

         when others =>
            raise Constraint_Error with "unknown generated operation";
      end case;
   end Operation_Name;

begin
   if Pack_Name /= "ada-stale-handle" or else Pack_Version /= "1" then
      raise Constraint_Error
        with "unsupported model pack: " & Pack_Name & "/" & Pack_Version;
   elsif Counterweave.JSON.Length (Source, Handles) /= Step_Count
     or else Counterweave.JSON.Length (Source, Values) /= Step_Count
     or else Counterweave.JSON.Length (Source, Expectations) /= Step_Count
   then
      raise Constraint_Error with "step arrays have different lengths";
   end if;

   Buggy_Handle_Pool.Initialize (Container);
   for Index in 0 .. Step_Count loop
      exit when Index = Step_Count;
      declare
         Operation    : constant Integer := Integer_At (Operations, Index);
         Handle_Id    : constant Positive := Integer_At (Handles, Index);
         Input_Value  : constant Integer := Integer_At (Values, Index);
         Expectation  : constant Integer := Integer_At (Expectations, Index);
         Action       : Unbounded_String;
         Model_Result : Unbounded_String;
         Actual       : Unbounded_String;
         Trace_Status : Counterweave.Traces.Step_Status :=
           Counterweave.Traces.Matched;
      begin
         if Expectation not in 0 .. 2 then
            raise Constraint_Error with "unknown generated expectation";
         end if;
         Begin_Observation (Index, Operation_Name (Operation));
         case Operation is
            when 1      =>
               Action :=
                 To_Unbounded_String
                   ("allocate h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id)));
               Model_Result :=
                 To_Unbounded_String
                   ("h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id))
                    & ": slot "
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer
                           (if Handle_Id = 1 then Old_Slot else New_Slot))
                    & ", gen "
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer
                           (if Handle_Id = 1
                            then Old_Generation
                            elsif Handle_Id = 4
                            then New_Generation
                            else Handle_Id)));

            when 2      =>
               Action :=
                 To_Unbounded_String
                   ("write h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id))
                    & " = "
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Input_Value)));
               Model_Result :=
                 To_Unbounded_String
                   ("slot 1 contains "
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Input_Value)));

            when 3      =>
               Action :=
                 To_Unbounded_String
                   ("release h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id)));
               Model_Result :=
                 To_Unbounded_String
                   ("h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id))
                    & " becomes stale");

            when 4      =>
               Action :=
                 To_Unbounded_String
                   ("read h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id)));
               Model_Result :=
                 To_Unbounded_String
                   (if Expectation = 1
                    then
                      "stale h"
                      & Counterweave.Strings.Compact_Image
                          (Long_Long_Integer (Handle_Id))
                      & " rejected"
                    else
                      "returned "
                      & Counterweave.Strings.Compact_Image
                          (Long_Long_Integer
                             (if Handle_Id = 4
                              then New_Value
                              else Old_Value)));

            when others =>
               null;
         end case;
         begin
            case Operation is
               when 1      =>
                  Bound_Handles (Handle_Id) :=
                    (Bound => True,
                     Value => Buggy_Handle_Pool.Allocate (Container));
                  Append
                    (Observations,
                     ",""status"":""ok"",""handle"":{""slot"":"
                     & Buggy_Handle_Pool.Slot_Number'Image
                         (Bound_Handles (Handle_Id).Value.Slot)
                     & ",""generation"":"
                     & Natural'Image
                         (Bound_Handles (Handle_Id).Value.Generation)
                     & "}");
                  Actual :=
                    To_Unbounded_String
                      ("h"
                       & Counterweave.Strings.Compact_Image
                           (Long_Long_Integer (Handle_Id))
                       & ": slot "
                       & Counterweave.Strings.Compact_Image
                           (Long_Long_Integer
                              (Bound_Handles (Handle_Id).Value.Slot))
                       & ", gen "
                       & Counterweave.Strings.Compact_Image
                           (Long_Long_Integer
                              (Bound_Handles (Handle_Id).Value.Generation)));
                  if Actual /= Model_Result then
                     Trace_Status := Counterweave.Traces.Diverged;
                  end if;

               when 2      =>
                  if not Bound_Handles (Handle_Id).Bound then
                     raise Constraint_Error
                       with "write references an unbound handle";
                  end if;
                  Buggy_Handle_Pool.Write
                    (Container, Bound_Handles (Handle_Id).Value, Input_Value);
                  Append
                    (Observations,
                     ",""status"":""ok"",""value"":"
                     & Integer'Image (Input_Value));
                  Actual := Model_Result;

               when 3      =>
                  if not Bound_Handles (Handle_Id).Bound then
                     raise Constraint_Error
                       with "release references an unbound handle";
                  end if;
                  Buggy_Handle_Pool.Release
                    (Container, Bound_Handles (Handle_Id).Value);
                  Append (Observations, ",""status"":""ok""");
                  Actual := Model_Result;

               when 4      =>
                  if not Bound_Handles (Handle_Id).Bound then
                     raise Constraint_Error
                       with "read references an unbound handle";
                  end if;
                  Expected_Stale := Expectation = 1;
                  Observed_Value :=
                    Buggy_Handle_Pool.Read
                      (Container, Bound_Handles (Handle_Id).Value);
                  Stale_Read_Accepted := Expected_Stale;
                  Append
                    (Observations,
                     ",""status"":""ok"",""value"":"
                     & Integer'Image (Observed_Value));
                  Actual :=
                    To_Unbounded_String
                      ((if Expectation = 1
                        then
                          "stale h"
                          & Counterweave.Strings.Compact_Image
                              (Long_Long_Integer (Handle_Id))
                          & " returned "
                        else "returned ")
                       & Counterweave.Strings.Compact_Image
                           (Long_Long_Integer (Observed_Value)));
                  if Expectation /= 0 then
                     Trace_Status := Counterweave.Traces.Violated;
                  end if;

               when others =>
                  raise Constraint_Error with "unknown generated operation";
            end case;
            if Trace_Status = Counterweave.Traces.Matched
              and then Actual /= Model_Result
            then
               Trace_Status := Counterweave.Traces.Diverged;
            end if;
            if Expectation /= 0 then
               Failed := True;
            end if;
         exception
            when Buggy_Handle_Pool.Stale_Handle =>
               Append (Observations, ",""status"":""stale""");
               Actual :=
                 To_Unbounded_String
                   ("stale h"
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Handle_Id))
                    & " rejected");
               if Expectation /= 1 then
                  Failed := True;
                  Trace_Status := Counterweave.Traces.Violated;
               end if;
            when Buggy_Handle_Pool.Pool_Exhausted =>
               Append (Observations, ",""status"":""pool-exhausted""");
               Actual := To_Unbounded_String ("pool exhausted");
               if Expectation /= 2 then
                  Failed := True;
                  Trace_Status := Counterweave.Traces.Violated;
               end if;
         end;
         Append_Trace_Step
           (Role         => Role_Name (Operation, Handle_Id, Expectation),
            Action       => To_String (Action),
            Model        => To_String (Model_Result),
            Observed     => To_String (Actual),
            Status       => Trace_Status,
            Model_Source =>
              Model_Source_Name
                (Index, Operation, Handle_Id, Expectation));
         Finish_Observation;
      end;
   end loop;
   Append (Observations, "]");
   Append (Trace_Steps, "]");

   declare
      Observation_Object : constant String :=
        "{""steps"":"
        & To_String (Observations)
        & ",""expected_stale"":"
        & (if Expected_Stale then "true" else "false")
        & ",""scenario"":"
        & Integer'Image (Scenario)
        & ",""history_shape"":"
        & Integer'Image (History_Shape)
        & ",""stale_read_accepted"":"
        & (if Stale_Read_Accepted then "true" else "false")
        & ",""observed_value"":"
        & Integer'Image (Observed_Value)
        & ",""old_generation"":"
        & Natural'Image (Bound_Handles (1).Value.Generation)
        & ",""new_generation"":"
        & Natural'Image (Bound_Handles (4).Value.Generation)
        & ",""modeled_new_generation"":"
        & Integer'Image (New_Generation)
        & "}";
      Trace_Object       : constant String :=
        "{""format"":""counterweave.trace/1"",""summary"":"
        & Counterweave.Strings.JSON_String
            ("capacity "
             & Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (Capacity))
             & " | old "
             & Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (Old_Value))
             & " | new "
             & Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (New_Value))
             & " | "
             & Counterweave.Strings.Compact_Image
                 (Long_Long_Integer (Step_Count))
             & " steps")
        & ",""basis"":"
        & Counterweave.Strings.JSON_String
            ("every allocation advances generation; released h1 stays stale")
        & ",""steps"":"
        & To_String (Trace_Steps)
        & "}";
      Result             :
        constant Counterweave.Adapter_Results.Adapter_Result :=
          (Verdict             =>
             (if Failed
              then Counterweave.Adapter_Results.Property_Violation
              else Counterweave.Adapter_Results.Passed),
           Pack_Name           => To_Unbounded_String (Pack_Name),
           Pack_Version        => To_Unbounded_String (Pack_Version),
           Property_Name       =>
             To_Unbounded_String ("released-handles-stay-stale"),
           Failure_Fingerprint =>
             (if Failed
              then To_Unbounded_String ("stale-read-accepted")
              else Null_Unbounded_String),
           Observations_JSON   => To_Unbounded_String (Observation_Object),
           Trace_JSON          => To_Unbounded_String (Trace_Object));
   begin
      Ada.Text_IO.Put_Line (Counterweave.Adapter_Results.To_JSON (Result));
   end;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "stale_handle_adapter: " & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Stale_Handle_Adapter;
