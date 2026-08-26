with Ada.Strings.Unbounded;
with Counterweave.Strings;
with Flyology_TLA.Replay;
with Flyology_TLA.Reporting;
with Flyology_TLA.Traces;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Components.Tables;
with Flyology_TUI.Layouts;

package body Counterweave.Trace_Views is

   use Ada.Strings.Unbounded;

   --  Preserve Counterweave's 1 MiB process-output and 4,096-step bounds;
   --  the remaining dimensions follow flyology_tla's reviewed Ada consumer.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_048_576,
      Maximum_Steps        => 4_096,
      Maximum_JSON_Depth   => 64,
      Maximum_Object_Names => 10_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 1_048_576);

   function Wide (Value : String) return Wide_Wide_String is
      Result : Wide_Wide_String (Value'Range);
   begin
      for Index in Value'Range loop
         Result (Index) :=
           Wide_Wide_Character'Val (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end Wide;

   function Matched_Mark return Wide_Wide_String
   is (Wide_Wide_String'(1 => Wide_Wide_Character'Val (16#2713#)));

   function Diverged_Mark return Wide_Wide_String
   is (Wide_Wide_String'(1 => Wide_Wide_Character'Val (16#2260#)));

   function Violated_Mark return Wide_Wide_String
   is (Wide_Wide_String'(1 => Wide_Wide_Character'Val (16#2715#)));

   function Step_Count (Source : String) return Natural is
      Trace : constant Flyology_TLA.Traces.Trace :=
        Flyology_TLA.Traces.Parse (Source, Limits);
   begin
      return Natural (Trace.Steps.Length);
   end Step_Count;

   function Fit (Value : String; Width : Positive) return String is
   begin
      if Value'Length <= Width then
         return Value;
      elsif Width <= 3 then
         return Value (Value'First .. Value'First + Width - 1);
      else
         return Value (Value'First .. Value'First + Width - 4) & "...";
      end if;
   end Fit;

   type Column_Id is
     (Step_Column, Action_Column, Outcome_Column, State_Column);

   type Display_Row is record
      Number  : Positive;
      Step    : Flyology_TLA.Traces.Trace_Step;
      Failure : Boolean := False;
   end record;

   function Id_Of (Item : Display_Row) return Natural
   is (Item.Number);

   function Cell
     (Item : Display_Row; Column : Column_Id) return Wide_Wide_String is
   begin
      case Column is
         when Step_Column    =>
            return
              (if Item.Failure then Violated_Mark else Matched_Mark)
              & " "
              & Wide
                  (Counterweave.Strings.Compact_Image
                     (Long_Long_Integer (Item.Number)));

         when Action_Column  =>
            return Wide (To_String (Item.Step.Action));

         when Outcome_Column =>
            return Wide (To_String (Item.Step.Expected_Outcome_JSON));

         when State_Column   =>
            return Wide (To_String (Item.Step.Expected_State_JSON));
      end case;
   end Cell;

   function Less (Left, Right : Display_Row; Column : Column_Id) return Boolean
   is
      pragma Unreferenced (Column);
   begin
      return Left.Number < Right.Number;
   end Less;

   package Trace_Tables is new
     Flyology_TUI.Components.Tables
       (Item_Type => Display_Row,
        Id_Type   => Natural,
        Column_Id => Column_Id,
        Id_Of     => Id_Of,
        Cell      => Cell,
        Less      => Less,
        Capacity  => 4_096);

   function Render
     (Source             : String;
      Conformance_Source : String;
      Width              : Positive;
      Theme              : Flyology_TUI.Themes.Theme;
      Maximum_Rows       : Positive := 8;
      Compact            : Boolean := False)
      return Flyology_TUI.Surfaces.Surface
   is
      Trace_SHA256  : Unbounded_String;
      Result_SHA256 : Unbounded_String;
      Trace         : constant Flyology_TLA.Traces.Trace :=
        Flyology_TLA.Traces.Parse (Source, Limits, Trace_SHA256);
      Result        : constant Flyology_TLA.Replay.Replay_Result :=
        Flyology_TLA.Reporting.Parse_JSON
          (Conformance_Source, Limits, Result_SHA256);
      Count         : constant Natural := Natural (Trace.Steps.Length);
      Failure       : constant Natural := Result.Failure_Step;
      Last          : constant Natural :=
        (if Failure > 0 then Failure else Natural'Min (Count, Maximum_Rows));
      First         : constant Natural :=
        (if Last <= Maximum_Rows then 1 else Last - Maximum_Rows + 1);

      function Stack
        (Top, Bottom : Flyology_TUI.Surfaces.Surface; Gap : Natural := 0)
         return Flyology_TUI.Surfaces.Surface
      is (Flyology_TUI.Layouts.Join_Vertically (Top, Bottom, Gap => Gap));
   begin
      if Trace_SHA256 /= Result_SHA256 then
         raise Flyology_TLA.Reporting.Result_Error
           with "conformance result does not identify the trace";
      elsif Count = 0 then
         return Flyology_TUI.Surfaces.Create (Width, 0);
      elsif Failure > Count then
         raise Flyology_TLA.Reporting.Result_Error
           with "failure step exceeds the trace";
      end if;

      declare
         Table_Overhead : constant Positive := 5;
         Cell_Width     : constant Positive := Width - Table_Overhead;
         Step_Width     : constant Positive := 5;
         Remaining      : constant Positive := Cell_Width - Step_Width;
         Action_Width   : constant Positive := Remaining / 3;
         Outcome_Width  : constant Positive := (Remaining - Action_Width) / 2;
         State_Width    : constant Positive :=
           Remaining - Action_Width - Outcome_Width;
         Columns        : constant Trace_Tables.Column_Definitions :=
           [Step_Column    =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String ("STEP"),
               Width         => Step_Width,
               Minimum_Width => Step_Width,
               Align         => Trace_Tables.Align_Right,
               Sortable      => False),
            Action_Column  =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("TRANSITION"),
               Width         => Action_Width,
               Minimum_Width => Action_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False),
            Outcome_Column =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("EXPECTED OUTCOME"),
               Width         => Outcome_Width,
               Minimum_Width => Outcome_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False),
            State_Column   =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("MODEL STATE"),
               Width         => State_Width,
               Minimum_Width => State_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False)];
         Values         : Trace_Tables.Item_Array (1 .. Last - First + 1);
      begin
         for Position in Values'Range loop
            declare
               Index : constant Positive := First + Position - 1;
            begin
               Values (Position) :=
                 (Number  => Index,
                  Step    => Trace.Steps (Index),
                  Failure => Index = Failure);
            end;
         end loop;

         declare
            Table : constant Trace_Tables.Model :=
              Trace_Tables.Create
                (Values        => Values,
                 Columns       => Columns,
                 Viewport_Rows => Values'Length,
                 Enabled       => True);
            Rows  : Flyology_TUI.Surfaces.Surface :=
              Trace_Tables.Render (Table, Theme, Has_Focus => False);
         begin
            if First > 1 and then not Compact then
               Rows :=
                 Stack
                   (Flyology_TUI.Surfaces.From_Text
                      (Wide
                         ("setup: steps 1-"
                          & Counterweave.Strings.Compact_Image
                              (Long_Long_Integer (First - 1))
                          & " omitted"),
                       Theme.Muted),
                    Rows);
            end if;
            if Last < Count and then not Compact then
               Rows :=
                 Stack
                   (Rows,
                    Flyology_TUI.Surfaces.From_Text
                      (Wide
                         (Counterweave.Strings.Compact_Image
                            (Long_Long_Integer (Count - Last))
                          & (if Failure = 0
                             then " later replayed steps not shown"
                             else " later modeled steps not replayed")),
                       Theme.Muted));
            end if;

            declare
               Divider : constant Flyology_TUI.Surfaces.Surface :=
                 Flyology_TUI.Components.Indicators.Divider
                   (Width, "CONFORMANCE REPLAY", Theme);
               Details : Flyology_TUI.Surfaces.Surface :=
                 (if Failure = 0
                  then Flyology_TUI.Surfaces.Create (Width, 0)
                  else
                    Flyology_TUI.Surfaces.From_Text
                      (Violated_Mark
                       & " "
                       & Wide
                           (Fit
                              ("DIVERGED | step "
                               & Counterweave.Strings.Compact_Image
                                   (Long_Long_Integer (Failure))
                               & " | "
                               & To_String (Result.Fingerprint),
                               Width - 2)),
                       Theme.Error));
            begin
               if not Compact then
                  Details :=
                    Stack
                      (Details,
                       Flyology_TUI.Components.Indicators.Key_Value
                         ("model",
                          Wide
                            (To_String (Trace.Model.Module_Name)
                             & " / "
                             & To_String (Trace.Model.Configuration)),
                          Width,
                          Theme));
               end if;
               return
                 (if Compact
                  then Stack (Divider, Stack (Rows, Details))
                  else
                    Stack
                      (Divider, Stack (Rows, Details, Gap => 1), Gap => 1));
            end;
         end;
      end;
   end Render;

end Counterweave.Trace_Views;
