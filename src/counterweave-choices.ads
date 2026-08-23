with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Counterweave.Choices is

   subtype Choice_Value is Interfaces.Unsigned_64;

   type Fork_Path is private;

   function Root return Fork_Path;

   function Child
     (Parent : Fork_Path; Label : String; Index : Interfaces.Unsigned_64 := 0)
      return Fork_Path;

   function Image (Path : Fork_Path) return String;

   type Choice_Tape is private;

   procedure Start_Recording
     (Tape : out Choice_Tape; Root_Seed : Choice_Value);

   function Draw
     (Tape : in out Choice_Tape; Path : Fork_Path) return Choice_Value;

   function Draw_Bounded
     (Tape : in out Choice_Tape; Path : Fork_Path; Maximum : Choice_Value)
      return Choice_Value;

   function Seed (Tape : Choice_Tape) return Choice_Value;

   function To_JSON (Tape : Choice_Tape) return String;

   function From_JSON (Source : String) return Choice_Tape;

   type Replay_Session is private;

   function Replay (Tape : Choice_Tape) return Replay_Session;

   function Draw
     (Session : in out Replay_Session; Path : Fork_Path) return Choice_Value;

   procedure Finish (Session : Replay_Session);

   Choice_Error : exception;
   Replay_Error : exception;

private
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;

   type Fork_Path is record
      Encoded   : Unbounded_String;
      Displayed : Unbounded_String;
   end record;

   package Value_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Choice_Value);

   type Fork_Record is record
      Path   : Fork_Path;
      State  : Choice_Value := 0;
      Values : Value_Vectors.Vector;
   end record;

   package Fork_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Fork_Record);

   type Choice_Tape is record
      Root_Seed : Choice_Value := 0;
      Forks     : Fork_Vectors.Vector;
   end record;

   package Position_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Natural);

   type Replay_Session is record
      Tape      : Choice_Tape;
      Positions : Position_Vectors.Vector;
   end record;

end Counterweave.Choices;
