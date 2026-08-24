with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Strings.Wide_Wide_Unbounded;
with Ada.Text_IO;
with Counterweave.JSON;
with Counterweave.Strings;
with Counterweave.Trace_Views;
with Counterweave.Traces;
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

   function Environment_Value (Name : String) return String
   is (if Ada.Environment_Variables.Exists (Name)
       then Ada.Environment_Variables.Value (Name)
       else "");

   function Detected_Profile return Flyology_TUI.Color_Profiles.Profile
   is (Flyology_TUI.Color_Profiles.Detect
         (NO_Color_Present => Ada.Environment_Variables.Exists ("NO_COLOR"),
          NO_Color_Value   => Environment_Value ("NO_COLOR"),
          Color_Term       => Environment_Value ("COLORTERM"),
          Term             => Environment_Value ("TERM")));

   function Stack
     (Top, Bottom : Flyology_TUI.Surfaces.Surface; Gap : Natural := 0)
      return Flyology_TUI.Surfaces.Surface
   is (Flyology_TUI.Layouts.Join_Vertically (Top, Bottom, Gap => Gap));

   function Image (Value : Natural) return String
   is (Counterweave.Strings.Compact_Image (Long_Long_Integer (Value)));

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

   function Trace_From_Run (Path : String) return Unbounded_String is
   begin
      if not Ada.Directories.Exists (Path) then
         return Null_Unbounded_String;
      end if;
      return
        Counterweave.Traces.Trace_JSON_From_Run
          (Counterweave.Strings.Read_File (Path));
   end Trace_From_Run;

   function Case_Model_Label (Path : String) return String is
      Source     : constant String := Counterweave.Strings.Read_File (Path);
      Root       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Pack       : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "pack");
      Provenance : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "provenance");
      Model      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Provenance, "model");

      function Text
        (Item : Counterweave.JSON.Value; Name : String) return String
      is (To_String
            (Counterweave.JSON.As_String
               (Source, Counterweave.JSON.Member (Source, Item, Name))));

      Hash : constant String := Text (Model, "model_sha256");
   begin
      return
        Text (Pack, "name")
        & "/"
        & Text (Pack, "version")
        & " | "
        & Text (Model, "backend")
        & " "
        & Text (Model, "solver")
        & " | model "
        & (if Hash'Length <= 12
           then Hash
           else Hash (Hash'First .. Hash'First + 11));
   end Case_Model_Label;

   procedure Render_Search_Result
     (Result           : Counterweave.Campaign_UI.Attempt_Result;
      Attempts         : Natural;
      Maximum_Attempts : Positive;
      Root_Seed        : Interfaces.Unsigned_64;
      Campaign_Path    : String;
      Case_Path        : String;
      Run_Path         : String)
   is
      package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

      Theme           : constant Flyology_TUI.Themes.Theme :=
        Flyology_TUI.Themes.Charm;
      Found           : constant Boolean :=
        Result.Outcome = Counterweave.Campaign_UI.Found;
      Badge_Label     : constant Wide_Wide_String :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found     => "BUG FOUND",
           when Counterweave.Campaign_UI.Passed    => "NO COUNTEREXAMPLE",
           when Counterweave.Campaign_UI.Cancelled => "CANCELLED",
           when Counterweave.Campaign_UI.Errored   => "ERROR");
      Badge_Tone      : constant Flyology_TUI.Components.Indicators.Tone :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found  =>
             Flyology_TUI.Components.Indicators.Success_Tone,
           when Counterweave.Campaign_UI.Passed =>
             Flyology_TUI.Components.Indicators.Warning_Tone,
           when others                          =>
             Flyology_TUI.Components.Indicators.Error_Tone);
      Verdict         : constant String :=
        (case Result.Outcome is
           when Counterweave.Campaign_UI.Found     => "PROPERTY VIOLATION",
           when Counterweave.Campaign_UI.Passed    => "BOUND EXHAUSTED",
           when Counterweave.Campaign_UI.Cancelled => "SEARCH CANCELLED",
           when Counterweave.Campaign_UI.Errored   => "INFRASTRUCTURE ERROR");
      Heading         : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Horizontally
          (Flyology_TUI.Surfaces.From_Text
             ("COUNTERWEAVE / SEARCH REPORT",
              Flyology_TUI.Themes.Charm_Palette.Title),
           Flyology_TUI.Components.Indicators.Badge
             (Badge_Label, Badge_Tone, Theme),
           Gap => 2);
      Verdict_Row     : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("verdict", Wide (Verdict), Content_Width, Theme);
      Trial_Row       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("constraint-valid trials",
           Wide (Image (Attempts) & " / " & Image (Maximum_Attempts)),
           Content_Width,
           Theme);
      Campaign_Seed_Row : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("campaign seed",
           Wide (Counterweave.Strings.Compact_Image (Root_Seed)),
           Content_Width,
           Theme);
      Trial_Seed_Row  : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("failing trial seed",
           Wide
             (if Attempts = 0
              then "none"
              else Counterweave.Strings.Compact_Image (Result.Seed)),
           Content_Width,
           Theme);
      Check_Row       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("check",
           Wide
             (if Length (Result.Property_Name) = 0
              then "none"
              else
                To_String (Result.Property_Name)
                & " | "
                & To_String (Result.Failure_Fingerprint)),
           Content_Width,
           Theme);
      Status_Row      : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ((if Found then "model" else "detail"),
           Wide
             (if Found
              then Case_Model_Label (Case_Path)
              else Brief (Result.Detail)),
           Content_Width,
           Theme);
      Metrics         : constant Flyology_TUI.Surfaces.Surface :=
        Stack
          (Verdict_Row,
           Stack
             (Campaign_Seed_Row,
              Stack
                (Trial_Row,
                 Stack
                   (Trial_Seed_Row,
                    Stack (Check_Row, Status_Row)))));
      Trace_JSON      : constant Unbounded_String :=
        (if Found then Trace_From_Run (Run_Path) else Null_Unbounded_String);
      Trace_Surface   : constant Flyology_TUI.Surfaces.Surface :=
        (if Length (Trace_JSON) = 0
         then Flyology_TUI.Surfaces.Create (Content_Width, 0)
         else
           Counterweave.Trace_Views.Render
             (Source       => To_String (Trace_JSON),
              Width        => Content_Width,
              Theme        => Theme,
              Maximum_Rows => 4,
              Compact      => True));

      function Evidence return Flyology_TUI.Surfaces.Surface is
      begin
         if not Found then
            return Flyology_TUI.Surfaces.Create (Content_Width, 0);
         end if;
         declare
            Case_Row     : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Key_Value
                ("case", Wide (Case_Path), Content_Width, Theme);
            Campaign_Row : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Key_Value
                ("campaign", Wide (Campaign_Path), Content_Width, Theme);
            Run_Row      : constant Flyology_TUI.Surfaces.Surface :=
              Flyology_TUI.Components.Indicators.Key_Value
                ("run", Wide (Run_Path), Content_Width, Theme);
         begin
            return
              Stack (Campaign_Row, Stack (Case_Row, Run_Row));
         end;
      end Evidence;

      Footer        : constant Flyology_TUI.Surfaces.Surface :=
        (if Found
         then
           Flyology_TUI.Components.Indicators.Status_Line
             ([Flyology_TUI.Components.Indicators.Make_Segment
                 (Counterweave.Trace_Views.Matched_Mark & " MODEL = ADA",
                  Flyology_TUI.Components.Indicators.High,
                  Flyology_TUI.Components.Indicators.Success_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment
                 (Counterweave.Trace_Views.Diverged_Mark
                  & " FIRST DIFFERENCE",
                  Flyology_TUI.Components.Indicators.Normal,
                  Flyology_TUI.Components.Indicators.Warning_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment
                 (Counterweave.Trace_Views.Violated_Mark
                  & " PROPERTY VIOLATION",
                  Flyology_TUI.Components.Indicators.Normal,
                  Flyology_TUI.Components.Indicators.Error_Tone)],
              Content_Width,
              Theme)
         else
           Flyology_TUI.Components.Indicators.Status_Line
             ([Flyology_TUI.Components.Indicators.Make_Segment
                 ("REPLAYABLE",
                  Flyology_TUI.Components.Indicators.High,
                  Flyology_TUI.Components.Indicators.Success_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment ("MINIZINC"),
               Flyology_TUI.Components.Indicators.Make_Segment
                 ("ADA ADAPTER")],
              Content_Width,
              Theme));
      Content       : constant Flyology_TUI.Surfaces.Surface :=
        Stack
          (Heading,
           Stack
             (Trace_Surface,
              Stack (Metrics, Stack (Evidence, Footer))));
      Panel         : constant Flyology_TUI.Layouts.Block :=
        (Padding    => (Top => 1, Right => 2, Bottom => 1, Left => 2),
         Border     => Flyology_TUI.Layouts.Rounded,
         Appearance => Theme.Border,
         others     => <>);
      Frame         : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Render (Panel, Content);
      View          : Flyology_TUI.Views.View :=
        Flyology_TUI.Views.From_Surface (Frame);
      Renderer      : Flyology_TUI.Renderers.Renderer;
      Output        : Unbounded_String;
   begin
      View.Bracketed_Paste := False;
      View.Window_Title :=
        Wide_Text.To_Unbounded_Wide_Wide_String ("Counterweave result");
      View.Cursor :=
        (Visible => True,
         X       => 0,
         Y       => Flyology_TUI.Surfaces.Height (Frame),
         Shape   => Flyology_TUI.Views.Cursor_Block,
         Blink   => False);
      Flyology_TUI.Renderers.Set_Color_Profile (Renderer, Detected_Profile);
      Flyology_TUI.Renderers.Render (Renderer, View, Output);
      Ada.Text_IO.Put (To_String (Output));
      Ada.Text_IO.New_Line;
   end Render_Search_Result;

   procedure Render_Reduction_Result
     (Update      : Counterweave.Reducers.Reduction_Update;
      Report_Path : String;
      Case_Path   : String;
      Run_Path    : String)
   is
      package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

      Source        : constant String :=
        Counterweave.Strings.Read_File (Report_Path);
      Root          : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Stop_Reason   : constant Wide_Wide_String :=
        Wide
          (To_String
             (Counterweave.JSON.As_String
                (Source,
                 Counterweave.JSON.Member (Source, Root, "stop_reason"))));
      Trace_JSON    : constant Unbounded_String :=
        (if Length (Update.Current_Trace_JSON) > 0
         then Update.Current_Trace_JSON
         else Trace_From_Run (Run_Path));
      Theme         : constant Flyology_TUI.Themes.Theme :=
        Flyology_TUI.Themes.Charm;
      Heading       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Horizontally
          (Flyology_TUI.Surfaces.From_Text
             ("COUNTERWEAVE", Flyology_TUI.Themes.Charm_Palette.Title),
           Flyology_TUI.Components.Indicators.Badge
             ("COUNTEREXAMPLE REDUCED",
              Flyology_TUI.Components.Indicators.Success_Tone,
              Theme),
           Gap => 2);
      Shrink_Row    : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("shrink",
           Wide
             (Image (Update.Accepted)
              & " smaller kept | "
              & Image (Update.Attempt)
              & " candidates | ")
           & Stop_Reason,
           Content_Width,
           Theme);
      Model_Row     : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("model pack",
           Wide
             (if Length (Update.Pack_Label) > 0
              then
                To_String (Update.Pack_Label)
                & " | "
                & To_String (Update.Model_Label)
              else Case_Model_Label (Case_Path)),
           Content_Width,
           Theme);
      Property_Row  : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("property",
           Wide
             (To_String (Update.Property_Name)
              & " | "
              & To_String (Update.Failure_Fingerprint)),
           Content_Width,
           Theme);
      Original_Row  : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("original repro",
           Wide (To_String (Update.Original_Repro)),
           Content_Width,
           Theme);
      Current_Row   : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("reduced repro",
           Wide (To_String (Update.Current_Repro)),
           Content_Width,
           Theme);
      Trace_Surface : constant Flyology_TUI.Surfaces.Surface :=
        (if Length (Trace_JSON) = 0
         then Flyology_TUI.Surfaces.Create (Content_Width, 0)
         else
           Counterweave.Trace_Views.Render
             (Source       => To_String (Trace_JSON),
              Width        => Content_Width,
              Theme        => Theme,
              Maximum_Rows => 4,
              Compact      => True));
      Case_Row      : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("reduced case", Wide (Case_Path), Content_Width, Theme);
      Run_Row       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("reduced run", Wide (Run_Path), Content_Width, Theme);
      Report_Row    : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("reduction evidence", Wide (Report_Path), Content_Width, Theme);
      Context       : constant Flyology_TUI.Surfaces.Surface :=
        Stack
          (Model_Row, Stack (Property_Row, Stack (Original_Row, Current_Row)));
      Evidence      : constant Flyology_TUI.Surfaces.Surface :=
        Stack (Case_Row, Stack (Run_Row, Report_Row));
      Footer        : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Status_Line
          ([Flyology_TUI.Components.Indicators.Make_Segment
              ("FINGERPRINT PRESERVED",
               Flyology_TUI.Components.Indicators.High,
               Flyology_TUI.Components.Indicators.Success_Tone),
            Flyology_TUI.Components.Indicators.Make_Segment ("SYSTEM-VALID"),
            Flyology_TUI.Components.Indicators.Make_Segment ("REPLAYABLE")],
           Content_Width,
           Theme);
      Content       : constant Flyology_TUI.Surfaces.Surface :=
        Stack
          (Heading,
           Stack
             (Trace_Surface,
              Stack
                (Context,
                 Stack (Shrink_Row, Stack (Evidence, Footer)))));
      Panel         : constant Flyology_TUI.Layouts.Block :=
        (Padding    => (Top => 1, Right => 2, Bottom => 1, Left => 2),
         Border     => Flyology_TUI.Layouts.Rounded,
         Appearance => Theme.Border,
         others     => <>);
      Frame         : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Render (Panel, Content);
      View          : Flyology_TUI.Views.View :=
        Flyology_TUI.Views.From_Surface (Frame);
      Renderer      : Flyology_TUI.Renderers.Renderer;
      Output        : Unbounded_String;
   begin
      View.Bracketed_Paste := False;
      View.Window_Title :=
        Wide_Text.To_Unbounded_Wide_Wide_String
          ("Counterweave reduction result");
      View.Cursor :=
        (Visible => True,
         X       => 0,
         Y       => Flyology_TUI.Surfaces.Height (Frame),
         Shape   => Flyology_TUI.Views.Cursor_Block,
         Blink   => False);
      Flyology_TUI.Renderers.Set_Color_Profile (Renderer, Detected_Profile);
      Flyology_TUI.Renderers.Render (Renderer, View, Output);
      Ada.Text_IO.Put (To_String (Output));
      Ada.Text_IO.New_Line;
   end Render_Reduction_Result;

end Counterweave.Terminal_Reports;
