with Counterweave.JSON;

package body Counterweave.Traces is

   use Ada.Strings.Unbounded;
   use type Counterweave.JSON.Value_Kind;

   function Image (Status : Step_Status) return String
   is (case Status is
         when Matched  => "match",
         when Diverged => "divergence",
         when Violated => "violation");

   function Parse (Source : String) return Counterexample_Trace is
      Root       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Format     : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "format")));
      Summary    : constant Unbounded_String :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Root, "summary"));
      Basis      : constant Unbounded_String :=
        Counterweave.JSON.As_String
          (Source, Counterweave.JSON.Member (Source, Root, "basis"));
      Step_Nodes : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "steps");
      Result     : Counterexample_Trace;
   begin
      if Counterweave.JSON.Kind (Root) /= Counterweave.JSON.Object_Value
        or else Format /= "counterweave.trace/1"
      then
         raise Trace_Error with "unsupported counterexample trace format";
      elsif Length (Summary) = 0 or else Length (Basis) = 0 then
         raise Trace_Error with "counterexample trace explanation is empty";
      elsif Counterweave.JSON.Kind (Step_Nodes)
        /= Counterweave.JSON.Array_Value
        or else Counterweave.JSON.Length (Source, Step_Nodes) = 0
        or else Counterweave.JSON.Length (Source, Step_Nodes) > 4_096
      then
         raise Trace_Error with "counterexample trace step count is invalid";
      end if;

      Result.Summary := Summary;
      Result.Basis := Basis;
      for Index in 0 .. Counterweave.JSON.Length (Source, Step_Nodes) - 1 loop
         declare
            Node         : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Element (Source, Step_Nodes, Index);
            Role         : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source, Counterweave.JSON.Member (Source, Node, "role"));
            Action       : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source, Counterweave.JSON.Member (Source, Node, "action"));
            Model        : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source, Counterweave.JSON.Member (Source, Node, "model"));
            Observed     : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source, Counterweave.JSON.Member (Source, Node, "observed"));
            Status_Text  : constant String :=
              To_String
                (Counterweave.JSON.As_String
                   (Source,
                    Counterweave.JSON.Member (Source, Node, "status")));
            Model_Source : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source,
                 Counterweave.JSON.Member (Source, Node, "model_source"));
            Status       : Step_Status;
         begin
            if Counterweave.JSON.Kind (Node) /= Counterweave.JSON.Object_Value
              or else Length (Role) = 0
              or else Length (Action) = 0
              or else Length (Model) = 0
              or else Length (Observed) = 0
              or else Length (Model_Source) = 0
            then
               raise Trace_Error
                 with "counterexample trace step is incomplete";
            end if;
            if Status_Text = "match" then
               Status := Matched;
            elsif Status_Text = "divergence" then
               Status := Diverged;
            elsif Status_Text = "violation" then
               Status := Violated;
            else
               raise Trace_Error with "unknown counterexample trace status";
            end if;
            Result.Steps.Append
              (Trace_Step'
                 (Role         => Role,
                  Action       => Action,
                  Model        => Model,
                  Observed     => Observed,
                  Status       => Status,
                  Model_Source => Model_Source));
         end;
      end loop;
      return Result;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Trace_Error with "malformed counterexample trace";
   end Parse;

   function Trace_JSON_From_Run (Source : String) return Unbounded_String is
      Root    : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Format  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, "format")));
      Adapter : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "adapter_result");
   begin
      if Format /= "counterweave.run/2" then
         raise Trace_Error with "unsupported run artifact format";
      elsif Counterweave.JSON.Kind (Adapter) = Counterweave.JSON.Null_Value
        or else not Counterweave.JSON.Has_Member (Source, Adapter, "trace")
      then
         return Null_Unbounded_String;
      end if;
      declare
         Node : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Member (Source, Adapter, "trace");
      begin
         if Counterweave.JSON.Kind (Node) = Counterweave.JSON.Null_Value then
            return Null_Unbounded_String;
         elsif Counterweave.JSON.Kind (Node) /= Counterweave.JSON.Object_Value
         then
            raise Trace_Error with "run artifact trace has invalid type";
         end if;
         declare
            Result : constant Unbounded_String :=
              To_Unbounded_String (Counterweave.JSON.Image (Source, Node));
            Parsed : constant Counterexample_Trace :=
              Parse (To_String (Result));
            pragma Unreferenced (Parsed);
         begin
            return Result;
         end;
      end;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Trace_Error with "malformed run artifact trace";
   end Trace_JSON_From_Run;

end Counterweave.Traces;
