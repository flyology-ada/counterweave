with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Buggy_Handle_Pool;
with Counterweave.JSON;
with Counterweave.Strings;

procedure Stale_Handle_Adapter is

   use Ada.Strings.Unbounded;

   function Case_Path return String is
   begin
      if Ada.Command_Line.Argument_Count = 2
        and then Ada.Command_Line.Argument (1) = "--case"
      then
         return Ada.Command_Line.Argument (2);
      end if;
      raise Constraint_Error with "usage: stale_handle_adapter --case PATH";
   end Case_Path;

   Source       : constant String := Counterweave.Strings.Read_File (Case_Path);
   Root         : constant Counterweave.JSON.Value := Counterweave.JSON.Parse (Source);
   Pack         : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "pack");
   Payload      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Root, "payload");
   Parameters   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "parameters");
   Solution     : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Payload, "solution");
   Operations   : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_operation");
   Handles      : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_handle");
   Values       : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_value");
   Expectations : constant Counterweave.JSON.Value :=
     Counterweave.JSON.Member (Source, Solution, "step_expectation");
   Pack_Name    : constant String :=
     To_String
       (Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Pack, "name")));
   Capacity     : constant Buggy_Handle_Pool.Slot_Number :=
     Buggy_Handle_Pool.Slot_Number
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "capacity")));
   Scenario     : constant Integer :=
     Integer
       (Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Parameters, "scenario")));
   Step_Count   : constant Natural := Counterweave.JSON.Length (Source, Operations);

   type Handle_State is record
      Bound : Boolean := False;
      Value : Buggy_Handle_Pool.Handle;
   end record;

   type Handle_Table is array (Positive range 1 .. 2) of Handle_State;

   Container           : Buggy_Handle_Pool.Pool (Capacity);
   Bound_Handles       : Handle_Table;
   Observations        : Unbounded_String := To_Unbounded_String ("[");
   First_Observation   : Boolean := True;
   Failed              : Boolean := False;
   Expected_Stale      : Boolean := False;
   Stale_Read_Accepted : Boolean := False;
   Observed_Value      : Integer := 0;

   function Integer_At
     (Items : Counterweave.JSON.Value;
      Index : Natural) return Integer
   is
     (Integer
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

   function Operation_Name (Operation : Integer) return String is
   begin
      case Operation is
         when 1 =>
            return "allocate";
         when 2 =>
            return "write";
         when 3 =>
            return "release";
         when 4 =>
            return "read";
         when others =>
            raise Constraint_Error with "unknown generated operation";
      end case;
   end Operation_Name;

begin
   if Pack_Name /= "ada-stale-handle" then
      raise Constraint_Error with "unsupported model pack: " & Pack_Name;
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
         Operation   : constant Integer := Integer_At (Operations, Index);
         Handle_Id   : constant Positive := Integer_At (Handles, Index);
         Input_Value : constant Integer := Integer_At (Values, Index);
         Expectation : constant Integer := Integer_At (Expectations, Index);
      begin
         if Expectation not in 0 .. 2 then
            raise Constraint_Error with "unknown generated expectation";
         end if;
         Begin_Observation (Index, Operation_Name (Operation));
         begin
            case Operation is
               when 1 =>
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

               when 2 =>
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

               when 3 =>
                  if not Bound_Handles (Handle_Id).Bound then
                     raise Constraint_Error
                       with "release references an unbound handle";
                  end if;
                  Buggy_Handle_Pool.Release
                    (Container, Bound_Handles (Handle_Id).Value);
                  Append (Observations, ",""status"":""ok""");

               when 4 =>
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
               when others =>
                  raise Constraint_Error with "unknown generated operation";
            end case;
            if Expectation /= 0 then
               Failed := True;
            end if;
         exception
            when Buggy_Handle_Pool.Stale_Handle =>
               Append (Observations, ",""status"":""stale""");
               if Expectation /= 1 then
                  Failed := True;
               end if;
            when Buggy_Handle_Pool.Pool_Exhausted =>
               Append (Observations, ",""status"":""pool-exhausted""");
               if Expectation /= 2 then
                  Failed := True;
               end if;
         end;
         Finish_Observation;
      end;
   end loop;
   Append (Observations, "]");

   Ada.Text_IO.Put_Line
     ("{""property"":""released-handles-stay-stale"","
      & """steps"":"
      & To_String (Observations)
      & ","
      & """expected_stale"":"
      & (if Expected_Stale then "true" else "false")
      & ","
      & """scenario"":"
      & Integer'Image (Scenario)
      & ","
      & """stale_read_accepted"":"
      & (if Stale_Read_Accepted then "true" else "false")
      & ","
      & """observed_value"":"
      & Integer'Image (Observed_Value)
      & ","
      & """old_generation"":"
      & Natural'Image (Bound_Handles (1).Value.Generation)
      & ","
      & """new_generation"":"
      & Natural'Image (Bound_Handles (2).Value.Generation)
      & "}");

   if Failed then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "stale_handle_adapter: " & Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Stale_Handle_Adapter;
