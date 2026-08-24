with Ada.Strings.Unbounded;
with Counterweave.Strings;
with Counterweave.Traces;
with Flyology_TUI.Colors;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Components.Tables;
with Flyology_TUI.Layouts;
with Flyology_TUI.Styles;

package body Counterweave.Trace_Views is

   use Ada.Strings.Unbounded;
   use type Counterweave.Traces.Step_Status;

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
   is (Wide_Wide_String'
         (1 => Wide_Wide_Character'Val (16#2713#)));

   function Diverged_Mark return Wide_Wide_String
   is (Wide_Wide_String'
         (1 => Wide_Wide_Character'Val (16#2260#)));

   function Violated_Mark return Wide_Wide_String
   is (Wide_Wide_String'
         (1 => Wide_Wide_Character'Val (16#2715#)));

   function Marker
     (Status : Counterweave.Traces.Step_Status) return Wide_Wide_String
   is (case Status is
         when Counterweave.Traces.Matched  => Matched_Mark,
         when Counterweave.Traces.Diverged => Diverged_Mark,
         when Counterweave.Traces.Violated => Violated_Mark);

   function Step_Count (Source : String) return Natural is
      Trace : constant Counterweave.Traces.Counterexample_Trace :=
        Counterweave.Traces.Parse (Source);
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

   type Column_Id is (Step_Column, Action_Column, Model_Column, Observed_Column);

   type Display_Row is record
      Number : Positive;
      Step   : Counterweave.Traces.Trace_Step;
   end record;

   function Id_Of (Item : Display_Row) return Natural is (Item.Number);

   function Cell
     (Item : Display_Row; Column : Column_Id) return Wide_Wide_String
   is
   begin
      case Column is
         when Step_Column =>
            return
              Marker (Item.Step.Status)
              & " "
              & Wide
                  (Counterweave.Strings.Compact_Image
                     (Long_Long_Integer (Item.Number)));
         when Action_Column =>
            return Wide (To_String (Item.Step.Action));
         when Model_Column =>
            return Wide (To_String (Item.Step.Model));
         when Observed_Column =>
            return Wide (To_String (Item.Step.Observed));
      end case;
   end Cell;

   function Less
     (Left, Right : Display_Row; Column : Column_Id) return Boolean
   is
      pragma Unreferenced (Column);
   begin
      return Left.Number < Right.Number;
   end Less;

   package Trace_Tables is new Flyology_TUI.Components.Tables
     (Item_Type => Display_Row,
      Id_Type   => Natural,
      Column_Id => Column_Id,
      Id_Of     => Id_Of,
      Cell      => Cell,
      Less      => Less,
      Capacity  => 4_096);

   function Render
     (Source       : String;
      Width        : Positive;
      Theme        : Flyology_TUI.Themes.Theme;
      Maximum_Rows : Positive := 8;
      Compact      : Boolean := False) return Flyology_TUI.Surfaces.Surface
   is
      Trace      : constant Counterweave.Traces.Counterexample_Trace :=
        Counterweave.Traces.Parse (Source);
      Count      : constant Natural := Natural (Trace.Steps.Length);
      First      : Natural := 0;
      Last       : Natural := Count - 1;
      Mismatch   : Natural := Natural'Last;
      Violation  : Natural := Natural'Last;
      Warning    : constant Flyology_TUI.Styles.Style :=
        (Foreground => Flyology_TUI.Colors.True_Color (245, 176, 65),
         Bold       => True,
         others     => <>);

      function Stack
        (Top, Bottom : Flyology_TUI.Surfaces.Surface; Gap : Natural := 0)
         return Flyology_TUI.Surfaces.Surface
      is (Flyology_TUI.Layouts.Join_Vertically (Top, Bottom, Gap => Gap));

      function Event_Summary
        (Label : String; Index : Natural) return Flyology_TUI.Surfaces.Surface
      is
         Item : constant Counterweave.Traces.Trace_Step := Trace.Steps (Index);
      begin
         return
           Flyology_TUI.Surfaces.From_Text
             (Marker (Item.Status)
              & " "
              & Wide
                  (Fit
                   (Label
                    & " | step "
                    & Counterweave.Strings.Compact_Image
                        (Long_Long_Integer (Index + 1))
                    & " | "
                    & To_String (Item.Action),
                    Width - 2)),
              (if Item.Status = Counterweave.Traces.Violated
               then Theme.Error
               else Warning));
      end Event_Summary;

      function Event_Explanation
        (Label : String; Index : Natural) return Flyology_TUI.Surfaces.Surface
      is (if Index = Natural'Last
          then Flyology_TUI.Surfaces.Create (Width, 0)
          else Event_Summary (Label, Index));
   begin
      for Index in Trace.Steps.First_Index .. Trace.Steps.Last_Index loop
         if Trace.Steps (Index).Status /= Counterweave.Traces.Matched
           and then Mismatch = Natural'Last
         then
            Mismatch := Index;
         end if;
         if Trace.Steps (Index).Status = Counterweave.Traces.Violated
           and then Violation = Natural'Last
         then
            Violation := Index;
         end if;
      end loop;

      if Mismatch /= Natural'Last then
         First := (if Mismatch = 0 then 0 else Mismatch - 1);
         Last := (if Violation = Natural'Last then Mismatch else Violation);
      end if;
      if Last - First + 1 > Maximum_Rows then
         declare
            End_At : constant Natural := Last;
         begin
            First := End_At - Maximum_Rows + 1;
         end;
      elsif Mismatch = Natural'Last and then Count > Maximum_Rows then
         Last := Maximum_Rows - 1;
      end if;

      declare
         Table_Overhead : constant Positive := 5;
         Cell_Width     : constant Positive := Width - Table_Overhead;
         Step_Width     : constant Positive := 5;
         Remaining      : constant Positive := Cell_Width - Step_Width;
         Action_Width   : constant Positive := Remaining / 3;
         Model_Width    : constant Positive := (Remaining - Action_Width) / 2;
         Observed_Width : constant Positive :=
           Remaining - Action_Width - Model_Width;
         Columns        : constant Trace_Tables.Column_Definitions :=
           [Step_Column     =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String ("STEP"),
               Width         => Step_Width,
               Minimum_Width => Step_Width,
               Align         => Trace_Tables.Align_Right,
               Sortable      => False),
            Action_Column   =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("TRANSITION"),
               Width         => Action_Width,
               Minimum_Width => Action_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False),
            Model_Column    =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("MODEL STATE"),
               Width         => Model_Width,
               Minimum_Width => Model_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False),
            Observed_Column =>
              (Heading       =>
                 Trace_Tables.Text.To_Unbounded_Wide_Wide_String
                   ("ADA STATE"),
               Width         => Observed_Width,
               Minimum_Width => Observed_Width,
               Align         => Trace_Tables.Align_Left,
               Sortable      => False)];
         Values         : Trace_Tables.Item_Array (1 .. Last - First + 1);
      begin
         for Position in Values'Range loop
            declare
               Index : constant Natural := First + Position - 1;
            begin
               Values (Position) :=
                 (Number => Index + 1, Step => Trace.Steps (Index));
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
            if First > 0 and then not Compact then
               Rows :=
                 Stack
                   (Flyology_TUI.Surfaces.From_Text
                      (Wide
                         ("setup: steps 1-"
                          & Counterweave.Strings.Compact_Image
                              (Long_Long_Integer (First))
                          & " omitted"),
                       Theme.Muted),
                    Rows);
            end if;
            if Last + 1 < Count and then not Compact then
               Rows :=
                 Stack
                   (Rows,
                    Flyology_TUI.Surfaces.From_Text
                      (Wide
                         (Counterweave.Strings.Compact_Image
                            (Long_Long_Integer (Count - Last - 1))
                          & " later steps not shown"),
                       Theme.Muted));
            end if;

            declare
               Divider : constant Flyology_TUI.Surfaces.Surface :=
                 Flyology_TUI.Components.Indicators.Divider
                   (Width, "FAILURE PATH", Theme);
               Details : Flyology_TUI.Surfaces.Surface :=
                 (if Mismatch = Violation
                  then Event_Explanation ("PROPERTY FAILS", Violation)
                  else
                    Stack
                      (Event_Explanation ("FIRST MISMATCH", Mismatch),
                       Event_Explanation ("PROPERTY FAILS", Violation)));
            begin
               if not Compact then
                  Details :=
                    Stack
                      (Details,
                       Flyology_TUI.Components.Indicators.Key_Value
                         ("model",
                          Wide (To_String (Trace.Basis)),
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
