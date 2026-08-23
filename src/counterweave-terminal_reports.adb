with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Strings.Wide_Wide_Unbounded;
with Ada.Text_IO;
with Counterweave.Strings;
with Flyology_TUI.Color_Profiles;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Layouts;
with Flyology_TUI.Renderers;
with Flyology_TUI.Surfaces;
with Flyology_TUI.Themes;
with Flyology_TUI.Views;

package body Counterweave.Terminal_Reports is

   use Ada.Strings.Unbounded;
   use type Counterweave.Campaign_UI.Attempt_Outcome;

   Content_Width : constant Positive := 72;

   function Wide (Value : String) return Wide_Wide_String is
      Result : Wide_Wide_String (Value'Range);
   begin
      for Index in Value'Range loop
         Result (Index) :=
           Wide_Wide_Character'Val (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end Wide;

   function Environment_Value (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name)
      else "");

   function Detected_Profile return Flyology_TUI.Color_Profiles.Profile is
     (Flyology_TUI.Color_Profiles.Detect
        (NO_Color_Present => Ada.Environment_Variables.Exists ("NO_COLOR"),
         NO_Color_Value   => Environment_Value ("NO_COLOR"),
         Color_Term       => Environment_Value ("COLORTERM"),
         Term             => Environment_Value ("TERM")));

   function Stack
     (Top, Bottom : Flyology_TUI.Surfaces.Surface;
      Gap         : Natural := 0) return Flyology_TUI.Surfaces.Surface is
     (Flyology_TUI.Layouts.Join_Vertically (Top, Bottom, Gap => Gap));

   function Image (Value : Natural) return String is
     (Counterweave.Strings.Compact_Image (Long_Long_Integer (Value)));

   function Brief (Value : Unbounded_String) return String is
      Limit : constant Positive := 54;
      Last  : constant Natural := Natural'Min (Length (Value), Limit);
   begin
      if Last = 0 then
         return "";
      end if;
      declare
         Result : String := Slice (Value, 1, Last);
      begin
         for Character of Result loop
            if Character in ASCII.LF | ASCII.CR | ASCII.HT then
               Character := ' ';
            end if;
         end loop;
         if Length (Value) > Limit then
            return Result & "...";
         end if;
         return Result;
      end;
   end Brief;

   procedure Render_Search_Result
     (Result           : Counterweave.Campaign_UI.Attempt_Result;
      Attempts         : Natural;
      Maximum_Attempts : Positive;
      Case_Path        : String;
      Run_Path         : String;
      Adapter          : String)
   is
      package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

      Theme : constant Flyology_TUI.Themes.Theme :=
        Flyology_TUI.Themes.Charm;
      Found : constant Boolean :=
        Result.Outcome = Counterweave.Campaign_UI.Found;
      Badge_Label : constant Wide_Wide_String :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found     => "BUG FOUND",
           when Counterweave.Campaign_UI.Passed    => "NO COUNTEREXAMPLE",
           when Counterweave.Campaign_UI.Cancelled => "CANCELLED",
           when Counterweave.Campaign_UI.Errored   => "ERROR");
      Badge_Tone : constant Flyology_TUI.Components.Indicators.Tone :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found =>
             Flyology_TUI.Components.Indicators.Success_Tone,
           when Counterweave.Campaign_UI.Passed =>
             Flyology_TUI.Components.Indicators.Warning_Tone,
           when others => Flyology_TUI.Components.Indicators.Error_Tone);
      Verdict : constant String :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found => "PROPERTY VIOLATION",
           when Counterweave.Campaign_UI.Passed => "BOUND EXHAUSTED",
           when Counterweave.Campaign_UI.Cancelled => "SEARCH CANCELLED",
           when Counterweave.Campaign_UI.Errored => "INFRASTRUCTURE ERROR");
      Heading : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Horizontally
          (Flyology_TUI.Surfaces.From_Text
             ("COUNTERWEAVE / SEARCH REPORT",
              Flyology_TUI.Themes.Charm_Palette.Title),
           Flyology_TUI.Components.Indicators.Badge
             (Badge_Label, Badge_Tone, Theme),
           Gap => 2);
      Divider : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Divider
          (Content_Width, "RESULT", Theme);
      Verdict_Row : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("verdict", Wide (Verdict), Content_Width, Theme);
      Trial_Row : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("constraint-valid trials",
           Wide (Image (Attempts) & " / " & Image (Maximum_Attempts)),
           Content_Width,
           Theme);
      Seed_Row : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("counterexample seed",
           Wide
             (if Attempts = 0
              then "none"
              else Counterweave.Strings.Compact_Image (Result.Seed)),
           Content_Width,
           Theme);
      Detail_Row : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("detail", Wide (Brief (Result.Detail)), Content_Width, Theme);
      Metrics : constant Flyology_TUI.Surfaces.Surface :=
        Stack (Verdict_Row, Stack (Trial_Row, Stack (Seed_Row, Detail_Row)));

      function Evidence return Flyology_TUI.Surfaces.Surface is
      begin
         if not Found then
            return Flyology_TUI.Surfaces.Create (Content_Width, 0);
         end if;
         declare
            Evidence_Divider : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Divider
                (Content_Width, "RETAINED EVIDENCE", Theme);
            Case_Row : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Key_Value
                ("case", Wide (Case_Path), Content_Width, Theme);
            Run_Row : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Key_Value
                ("run", Wide (Run_Path), Content_Width, Theme);
            Replay_Divider : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Divider
                (Content_Width, "EXACT REPLAY", Theme);
            Replay : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Surfaces.From_Text
                (Wide
                   ("bin/counterweave execute"
                    & ASCII.LF
                    & "  --case "
                    & Case_Path
                    & ASCII.LF
                    & "  --adapter "
                    & Adapter
                    & ASCII.LF
                    & "  --output "
                    & Run_Path),
                 Theme.Primary);
         begin
            return
              Stack
                (Evidence_Divider,
                 Stack
                   (Case_Row,
                    Stack
                      (Run_Row,
                       Stack (Replay_Divider, Replay, Gap => 1)),
                    Gap => 1),
                 Gap => 1);
         end;
      end Evidence;

      Footer : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Status_Line
          ([Flyology_TUI.Components.Indicators.Make_Segment
              ("REPLAYABLE", Flyology_TUI.Components.Indicators.High,
               Flyology_TUI.Components.Indicators.Success_Tone),
            Flyology_TUI.Components.Indicators.Make_Segment ("MINIZINC"),
            Flyology_TUI.Components.Indicators.Make_Segment ("ADA ADAPTER")],
           Content_Width,
           Theme);
      Content : constant Flyology_TUI.Surfaces.Surface :=
        Stack
          (Heading,
           Stack
             (Divider,
              Stack
                (Metrics,
                 Stack (Evidence, Footer, Gap => 1),
                 Gap => 1),
              Gap => 1),
           Gap => 1);
      Panel : constant Flyology_TUI.Layouts.Block :=
        (Padding    => (Top => 1, Right => 2, Bottom => 1, Left => 2),
         Border     => Flyology_TUI.Layouts.Rounded,
         Appearance => Theme.Border,
         others     => <>);
      Frame : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Render (Panel, Content);
      View : Flyology_TUI.Views.View :=
        Flyology_TUI.Views.From_Surface (Frame);
      Renderer : Flyology_TUI.Renderers.Renderer;
      Output, Reset : Unbounded_String;
   begin
      View.Bracketed_Paste := False;
      View.Window_Title :=
        Wide_Text.To_Unbounded_Wide_Wide_String ("Counterweave result");
      View.Cursor :=
        (Visible => True,
         X       => 0,
         Y       => Flyology_TUI.Surfaces.Height (Frame) + 1,
         Shape   => Flyology_TUI.Views.Cursor_Block,
         Blink   => False);
      Flyology_TUI.Renderers.Set_Color_Profile (Renderer, Detected_Profile);
      Flyology_TUI.Renderers.Render (Renderer, View, Output);
      Flyology_TUI.Renderers.Reset (Renderer, Reset);
      Ada.Text_IO.Put (To_String (Output));
      Ada.Text_IO.Put (To_String (Reset));
      Ada.Text_IO.New_Line;
   end Render_Search_Result;

end Counterweave.Terminal_Reports;
