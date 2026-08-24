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

   function Draw_Bounded
     (Session : in out Replay_Session;
      Path    : Fork_Path;
      Maximum : Choice_Value) return Choice_Value;

   function Consumed (Session : Replay_Session) return Choice_Tape;

   procedure Finish (Session : Replay_Session);

   function Fork_Count (Tape : Choice_Tape) return Natural;

   function Value_Count (Tape : Choice_Tape) return Natural;

   type Shrink_Strategy is
     (Delete_Subtree,
      Delete_Fork,
      Delete_Chunk,
      Small_Value,
      Boundary_Value,
      Halve_Value,
      Clear_Bit,
      Redistribute_Bit,
      Binary_Search,
      Minimize_Duplicates,
      Lower_And_Delete,
      Reorder_Values);

   function Image (Strategy : Shrink_Strategy) return String;

   type Shrink_Stop_Reason is (Fixed_Point, Attempt_Limit, Cancelled);

   generic
      with
        procedure Evaluate
          (Current   : Choice_Tape;
           Candidate : in out Choice_Tape;
           Strategy  : Shrink_Strategy;
           Location  : String;
           Preserved : out Boolean);
   procedure Shrink
     (Initial          : Choice_Tape;
      Result           : out Choice_Tape;
      Maximum_Attempts : Positive := 1_000;
      Should_Stop      : access function return Boolean := null;
      Stopped          : access procedure (Reason : Shrink_Stop_Reason) :=
        null;
      Retained         : access procedure := null);

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

   type Bounded_Algorithm is (Lower_Rejection_V1, Upper_Rejection_V1);

   type Choice_Tape is record
      Root_Seed : Choice_Value := 0;
      Forks     : Fork_Vectors.Vector;
      Bounded   : Bounded_Algorithm := Upper_Rejection_V1;
   end record;

   package Position_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Natural);

   type Replay_Session is record
      Tape      : Choice_Tape;
      Positions : Position_Vectors.Vector;
   end record;

end Counterweave.Choices;
