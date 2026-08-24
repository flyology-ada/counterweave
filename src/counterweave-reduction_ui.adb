with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Wide_Wide_Unbounded;
with Counterweave.Processes;
with Counterweave.Strings;
with Counterweave.Trace_Views;
with Flyology_TUI.Backends;
with Flyology_TUI.Backends.POSIX;
with Flyology_TUI.Colors;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Components.Progress;
with Flyology_TUI.Events;
with Flyology_TUI.Layouts;
with Flyology_TUI.Styles;
with Flyology_TUI.Surfaces;
with Flyology_TUI.Themes;
with Flyology_TUI.Views;
with Interfaces.C;

package body Counterweave.Reduction_UI is

   use Ada.Strings.Unbounded;
   use type Counterweave.Reducers.Reduction_Outcome;
   use type Flyology_TUI.Backends.Input_Status;
   use type Flyology_TUI.Events.Key_Kind;
   use type Flyology_TUI.Events.Terminal_Event_Kind;
   use type Interfaces.C.int;
   package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

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
   is (Counterweave.Strings.Compact_Image (Long_Long_Integer (Value)));

   function Humanize (Value : String) return String is
      Result : String := Value;
   begin
      for Character of Result loop
         if Character in '-' | '_' then
            Character := ' ';
         end if;
      end loop;
      return Result;
   end Humanize;

   protected type Progress_State is
      procedure Initialize (Maximum_Attempts : Positive);
      procedure Publish (Update : Counterweave.Reducers.Reduction_Update);
      procedure Request_Stop;
      function Stop_Requested return Boolean;
      procedure Complete (Succeeded : Boolean; Detail : String);
      procedure Snapshot
        (Value     : out Counterweave.Reducers.Reduction_Update;
         Stopping  : out Boolean;
         Completed : out Boolean;
         Succeeded : out Boolean;
         Detail    : out Unbounded_String);
   private
      Last           : Counterweave.Reducers.Reduction_Update;
      Is_Stopping    : Boolean := False;
      Is_Completed   : Boolean := False;
      Was_Successful : Boolean := False;
      Failure_Detail : Unbounded_String;
   end Progress_State;

   protected body Progress_State is
      procedure Initialize (Maximum_Attempts : Positive) is
      begin
         Last.Maximum_Attempts := Maximum_Attempts;
      end Initialize;

      procedure Publish (Update : Counterweave.Reducers.Reduction_Update) is
      begin
         Last := Update;
      end Publish;

      procedure Request_Stop is
      begin
         Is_Stopping := True;
      end Request_Stop;

      function Stop_Requested return Boolean
      is (Is_Stopping);

      procedure Complete (Succeeded : Boolean; Detail : String) is
      begin
         Was_Successful := Succeeded;
         Failure_Detail := To_Unbounded_String (Detail);
         Is_Completed := True;
      end Complete;

      procedure Snapshot
        (Value     : out Counterweave.Reducers.Reduction_Update;
         Stopping  : out Boolean;
         Completed : out Boolean;
         Succeeded : out Boolean;
         Detail    : out Unbounded_String) is
      begin
         Value := Last;
         Stopping := Is_Stopping;
         Completed := Is_Completed;
         Succeeded := Was_Successful;
         Detail := Failure_Detail;
      end Snapshot;
   end Progress_State;

   function Present
     (Item     : Counterweave.Reducers.Reduction_Update;
      Title    : String;
      Case_Path : String;
      Run_Path : String;
      Report_Path : String;
      Width    : Natural;
      Height   : Natural;
      Stopping : Boolean;
      Completed : Boolean;
      Succeeded : Boolean) return Flyology_TUI.Views.View
   is
      Theme           : constant Flyology_TUI.Themes.Theme :=
        Flyology_TUI.Themes.Charm;
      Available_Width : constant Natural :=
        (if Width > 8 then Width - 8 else Width);
      Content_Width   : constant Positive :=
        Positive (Natural'Max (40, Available_Width));
      Compact_Height  : constant Boolean := Height > 0 and then Height < 32;
      Ratio           : constant Long_Float :=
        Long_Float (Natural'Min (Item.Attempt, Item.Maximum_Attempts))
        / Long_Float (Item.Maximum_Attempts);
      Accent          : constant Flyology_TUI.Styles.Style :=
        Flyology_TUI.Styles.With_Foreground
          (Flyology_TUI.Styles.Default,
           Flyology_TUI.Colors.True_Color (255, 92, 205));
      Track           : constant Flyology_TUI.Styles.Style :=
        Flyology_TUI.Styles.With_Foreground
          (Flyology_TUI.Styles.Default,
           Flyology_TUI.Colors.True_Color (72, 72, 82));

      function Render_Progress return Flyology_TUI.Surfaces.Surface is
         Model : Flyology_TUI.Components.Progress.Model :=
           Flyology_TUI.Components.Progress.Create (Content_Width, True);
      begin
         Model.Set (Flyology_TUI.Components.Progress.Fraction (Ratio));
         return Model.Render (Accent, Track);
      end Render_Progress;

      function Current_Size return String
      is (if Item.Outcome = Counterweave.Reducers.Preserved
          then
            Image (Item.Candidate_Forks)
            & " forks / "
            & Image (Item.Candidate_Values)
            & " values"
          else
            Image (Item.Current_Forks)
            & " forks / "
            & Image (Item.Current_Values)
            & " values");

      function Repro_Image (Value : Unbounded_String) return String
      is (if Length (Value) = 0 then Current_Size else To_String (Value));

      function Path_Image return Wide_Wide_String is
         Arrow : constant Wide_Wide_String :=
           Wide_Wide_String'
             (1 => Wide_Wide_Character'Val (16#2192#));
         Original_Steps : constant Natural :=
           (if Length (Item.Original_Trace_JSON) = 0
            then 0
            else
              Counterweave.Trace_Views.Step_Count
                (To_String (Item.Original_Trace_JSON)));
         Current_Steps  : constant Natural :=
           (if Length (Item.Current_Trace_JSON) = 0
            then 0
            else
              Counterweave.Trace_Views.Step_Count
                (To_String (Item.Current_Trace_JSON)));
      begin
         if Original_Steps = 0 or else Current_Steps = 0 then
            return "trace unavailable";
         elsif Current_Steps < Original_Steps then
            return
              Wide (Image (Original_Steps))
              & " "
              & Arrow
              & " "
              & Wide (Image (Current_Steps) & " steps | shorter failing path");
         elsif Item.Accepted > 0 then
            return
              Wide (Image (Original_Steps))
              & " "
              & Arrow
              & " "
              & Wide
                  (Image (Current_Steps)
                   & " steps | replay choices smaller; path unchanged");
         else
            return
              Wide (Image (Original_Steps))
              & " "
              & Arrow
              & " "
              & Wide
                  (Image (Current_Steps)
                   & " steps | no smaller failing path found");
         end if;
      end Path_Image;

      function Trace_Surface return Flyology_TUI.Surfaces.Surface
      is (if Length (Item.Current_Trace_JSON) = 0
          then Flyology_TUI.Surfaces.Create (Content_Width, 0)
          else
            Counterweave.Trace_Views.Render
              (Source       => To_String (Item.Current_Trace_JSON),
               Width        => Content_Width,
               Theme        => Theme,
               Maximum_Rows => (if Compact_Height then 4 else 6),
               Compact      => Compact_Height));

      function Last_Result return String is
      begin
         if Item.Attempt = 0 then
            return "waiting for the first candidate";
         end if;
         case Item.Outcome is
            when Counterweave.Reducers.Preserved =>
               return
                 (if Item.Retained
                  then "same bug reproduced; smaller case kept"
                  else "same bug reproduced");
            when Counterweave.Reducers.Different_Result =>
               return "bug changed or disappeared; not kept";
            when Counterweave.Reducers.Invalid_Candidate =>
               return "generated case was invalid; not kept";
            when Counterweave.Reducers.Infrastructure_Error =>
               return "infrastructure error; candidate not kept";
         end case;
      end Last_Result;

      Heading               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Horizontally
          (Flyology_TUI.Surfaces.From_Text
             ("COUNTERWEAVE", Flyology_TUI.Themes.Charm_Palette.Title),
           Flyology_TUI.Components.Indicators.Badge
             ((if Completed
               then
                 (if Succeeded
                  then "COUNTEREXAMPLE REDUCED"
                  else "REDUCTION FAILED")
               elsif Stopping
               then "CANCELLING"
               else "SHRINKING"),
              (if (Completed and then not Succeeded) or else Stopping
               then Flyology_TUI.Components.Indicators.Warning_Tone
               else Flyology_TUI.Components.Indicators.Success_Tone),
              Theme),
           Gap => 2);
      Purpose               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Surfaces.From_Text (Wide (Title), Theme.Muted);
      Identity_Row          : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("MODEL",
           Wide
             ((if Length (Item.Pack_Label) = 0
               then "waiting"
               else To_String (Item.Pack_Label))
              & " | "
              & (if Length (Item.Model_Label) = 0
                 then "model pending"
                 else To_String (Item.Model_Label))),
           Content_Width,
           Theme);
      Property_Row          : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("CHECK",
           Wide
             ((if Length (Item.Property_Name) = 0
               then "waiting"
               else Humanize (To_String (Item.Property_Name)))
              & " | bug: "
              & (if Length (Item.Failure_Fingerprint) = 0
                 then "fingerprint pending"
                 else Humanize (To_String (Item.Failure_Fingerprint)))),
           Content_Width,
           Theme);
      Original_Row          : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("ORIGINAL",
           Wide
             (if Length (Item.Original_Repro) = 0
              then "waiting for baseline replay"
              else To_String (Item.Original_Repro)),
           Content_Width,
           Theme);
      Current_Row           : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ((if Completed then "REDUCED" else "NOW"),
           Wide (Repro_Image (Item.Current_Repro)),
           Content_Width,
           Theme);
      Path_Row              : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("PATH SIZE", Path_Image, Content_Width, Theme);
      Context               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Identity_Row,
           Flyology_TUI.Layouts.Join_Vertically
             (Property_Row,
              Flyology_TUI.Layouts.Join_Vertically
                (Original_Row, Current_Row)));
      Compact_Context       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Identity_Row,
           Flyology_TUI.Layouts.Join_Vertically
             (Property_Row,
              Flyology_TUI.Layouts.Join_Vertically
                (Original_Row, Current_Row)));
      Divider               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Divider
          (Content_Width, "SHRINK ACTIVITY", Theme);
      Attempt_Row           : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("TRYING",
           Wide
             (Image (Item.Attempt)
              & " of "
              & Image (Item.Maximum_Attempts)
              & (if Item.Attempt = 0
                 then ""
                 else " | " & Humanize (To_String (Item.Strategy)))),
           Content_Width,
           Theme);
      Accepted_Row          : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("SMALLER CASES KEPT",
           Wide (Image (Item.Accepted)),
           Content_Width,
           Theme);
      Tape_Row              : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("REPLAY CHOICES", Wide (Current_Size), Content_Width, Theme);
      Strategy_Row          : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("LAST RESULT",
           Wide (Last_Result),
           Content_Width,
           Theme);
      Metrics               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Attempt_Row,
           Flyology_TUI.Layouts.Join_Vertically
             (Accepted_Row,
              Flyology_TUI.Layouts.Join_Vertically (Tape_Row, Strategy_Row)));
      Compact_Result_Row    : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("RESULT",
           Wide
             (Last_Result
              & " | "
              & Image (Item.Accepted)
              & " smaller kept"),
           Content_Width,
           Theme);
      Compact_Metrics       : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Attempt_Row, Compact_Result_Row);
      Completion_Row        : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("SHRINK",
           Wide
             (Image (Item.Accepted)
              & " smaller kept | "
              & Image (Item.Attempt)
              & " candidates | "
              & Current_Size),
           Content_Width,
           Theme);
      Case_Row              : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("CASE", Wide (Case_Path), Content_Width, Theme);
      Run_Row               : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("RUN", Wide (Run_Path), Content_Width, Theme);
      Report_Row            : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Components.Indicators.Key_Value
          ("REDUCTION", Wide (Report_Path), Content_Width, Theme);
      Evidence              : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Case_Row,
           Flyology_TUI.Layouts.Join_Vertically (Run_Row, Report_Row));
      Footer                : constant Flyology_TUI.Surfaces.Surface :=
        (if Completed
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
                  Flyology_TUI.Components.Indicators.Error_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment
                 ("ENTER SHELL")],
              Content_Width,
              Theme)
         else
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
                  Flyology_TUI.Components.Indicators.Error_Tone),
               Flyology_TUI.Components.Indicators.Make_Segment
                 ("q CANCEL")],
              Content_Width,
              Theme));
      Activity              : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically
          (Divider,
           Flyology_TUI.Layouts.Join_Vertically
             (Render_Progress,
              (if Compact_Height then Compact_Metrics else Metrics)),
           Gap => (if Compact_Height then 0 else 1));
      Content               : constant Flyology_TUI.Surfaces.Surface :=
        (if Completed
         then
           Flyology_TUI.Layouts.Join_Vertically
             (Heading,
              Flyology_TUI.Layouts.Join_Vertically
                (Trace_Surface,
                 Flyology_TUI.Layouts.Join_Vertically
                   (Context,
                    Flyology_TUI.Layouts.Join_Vertically
                      (Path_Row,
                       Flyology_TUI.Layouts.Join_Vertically
                         (Completion_Row,
                          Flyology_TUI.Layouts.Join_Vertically
                            (Evidence, Footer))))))
         elsif Compact_Height
         then
           Flyology_TUI.Layouts.Join_Vertically
             (Heading,
              Flyology_TUI.Layouts.Join_Vertically
                (Compact_Context,
                 Flyology_TUI.Layouts.Join_Vertically
                   (Activity,
                    Flyology_TUI.Layouts.Join_Vertically
                      (Trace_Surface, Footer))))
         else
           Flyology_TUI.Layouts.Join_Vertically
             (Heading,
              Flyology_TUI.Layouts.Join_Vertically
                (Purpose,
                 Flyology_TUI.Layouts.Join_Vertically
                   (Context,
                    Flyology_TUI.Layouts.Join_Vertically
                      (Activity,
                       Flyology_TUI.Layouts.Join_Vertically
                         (Trace_Surface, Footer, Gap => 1),
                       Gap => 1),
                    Gap => 1),
                 Gap => 1),
              Gap => 1));
      Panel                 : constant Flyology_TUI.Layouts.Block :=
        (Padding    => (Top => 1, Right => 2, Bottom => 1, Left => 2),
         Border     => Flyology_TUI.Layouts.Rounded,
         Appearance => Theme.Border,
         others     => <>);
      Result                : Flyology_TUI.Views.View :=
        Flyology_TUI.Views.From_Surface
          (Flyology_TUI.Layouts.Render (Panel, Content));
   begin
      Result.Alternate_Screen := True;
      Result.Window_Title :=
        Wide_Text.To_Unbounded_Wide_Wide_String ("Counterweave reduction");
      return Result;
   end Present;

   procedure Run
     (Title            : String;
      Case_Path        : String;
      Run_Path         : String;
      Report_Path      : String;
      Maximum_Attempts : Positive;
      Action           :
        not null access procedure
          (Progress :
             access procedure
               (Update : Counterweave.Reducers.Reduction_Update);
           Stop     : access function return Boolean);
      Result           : out Completion_Result)
   is
      State    : Progress_State;
      Terminal : Flyology_TUI.Backends.POSIX.POSIX_Backend;
      Opened   : Boolean := False;

      procedure Record_Progress
        (Update : Counterweave.Reducers.Reduction_Update) is
      begin
         State.Publish (Update);
         if Opened then
            Flyology_TUI.Backends.POSIX.Interrupt (Terminal);
         end if;
      end Record_Progress;

      function Stop return Boolean
      is (State.Stop_Requested);

      procedure Read_Result is
         Stopping, Completed, Succeeded : Boolean;
         Detail                         : Unbounded_String;
      begin
         State.Snapshot (Result.Last, Stopping, Completed, Succeeded, Detail);
         pragma Unreferenced (Stopping, Completed);
         Result.Succeeded := Succeeded;
         Result.Detail := Detail;
      end Read_Result;
   begin
      State.Initialize (Maximum_Attempts);
      if not Interactive then
         begin
            Action (Record_Progress'Access, Stop'Access);
            State.Complete (True, "");
         exception
            when Error : others =>
               State.Complete
                 (False, Ada.Exceptions.Exception_Message (Error));
         end;
         Read_Result;
         if not Result.Succeeded then
            raise Action_Error with To_String (Result.Detail);
         end if;
         return;
      end if;

      Flyology_TUI.Backends.POSIX.Open (Terminal);
      Opened := True;
      declare
         task Worker;

         task body Worker is
         begin
            Action (Record_Progress'Access, Stop'Access);
            State.Complete (True, "");
            Flyology_TUI.Backends.POSIX.Interrupt (Terminal);
         exception
            when Error : others =>
               State.Complete
                 (False, Ada.Exceptions.Exception_Message (Error));
               Flyology_TUI.Backends.POSIX.Interrupt (Terminal);
         end Worker;

         Width                          : Natural := 80;
         Height                         : Natural := 24;
         Event                          : Flyology_TUI.Events.Terminal_Event;
         Status                         : Flyology_TUI.Backends.Input_Status;
         Last                           :
           Counterweave.Reducers.Reduction_Update;
         Stopping, Completed, Succeeded : Boolean;
         Dismissed                      : Boolean := False;
         Detail                         : Unbounded_String;
      begin
         declare
            Detected_Width  : Natural := Width;
            Detected_Height : Natural := Height;
            Available       : Boolean := False;
         begin
            Flyology_TUI.Backends.POSIX.Current_Size
              (Terminal, Detected_Width, Detected_Height, Available);
            if Available and then Detected_Width > 0 and then Detected_Height > 0
            then
               Width := Detected_Width;
               Height := Detected_Height;
            end if;
         end;
         loop
            State.Snapshot (Last, Stopping, Completed, Succeeded, Detail);
            Flyology_TUI.Backends.POSIX.Render
              (Terminal,
               Present
                 (Item        => Last,
                  Title       => Title,
                  Case_Path   => Case_Path,
                  Run_Path    => Run_Path,
                  Report_Path => Report_Path,
                  Width       => Width,
                  Height      => Height,
                  Stopping    => Stopping,
                  Completed   => Completed,
                  Succeeded   => Succeeded));
            exit when Completed and then Dismissed;
            Flyology_TUI.Backends.POSIX.Next_Event (Terminal, Event, Status);
            if Status = Flyology_TUI.Backends.Event_Available then
               if Event.Kind = Flyology_TUI.Events.Resize then
                  Width := Event.Width;
                  Height := Event.Height;
               elsif Completed
                 and then
                   (Event.Kind = Flyology_TUI.Events.Interrupt
                    or else
                      (Event.Kind = Flyology_TUI.Events.Key_Press
                       and then Event.Key.Kind
                                  in Flyology_TUI.Events.Enter_Key
                                   | Flyology_TUI.Events.Escape_Key))
               then
                  Dismissed := True;
               elsif Completed
                 and then Event.Kind = Flyology_TUI.Events.Key_Press
                 and then Event.Key.Kind = Flyology_TUI.Events.Text_Key
               then
                  declare
                     Key : constant Wide_Wide_String :=
                       Wide_Text.To_Wide_Wide_String (Event.Key.Value);
                  begin
                     Dismissed := Key = "q";
                  end;
               elsif not Completed
                 and then Event.Kind = Flyology_TUI.Events.Interrupt
               then
                  State.Request_Stop;
                  Counterweave.Processes.Request_Cancel;
               elsif not Completed
                 and then Event.Kind = Flyology_TUI.Events.Key_Press
                 and then Event.Key.Kind = Flyology_TUI.Events.Text_Key
               then
                  declare
                     Key : constant Wide_Wide_String :=
                       Wide_Text.To_Wide_Wide_String (Event.Key.Value);
                  begin
                     if Key = "q"
                       or else (Key = "c" and then Event.Key.Modified.Control)
                     then
                        State.Request_Stop;
                        Counterweave.Processes.Request_Cancel;
                     end if;
                  end;
               end if;
            end if;
         end loop;
      exception
         when others =>
            State.Request_Stop;
            Counterweave.Processes.Request_Cancel;
            raise;
      end;
      Flyology_TUI.Backends.POSIX.Close (Terminal);
      Opened := False;
      Read_Result;
      if not Result.Succeeded then
         raise Action_Error with To_String (Result.Detail);
      end if;
   exception
      when others =>
         if Opened then
            Flyology_TUI.Backends.POSIX.Close (Terminal);
         end if;
         raise;
   end Run;

end Counterweave.Reduction_UI;
