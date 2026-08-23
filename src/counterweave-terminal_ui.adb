with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Strings.Wide_Wide_Unbounded;
with Counterweave.Processes;
with Flyology_TUI.Application_Events;
with Flyology_TUI.Backends.POSIX;
with Flyology_TUI.Events;
with Flyology_TUI.Layouts;
with Flyology_TUI.Runners;
with Flyology_TUI.Styles;
with Flyology_TUI.Surfaces;
with Flyology_TUI.Transitions;
with Flyology_TUI.Views;
with Interfaces.C;

package body Counterweave.Terminal_UI is

   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Flyology_TUI.Events.Key_Kind;
   use type Flyology_TUI.Events.Terminal_Event_Kind;
   package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;

   function Isatty (Descriptor : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "isatty";

   function Interactive return Boolean is
     (Isatty (0) = 1
      and then Isatty (1) = 1
      and then
        (not Ada.Environment_Variables.Exists ("TERM")
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

   type Completion_Message is record
      Succeeded : Boolean := False;
      Detail    : Unbounded_String;
   end record;

   type Command is (Perform);

   type Model is limited record
      Width     : Natural := 80;
      Height    : Natural := 24;
      Completed : Boolean := False;
      Cancelling : Boolean := False;
      Result    : Completion_Message;
   end record;

   package Events is new
     Flyology_TUI.Application_Events (Completion_Message);
   package Transitions is new Flyology_TUI.Transitions (Command);

   procedure Initialize
     (Item : in out Model;
      Next : in out Transitions.Transition)
   is
      pragma Unreferenced (Item);
   begin
      Transitions.Run (Next, Perform);
   end Initialize;

   procedure Update
     (Item  : in out Model;
      Event : Events.Event;
      Next  : in out Transitions.Transition) is
   begin
      case Event.Kind is
         when Events.Application_Message =>
            Item.Completed := True;
            Item.Result := Event.Application;
            Transitions.Quit (Next);
         when Events.Terminal_Input =>
            if Event.Terminal.Kind = Flyology_TUI.Events.Resize then
               Item.Width := Event.Terminal.Width;
               Item.Height := Event.Terminal.Height;
            elsif Event.Terminal.Kind = Flyology_TUI.Events.Interrupt then
               Counterweave.Processes.Request_Cancel;
               Item.Cancelling := True;
            elsif Event.Terminal.Kind = Flyology_TUI.Events.Key_Press
              and then Event.Terminal.Key.Kind = Flyology_TUI.Events.Text_Key
            then
               declare
                  Key : constant Wide_Wide_String :=
                    Wide_Text.To_Wide_Wide_String
                      (Event.Terminal.Key.Value);
               begin
                  if Key = "q"
                    or else
                      (Key = "c"
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
      Heading : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Surfaces.From_Text
          ("Counterweave",
           Flyology_TUI.Styles.Emphasized (Flyology_TUI.Styles.Default));
      Status  : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Surfaces.From_Text
          (Wide
             (if Item.Cancelling
              then "Cancelling active process..."
              else Title & "  (q or Ctrl-C to cancel)"));
      Content : constant Flyology_TUI.Surfaces.Surface :=
        Flyology_TUI.Layouts.Join_Vertically (Heading, Status, Gap => 1);
      Result  : Flyology_TUI.Views.View :=
        Flyology_TUI.Views.From_Surface (Content);
   begin
      Result.Alternate_Screen := True;
      Result.Window_Title :=
        Ada.Strings.Wide_Wide_Unbounded.To_Unbounded_Wide_Wide_String
          ("Counterweave");
      return Result;
   end Present;

   procedure Execute
     (Item     : Command;
      Result   : out Completion_Message;
      Produced : out Boolean)
   is
      pragma Unreferenced (Item);
   begin
      Action;
      Result := (Succeeded => True, Detail => Null_Unbounded_String);
      Produced := True;
   exception
      when Error : others =>
         Result :=
           (Succeeded => False,
            Detail    =>
              To_Unbounded_String (Ada.Exceptions.Exception_Information (Error)));
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

   procedure Run is
      State    : Model;
      Terminal : Flyology_TUI.Backends.POSIX.POSIX_Backend;
   begin
      if not Interactive then
         Action;
         return;
      end if;
      Runtime.Run (State, Terminal);
      if not State.Completed then
         raise Action_Error with "interactive runner stopped before completion";
      elsif not State.Result.Succeeded then
         raise Action_Error with To_String (State.Result.Detail);
      end if;
   end Run;

end Counterweave.Terminal_UI;
