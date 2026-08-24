with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Wide_Wide_Unbounded;
with Ada.Text_IO;
with Counterweave.Processes;
with Counterweave.Strings;
with Flyology_TUI.Application_Events;
with Flyology_TUI.Backends.POSIX;
with Flyology_TUI.Colors;
with Flyology_TUI.Components.Help;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Components.Progress;
with Flyology_TUI.Events;
with Flyology_TUI.Layouts;
with Flyology_TUI.Runners;
with Flyology_TUI.Styles;
with Flyology_TUI.Surfaces;
with Flyology_TUI.Themes;
with Flyology_TUI.Transitions;
with Flyology_TUI.Views;
with Interfaces.C;

package body Counterweave.Campaign_UI is

   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;

   function Isatty (Descriptor : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "isatty";

   function Interactive return Boolean
   is (Isatty (0) = 1
       and then Isatty (1) = 1
       and then (not Ada.Environment_Variables.Exists ("TERM")
                 or else Ada.Environment_Variables.Value ("TERM") /= "dumb"));

   function Wide (Value : String) return Wide_Wide_String is
      Result : Wide_Wide_String (Value'Range);
   begin
      for Index in Value'Range loop
         Result (Index) :=
           Wide_Wide_Character'Val (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end Wide;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Outcome_Image (Value : Attempt_Outcome) return String
   is (case Value is
         when Passed    => "PASS",
         when Found     => "FOUND",
         when Cancelled => "CANCELLED",
         when Errored   => "ERROR");

   package body Runs is

      type Command is new Positive;

      type Model is limited record
         Current    : Natural := 0;
         Width      : Natural := 80;
         Height     : Natural := 24;
         Cancelling : Boolean := False;
         Completed  : Boolean := False;
         Last       : Attempt_Result;
      end record;

      package Events is new Flyology_TUI.Application_Events (Attempt_Result);
      package Transitions is new Flyology_TUI.Transitions (Command);
      package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

      procedure Initialize
        (Item : in out Model; Next : in out Transitions.Transition)
      is
         pragma Unreferenced (Item);
      begin
         Transitions.Run (Next, 1);
      end Initialize;

      procedure Update
        (Item  : in out Model;
         Event : Events.Event;
         Next  : in out Transitions.Transition)
      is
         use type Flyology_TUI.Events.Key_Kind;
         use type Flyology_TUI.Events.Terminal_Event_Kind;
      begin
         case Event.Kind is
            when Events.Application_Message =>
               Item.Current := Event.Application.Attempt;
               Item.Last := Event.Application;
               if Item.Last.Outcome = Passed
                 and then Item.Current < Maximum_Attempts
               then
                  Transitions.Run (Next, Command (Item.Current + 1));
               else
                  Item.Completed := True;
                  Transitions.Quit (Next);
               end if;

            when Events.Terminal_Input      =>
               if Event.Terminal.Kind = Flyology_TUI.Events.Resize then
                  if Event.Terminal.Width >= 48 then
                     Item.Width := Event.Terminal.Width;
                  end if;
                  if Event.Terminal.Height > 0 then
                     Item.Height := Event.Terminal.Height;
                  end if;
               elsif Event.Terminal.Kind = Flyology_TUI.Events.Interrupt then
                  Counterweave.Processes.Request_Cancel;
                  Item.Cancelling := True;
               elsif Event.Terminal.Kind = Flyology_TUI.Events.Key_Press
                 and then Event.Terminal.Key.Kind
                          = Flyology_TUI.Events.Text_Key
               then
                  declare
                     Key : constant Wide_Wide_String :=
                       Wide_Text.To_Wide_Wide_String
                         (Event.Terminal.Key.Value);
                  begin
                     if Key = "q"
                       or else (Key = "c"
                                and then Event.Terminal.Key.Modified.Control)
                     then
                        Counterweave.Processes.Request_Cancel;
                        Item.Cancelling := True;
                     end if;
                  end;
               end if;
         end case;
      end Update;

      function Present (Item : Model) return Flyology_TUI.Views.View is
         Theme           : constant Flyology_TUI.Themes.Theme :=
           Flyology_TUI.Themes.Charm;
         Accent          : constant Flyology_TUI.Styles.Style :=
           Flyology_TUI.Styles.With_Foreground
             (Flyology_TUI.Styles.Default,
              Flyology_TUI.Colors.True_Color (117, 113, 249));
         Track           : constant Flyology_TUI.Styles.Style :=
           Flyology_TUI.Styles.With_Foreground
             (Flyology_TUI.Styles.Default,
              Flyology_TUI.Colors.True_Color (72, 72, 82));
         Available_Width : constant Natural :=
           (if Item.Width > 8 then Item.Width - 8 else Item.Width);
         Content_Width   : constant Positive :=
           Positive (Natural'Max (40, Available_Width));
         Bar_Width       : constant Positive := Content_Width;
         Ratio           : constant Long_Float :=
           Long_Float (Item.Current) / Long_Float (Maximum_Attempts);

         function Render_Progress return Flyology_TUI.Surfaces.Surface is
            Progress_Model : Flyology_TUI.Components.Progress.Model :=
              Flyology_TUI.Components.Progress.Create (Bar_Width, True);
         begin
            Progress_Model.Set
              (Flyology_TUI.Components.Progress.Fraction (Ratio));
            return Progress_Model.Render (Accent, Track);
         end Render_Progress;

         function Display_Detail return String is
            Limit : constant Positive :=
              Positive (Natural'Max (16, Content_Width / 2));
            Last  : constant Natural :=
              Natural'Min (Length (Item.Last.Detail), Limit);
         begin
            if Last = 0 then
               return "";
            end if;
            declare
               Result : String := Slice (Item.Last.Detail, 1, Last);
            begin
               for Character of Result loop
                  if Character in ASCII.LF | ASCII.CR | ASCII.HT then
                     Character := ' ';
                  end if;
               end loop;
               if Length (Item.Last.Detail) > Limit then
                  return Result & "...";
               end if;
               return Result;
            end;
         end Display_Detail;

         Badge_Tone  : constant Flyology_TUI.Components.Indicators.Tone :=
           (if Item.Cancelling
              or else (Item.Current > 0 and then Item.Last.Outcome = Errored)
            then Flyology_TUI.Components.Indicators.Error_Tone
            elsif Item.Current > 0 and then Item.Last.Outcome = Found
            then Flyology_TUI.Components.Indicators.Success_Tone
            else Flyology_TUI.Components.Indicators.Warning_Tone);
         Badge_Label : constant Wide_Wide_String :=
           (if Item.Cancelling
            then "CANCELLING"
            elsif Item.Current > 0 and then Item.Last.Outcome = Found
            then "BUG FOUND"
            elsif Item.Current > 0 and then Item.Last.Outcome = Errored
            then "ERROR"
            else "SEARCHING");
         Heading     : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Layouts.Join_Horizontally
             (Flyology_TUI.Surfaces.From_Text
                ("COUNTERWEAVE", Flyology_TUI.Themes.Charm_Palette.Title),
              Flyology_TUI.Components.Indicators.Badge
                (Badge_Label, Badge_Tone, Theme),
              Gap => 2);
         Purpose     : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Surfaces.From_Text (Wide (Title), Theme.Muted);
         Divider     : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Divider
             (Content_Width, "SYSTEM-VALID EXPLORATION", Theme);
         Trial_Row   : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Key_Value
             ("completed trials",
              Wide (Image (Item.Current) & " / " & Image (Maximum_Attempts)),
              Content_Width,
              Theme);
         Campaign_Seed_Row : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Key_Value
             ("campaign seed",
              Wide (Counterweave.Strings.Compact_Image (Root_Seed)),
              Content_Width,
              Theme);
         Trial_Seed_Row : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Key_Value
             ("current trial seed",
              Wide
                (if Item.Current = 0
                 then "pending"
                 else Counterweave.Strings.Compact_Image (Item.Last.Seed)),
              Content_Width,
              Theme);
         Result_Row  : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Key_Value
             ("last property result",
              Wide
                (if Item.Current = 0
                 then "waiting"
                 else
                   Outcome_Image (Item.Last.Outcome) & " | " & Display_Detail),
              Content_Width,
              Theme);
         Metrics     : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Layouts.Join_Vertically
             (Campaign_Seed_Row,
              Flyology_TUI.Layouts.Join_Vertically
                (Trial_Row,
                 Flyology_TUI.Layouts.Join_Vertically
                   (Trial_Seed_Row, Result_Row)));
         Help        : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Help.Render
             ([(Key         => Wide_Text.To_Unbounded_Wide_Wide_String ("q"),
                Description =>
                  Wide_Text.To_Unbounded_Wide_Wide_String
                    ("cancel active trial"),
                Enabled     => True),
               (Key         =>
                  Wide_Text.To_Unbounded_Wide_Wide_String ("Ctrl-C"),
                Description =>
                  Wide_Text.To_Unbounded_Wide_Wide_String
                    ("cancel and retain prior evidence"),
                Enabled     => True)],
              Width    => Content_Width,
              Theme    => Theme,
              Vertical => False);
         Footer      : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Components.Indicators.Status_Line
             ([Flyology_TUI.Components.Indicators.Make_Segment
                 ("CONSTRAINED",
                  Flyology_TUI.Components.Indicators.High,
                  Flyology_TUI.Components.Indicators.Success_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment
                 ("REPLAYABLE FORKS"),
               Flyology_TUI.Components.Indicators.Make_Segment
                 ("ADA ADAPTER")],
              Content_Width,
              Theme);
         Content     : constant Flyology_TUI.Surfaces.Surface :=
           Flyology_TUI.Layouts.Join_Vertically
             (Heading,
              Flyology_TUI.Layouts.Join_Vertically
                (Purpose,
                 Flyology_TUI.Layouts.Join_Vertically
                   (Divider,
                    Flyology_TUI.Layouts.Join_Vertically
                      (Render_Progress,
                       Flyology_TUI.Layouts.Join_Vertically
                         (Metrics,
                          Flyology_TUI.Layouts.Join_Vertically
                            (Help, Footer, Gap => 1),
                          Gap => 1),
                       Gap => 1),
                    Gap => 1),
                 Gap => 1),
              Gap => 1);
         Panel       : constant Flyology_TUI.Layouts.Block :=
           (Padding    => (Top => 1, Right => 2, Bottom => 1, Left => 2),
            Border     => Flyology_TUI.Layouts.Rounded,
            Appearance => Theme.Border,
            others     => <>);
         Result      : Flyology_TUI.Views.View :=
           Flyology_TUI.Views.From_Surface
             (Flyology_TUI.Layouts.Render (Panel, Content));
      begin
         Result.Alternate_Screen := True;
         Result.Window_Title :=
           Wide_Text.To_Unbounded_Wide_Wide_String ("Counterweave search");
         return Result;
      end Present;

      procedure Execute
        (Item : Command; Result : out Attempt_Result; Produced : out Boolean)
      is
      begin
         Attempt (Positive (Item), Result);
         Result.Attempt := Natural (Item);
         Produced := True;
      exception
         when Error : others =>
            Result :=
              (Outcome             => Errored,
               Attempt             => Natural (Item),
               Seed                => 0,
               Detail              =>
                 To_Unbounded_String
                   (Ada.Exceptions.Exception_Information (Error)),
               Property_Name       => Null_Unbounded_String,
               Failure_Fingerprint => Null_Unbounded_String);
            Produced := True;
      end Execute;

      package Runtime is new
        Flyology_TUI.Runners
          (Events      => Events,
           Transitions => Transitions,
           Model_Type  => Model,
           Initialize  => Initialize,
           Update      => Update,
           Present     => Present,
           Execute     => Execute);

      procedure Run (Final_Result : out Attempt_Result; Attempts : out Natural)
      is
      begin
         if Interactive then
            declare
               State    : Model;
               Terminal : Flyology_TUI.Backends.POSIX.POSIX_Backend;
            begin
               Runtime.Run (State, Terminal);
               Attempts := State.Current;
               if State.Completed then
                  Final_Result := State.Last;
               else
                  Final_Result :=
                    (Outcome             => Errored,
                     Attempt             => State.Current,
                     Seed                => 0,
                     Detail              =>
                       To_Unbounded_String
                         ("interactive runner stopped before completion"),
                     Property_Name       => Null_Unbounded_String,
                     Failure_Fingerprint => Null_Unbounded_String);
               end if;
            end;
         else
            Attempts := 0;
            for Index in 1 .. Maximum_Attempts loop
               declare
                  Produced : Boolean;
               begin
                  Execute (Command (Index), Final_Result, Produced);
                  pragma Assert (Produced);
               end;
               Attempts := Index;
               Ada.Text_IO.Put_Line
                 ("trial "
                  & Image (Index)
                  & "/"
                  & Image (Maximum_Attempts)
                  & " seed="
                  & Counterweave.Strings.Compact_Image (Final_Result.Seed)
                  & " "
                  & Outcome_Image (Final_Result.Outcome));
               exit when Final_Result.Outcome /= Passed;
            end loop;
         end if;
      end Run;

   end Runs;

end Counterweave.Campaign_UI;
