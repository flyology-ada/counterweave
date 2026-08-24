with Ada.Containers;
with Counterweave.JSON;
with Counterweave.Strings;

package body Counterweave.Choices is

   use type Ada.Containers.Count_Type;

   FNV_Offset : constant Choice_Value := 16#CBF2_9CE4_8422_2325#;
   FNV_Prime  : constant Choice_Value := 16#0000_0100_0000_01B3#;
   Gamma      : constant Choice_Value := 16#9E37_79B9_7F4A_7C15#;

   function Root return Fork_Path is
   begin
      return
        (Encoded => Null_Unbounded_String, Displayed => Null_Unbounded_String);
   end Root;

   function Child
     (Parent : Fork_Path; Label : String; Index : Interfaces.Unsigned_64 := 0)
      return Fork_Path
   is
      Length_Image : constant String :=
        Counterweave.Strings.Compact_Image (Long_Long_Integer (Label'Length));
      Index_Image  : constant String :=
        Counterweave.Strings.Compact_Image (Index);
      Encoded      : Unbounded_String := Parent.Encoded;
      Displayed    : Unbounded_String := Parent.Displayed;
   begin
      Append (Encoded, Length_Image & ":" & Label & "#" & Index_Image & ";");
      if Length (Displayed) > 0 then
         Append (Displayed, "/");
      end if;
      Append (Displayed, Label & "[" & Index_Image & "]");
      return (Encoded => Encoded, Displayed => Displayed);
   end Child;

   function Image (Path : Fork_Path) return String is
   begin
      if Length (Path.Displayed) = 0 then
         return "root";
      end if;
      return To_String (Path.Displayed);
   end Image;

   function Mixed (Value : Choice_Value) return Choice_Value is
      Result : Choice_Value := Value;
   begin
      Result :=
        (Result xor Interfaces.Shift_Right (Result, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Result :=
        (Result xor Interfaces.Shift_Right (Result, 27))
        * 16#94D0_49BB_1331_11EB#;
      return Result xor Interfaces.Shift_Right (Result, 31);
   end Mixed;

   function Derived_State
     (Root_Seed : Choice_Value; Path : Fork_Path) return Choice_Value
   is
      Hash : Choice_Value := FNV_Offset xor Root_Seed;
   begin
      for Item of To_String (Path.Encoded) loop
         Hash := (Hash xor Character'Pos (Item)) * FNV_Prime;
      end loop;
      return Mixed (Hash + Gamma);
   end Derived_State;

   function Next (State : in out Choice_Value) return Choice_Value is
   begin
      State := State + Gamma;
      return Mixed (State);
   end Next;

   function Find_Fork (Tape : Choice_Tape; Path : Fork_Path) return Natural is
   begin
      for Index in Tape.Forks.First_Index .. Tape.Forks.Last_Index loop
         if Tape.Forks (Index).Path.Encoded = Path.Encoded then
            return Index;
         end if;
      end loop;
      return Natural'Last;
   end Find_Fork;

   procedure Start_Recording (Tape : out Choice_Tape; Root_Seed : Choice_Value)
   is
   begin
      Tape :=
        (Root_Seed => Root_Seed,
         Forks     => Fork_Vectors.Empty_Vector,
         Bounded   => Upper_Rejection_V1);
   end Start_Recording;

   function Draw
     (Tape : in out Choice_Tape; Path : Fork_Path) return Choice_Value
   is
      Index : Natural := Find_Fork (Tape, Path);
   begin
      if Index = Natural'Last then
         Tape.Forks.Append
           (Fork_Record'
              (Path   => Path,
               State  => Derived_State (Tape.Root_Seed, Path),
               Values => Value_Vectors.Empty_Vector));
         Index := Tape.Forks.Last_Index;
      end if;

      declare
         Item  : Fork_Record := Tape.Forks (Index);
         Value : constant Choice_Value := Next (Item.State);
      begin
         Item.Values.Append (Value);
         Tape.Forks.Replace_Element (Index, Item);
         return Value;
      end;
   end Draw;

   function Draw_Bounded
     (Tape : in out Choice_Tape; Path : Fork_Path; Maximum : Choice_Value)
      return Choice_Value
   is
      Range_Size : Choice_Value;
      Boundary   : Choice_Value;
      Value      : Choice_Value;
   begin
      if Maximum = Choice_Value'Last then
         return Draw (Tape, Path);
      end if;
      Range_Size := Maximum + 1;
      case Tape.Bounded is
         when Lower_Rejection_V1 =>
            Boundary := (-Range_Size) mod Range_Size;
            loop
               Value := Draw (Tape, Path);
               if Value >= Boundary then
                  return Value mod Range_Size;
               end if;
            end loop;

         when Upper_Rejection_V1 =>
            Boundary := Choice_Value'Last - ((-Range_Size) mod Range_Size);
            loop
               Value := Draw (Tape, Path);
               if Value <= Boundary then
                  return Value mod Range_Size;
               end if;
            end loop;
      end case;
   end Draw_Bounded;

   function Seed (Tape : Choice_Tape) return Choice_Value is
   begin
      return Tape.Root_Seed;
   end Seed;

   function To_JSON (Tape : Choice_Tape) return String is
      Result     : Unbounded_String :=
        To_Unbounded_String
          ("{""format"":"""
           & (case Tape.Bounded is
                when Lower_Rejection_V1 => "counterweave.choices/1",
                when Upper_Rejection_V1 => "counterweave.choices/2")
           & """,""algorithm"":""splitmix64-v1"""
           & (case Tape.Bounded is
                when Lower_Rejection_V1 => "",
                when Upper_Rejection_V1 =>
                  ",""bounded"":""upper-rejection-v1""")
           & ",""root_seed"":"
           & Counterweave.Strings.JSON_String
               (Counterweave.Strings.Compact_Image (Tape.Root_Seed))
           & ",""forks"":[");
      First_Fork : Boolean := True;
   begin
      for Fork of Tape.Forks loop
         if First_Fork then
            First_Fork := False;
         else
            Append (Result, ",");
         end if;
         Append
           (Result,
            "{""path"":"
            & Counterweave.Strings.JSON_String (Image (Fork.Path))
            & ",""key"":"
            & Counterweave.Strings.JSON_String (To_String (Fork.Path.Encoded))
            & ",""values"":[");
         declare
            First_Value : Boolean := True;
         begin
            for Value of Fork.Values loop
               if First_Value then
                  First_Value := False;
               else
                  Append (Result, ",");
               end if;
               Append
                 (Result,
                  Counterweave.Strings.JSON_String
                    (Counterweave.Strings.Compact_Image (Value)));
            end loop;
         end;
         Append (Result, "]}");
      end loop;
      Append (Result, "]}");
      return To_String (Result);
   end To_JSON;

   function From_JSON (Source : String) return Choice_Tape is
      Root_Value : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Format     : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source,
              Counterweave.JSON.Member (Source, Root_Value, "format")));
      Algorithm  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source,
              Counterweave.JSON.Member (Source, Root_Value, "algorithm")));
      Forks      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root_Value, "forks");
      Result     : Choice_Tape;
   begin
      if Format not in "counterweave.choices/1" | "counterweave.choices/2" then
         raise Choice_Error with "unsupported choice tape format";
      elsif Algorithm /= "splitmix64-v1" then
         raise Choice_Error with "unsupported choice algorithm";
      end if;
      if Format = "counterweave.choices/1" then
         Result.Bounded := Lower_Rejection_V1;
      elsif To_String
              (Counterweave.JSON.As_String
                 (Source,
                  Counterweave.JSON.Member (Source, Root_Value, "bounded")))
        = "upper-rejection-v1"
      then
         Result.Bounded := Upper_Rejection_V1;
      else
         raise Choice_Error with "unsupported bounded choice algorithm";
      end if;
      Result.Root_Seed :=
        Counterweave.JSON.As_Unsigned
          (Source, Counterweave.JSON.Member (Source, Root_Value, "root_seed"));

      for Fork_Index in 0 .. Counterweave.JSON.Length (Source, Forks) loop
         exit when Fork_Index = Counterweave.JSON.Length (Source, Forks);
         declare
            Fork_Value : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Element (Source, Forks, Fork_Index);
            Key        : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source, Counterweave.JSON.Member (Source, Fork_Value, "key"));
            Displayed  : constant Unbounded_String :=
              Counterweave.JSON.As_String
                (Source,
                 Counterweave.JSON.Member (Source, Fork_Value, "path"));
            Values     : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Member (Source, Fork_Value, "values");
            Item       : Fork_Record :=
              (Path   => (Encoded => Key, Displayed => Displayed),
               State  => 0,
               Values => Value_Vectors.Empty_Vector);
         begin
            for Existing of Result.Forks loop
               if Existing.Path.Encoded = Key then
                  raise Choice_Error with "duplicate choice fork";
               end if;
            end loop;
            for Value_Index in 0 .. Counterweave.JSON.Length (Source, Values)
            loop
               exit when
                 Value_Index = Counterweave.JSON.Length (Source, Values);
               Item.Values.Append
                 (Counterweave.JSON.As_Unsigned
                    (Source,
                     Counterweave.JSON.Element (Source, Values, Value_Index)));
            end loop;
            Result.Forks.Append (Item);
         end;
      end loop;
      return Result;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Choice_Error with "malformed choice tape";
   end From_JSON;

   function Replay (Tape : Choice_Tape) return Replay_Session is
      Result : Replay_Session :=
        (Tape => Tape, Positions => Position_Vectors.Empty_Vector);
   begin
      for Unused of Tape.Forks loop
         Result.Positions.Append (0);
      end loop;
      return Result;
   end Replay;

   function Draw
     (Session : in out Replay_Session; Path : Fork_Path) return Choice_Value
   is
      Index    : constant Natural := Find_Fork (Session.Tape, Path);
      Position : Natural;
   begin
      if Index = Natural'Last then
         raise Replay_Error with "choice fork is missing: " & Image (Path);
      end if;
      Position := Session.Positions (Index);
      if Position >= Natural (Session.Tape.Forks (Index).Values.Length) then
         raise Replay_Error with "choice fork is exhausted: " & Image (Path);
      end if;
      Session.Positions.Replace_Element (Index, Position + 1);
      return Session.Tape.Forks (Index).Values (Position);
   end Draw;

   function Draw_Bounded
     (Session : in out Replay_Session;
      Path    : Fork_Path;
      Maximum : Choice_Value) return Choice_Value
   is
      Range_Size : Choice_Value;
      Boundary   : Choice_Value;
      Value      : Choice_Value;
   begin
      if Maximum = Choice_Value'Last then
         return Draw (Session, Path);
      end if;
      Range_Size := Maximum + 1;
      case Session.Tape.Bounded is
         when Lower_Rejection_V1 =>
            Boundary := (-Range_Size) mod Range_Size;
            loop
               Value := Draw (Session, Path);
               if Value >= Boundary then
                  return Value mod Range_Size;
               end if;
            end loop;

         when Upper_Rejection_V1 =>
            Boundary := Choice_Value'Last - ((-Range_Size) mod Range_Size);
            loop
               Value := Draw (Session, Path);
               if Value <= Boundary then
                  return Value mod Range_Size;
               end if;
            end loop;
      end case;
   end Draw_Bounded;

   function Consumed (Session : Replay_Session) return Choice_Tape is
      Result : Choice_Tape :=
        (Root_Seed => Session.Tape.Root_Seed,
         Forks     => Fork_Vectors.Empty_Vector,
         Bounded   => Session.Tape.Bounded);
   begin
      for Index in
        Session.Tape.Forks.First_Index .. Session.Tape.Forks.Last_Index
      loop
         declare
            Count : constant Natural := Session.Positions (Index);
         begin
            if Count > 0 then
               declare
                  Source : constant Fork_Record := Session.Tape.Forks (Index);
                  Item   : Fork_Record :=
                    (Path   => Source.Path,
                     State  => 0,
                     Values => Value_Vectors.Empty_Vector);
               begin
                  for Position in 0 .. Count - 1 loop
                     Item.Values.Append (Source.Values (Position));
                  end loop;
                  Result.Forks.Append (Item);
               end;
            end if;
         end;
      end loop;
      return Result;
   end Consumed;

   procedure Finish (Session : Replay_Session) is
   begin
      for Index in
        Session.Tape.Forks.First_Index .. Session.Tape.Forks.Last_Index
      loop
         if Session.Positions (Index)
           /= Natural (Session.Tape.Forks (Index).Values.Length)
         then
            raise Replay_Error
              with
                "choice fork has unused values: "
                & Image (Session.Tape.Forks (Index).Path);
         end if;
      end loop;
   end Finish;

   function Fork_Count (Tape : Choice_Tape) return Natural
   is (Natural (Tape.Forks.Length));

   function Value_Count (Tape : Choice_Tape) return Natural is
      Result : Natural := 0;
   begin
      for Fork of Tape.Forks loop
         Result := Result + Natural (Fork.Values.Length);
      end loop;
      return Result;
   end Value_Count;

   function Image (Strategy : Shrink_Strategy) return String is
   begin
      return
        (case Strategy is
           when Delete_Subtree      => "delete-subtree",
           when Delete_Fork         => "delete-fork",
           when Delete_Chunk        => "delete-chunk",
           when Small_Value         => "small-value",
           when Boundary_Value      => "boundary-value",
           when Halve_Value         => "halve-value",
           when Clear_Bit           => "clear-bit",
           when Redistribute_Bit    => "redistribute-bit",
           when Binary_Search       => "binary-search",
           when Minimize_Duplicates => "minimize-duplicates",
           when Lower_And_Delete    => "lower-and-delete",
           when Reorder_Values      => "reorder-values");
   end Image;

   procedure Shrink
     (Initial          : Choice_Tape;
      Result           : out Choice_Tape;
      Maximum_Attempts : Positive := 1_000;
      Should_Stop      : access function return Boolean := null;
      Stopped          : access procedure (Reason : Shrink_Stop_Reason) :=
        null;
      Retained         : access procedure := null)
   is
      type Candidate_Value_Array is array (Positive range <>) of Choice_Value;

      Small_Values : constant Candidate_Value_Array := [0, 1, 2, 3, 4];
      Boundaries   : constant Candidate_Value_Array :=
        [Choice_Value'Last,
         Choice_Value'Last - 1,
         16#7FFF_FFFF_FFFF_FFFF#,
         16#8000_0000_0000_0000#,
         16#0000_0000_FFFF_FFFF#,
         16#0000_0001_0000_0000#,
         16#0000_0000_0000_FFFF#,
         16#0000_0000_0000_00FF#,
         128];

      Current  : Choice_Tape := Initial;
      Pending  : Choice_Tape;
      Attempts : Natural := 0;

      Stop_Shrinking : exception;
      Stop_Reason    : Shrink_Stop_Reason := Fixed_Point;

      function Location
        (Fork : Fork_Record; Position : Natural := Natural'Last) return String
      is
         Base : constant String := Image (Fork.Path);
      begin
         if Position = Natural'Last then
            return Base;
         end if;
         return
           Base
           & "/value["
           & Counterweave.Strings.Compact_Image (Long_Long_Integer (Position))
           & "]";
      end Location;

      function Simpler_Value
        (Candidate : Choice_Value; Original : Choice_Value) return Boolean
      is (Candidate < Original);

      function Strictly_Smaller
        (Candidate : Choice_Tape; Original : Choice_Tape) return Boolean
      is
         Candidate_Values : constant Natural := Value_Count (Candidate);
         Original_Values  : constant Natural := Value_Count (Original);
      begin
         if Candidate_Values /= Original_Values then
            return Candidate_Values < Original_Values;
         elsif Candidate.Forks.Length /= Original.Forks.Length then
            return Candidate.Forks.Length < Original.Forks.Length;
         end if;
         for Fork_Index in
           Candidate.Forks.First_Index .. Candidate.Forks.Last_Index
         loop
            declare
               Left  : constant Fork_Record := Candidate.Forks (Fork_Index);
               Right : constant Fork_Record := Original.Forks (Fork_Index);
            begin
               if Left.Path.Encoded /= Right.Path.Encoded then
                  return Left.Path.Encoded < Right.Path.Encoded;
               elsif Left.Values.Length /= Right.Values.Length then
                  return Left.Values.Length < Right.Values.Length;
               end if;
               for Value_Index in
                 Left.Values.First_Index .. Left.Values.Last_Index
               loop
                  if Left.Values (Value_Index) /= Right.Values (Value_Index)
                  then
                     return
                       Simpler_Value
                         (Left.Values (Value_Index),
                          Right.Values (Value_Index));
                  end if;
               end loop;
            end;
         end loop;
         return False;
      end Strictly_Smaller;

      procedure Attempt
        (Candidate : in out Choice_Tape;
         Strategy  : Shrink_Strategy;
         Where     : String;
         Accepted  : out Boolean)
      is
         Preserved : Boolean := False;
      begin
         Accepted := False;
         if not Strictly_Smaller (Candidate, Current) then
            return;
         end if;
         if Should_Stop /= null and then Should_Stop.all then
            Stop_Reason := Cancelled;
            raise Stop_Shrinking;
         elsif Attempts = Maximum_Attempts then
            Stop_Reason := Attempt_Limit;
            raise Stop_Shrinking;
         end if;
         Attempts := Attempts + 1;
         Evaluate (Current, Candidate, Strategy, Where, Preserved);
         if Preserved and then Strictly_Smaller (Candidate, Current) then
            Pending.Root_Seed := Candidate.Root_Seed;
            Pending.Bounded := Candidate.Bounded;
            Fork_Vectors.Move
              (Target => Pending.Forks, Source => Candidate.Forks);
            Accepted := True;
            if Retained /= null then
               Retained.all;
            end if;
         end if;
      end Attempt;

      function Starts_With (Value : String; Prefix : String) return Boolean
      is (Prefix'Length <= Value'Length
          and then Value (Value'First .. Value'First + Prefix'Length - 1)
                   = Prefix);

      function Try_Delete_Subtree return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            declare
               Fork : constant Fork_Record := Current.Forks (Fork_Index);
               Key  : constant String := To_String (Fork.Path.Encoded);
            begin
               for Last in Key'Range loop
                  if Key (Last) = ';' then
                     declare
                        Prefix    : constant String := Key (Key'First .. Last);
                        Candidate : Choice_Tape := Current;
                        Removed   : Natural := 0;
                        Accepted  : Boolean;
                     begin
                        for Index in reverse
                          Candidate.Forks.First_Index
                          .. Candidate.Forks.Last_Index
                        loop
                           if Starts_With
                                (To_String
                                   (Candidate.Forks (Index).Path.Encoded),
                                 Prefix)
                           then
                              Candidate.Forks.Delete (Index);
                              Removed := Removed + 1;
                           end if;
                        end loop;
                        if Removed > 1 then
                           Attempt
                             (Candidate,
                              Delete_Subtree,
                              To_String (Fork.Path.Displayed),
                              Accepted);
                           if Accepted then
                              return True;
                           end if;
                        end if;
                     end;
                  end if;
               end loop;
            end;
         end loop;
         return False;
      end Try_Delete_Subtree;

      function Try_Delete_Fork return Boolean is
      begin
         for Index in Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            declare
               Candidate : Choice_Tape := Current;
               Where     : constant String := Location (Current.Forks (Index));
               Accepted  : Boolean;
            begin
               Candidate.Forks.Delete (Index);
               Attempt (Candidate, Delete_Fork, Where, Accepted);
               if Accepted then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Try_Delete_Fork;

      function Try_Delete_Chunk return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            declare
               Length : constant Natural :=
                 Natural (Current.Forks (Fork_Index).Values.Length);
               Chunk  : Natural := Length;
            begin
               while Chunk > 0 loop
                  for First in 0 .. Length - Chunk loop
                     declare
                        Candidate : Choice_Tape := Current;
                        Item      : Fork_Record :=
                          Candidate.Forks (Fork_Index);
                        Accepted  : Boolean;
                     begin
                        for Unused in 1 .. Chunk loop
                           Item.Values.Delete (First);
                        end loop;
                        Candidate.Forks.Replace_Element (Fork_Index, Item);
                        Attempt
                          (Candidate,
                           Delete_Chunk,
                           Location (Item, First),
                           Accepted);
                        if Accepted then
                           return True;
                        end if;
                     end;
                  end loop;
                  Chunk := Chunk / 2;
               end loop;
            end;
         end loop;
         return False;
      end Try_Delete_Chunk;

      function Try_Values
        (Values : Candidate_Value_Array; Strategy : Shrink_Strategy)
         return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
               begin
                  for Value of Values loop
                     if Simpler_Value (Value, Original) then
                        declare
                           Candidate : Choice_Tape := Current;
                           Item      : Fork_Record :=
                             Candidate.Forks (Fork_Index);
                           Accepted  : Boolean;
                        begin
                           Item.Values.Replace_Element (Value_Index, Value);
                           Candidate.Forks.Replace_Element (Fork_Index, Item);
                           Attempt
                             (Candidate,
                              Strategy,
                              Location (Item, Value_Index),
                              Accepted);
                           if Accepted then
                              return True;
                           end if;
                        end;
                     end if;
                  end loop;
               end;
            end loop;
         end loop;
         return False;
      end Try_Values;

      function Try_Halve_Value return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original    : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
                  Replacement : constant Choice_Value := Original / 2;
               begin
                  if Simpler_Value (Replacement, Original) then
                     declare
                        Candidate : Choice_Tape := Current;
                        Item      : Fork_Record :=
                          Candidate.Forks (Fork_Index);
                        Accepted  : Boolean;
                     begin
                        Item.Values.Replace_Element (Value_Index, Replacement);
                        Candidate.Forks.Replace_Element (Fork_Index, Item);
                        Attempt
                          (Candidate,
                           Halve_Value,
                           Location (Item, Value_Index),
                           Accepted);
                        if Accepted then
                           return True;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end loop;
         return False;
      end Try_Halve_Value;

      function Try_Clear_Bit return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
               begin
                  for Bit in reverse 0 .. 63 loop
                     declare
                        Mask : constant Choice_Value :=
                          Interfaces.Shift_Left (1, Bit);
                     begin
                        if (Original and Mask) /= 0 then
                           declare
                              Replacement : constant Choice_Value :=
                                Original and not Mask;
                           begin
                              if Simpler_Value (Replacement, Original) then
                                 declare
                                    Candidate : Choice_Tape := Current;
                                    Item      : Fork_Record :=
                                      Candidate.Forks (Fork_Index);
                                    Accepted  : Boolean;
                                 begin
                                    Item.Values.Replace_Element
                                      (Value_Index, Replacement);
                                    Candidate.Forks.Replace_Element
                                      (Fork_Index, Item);
                                    Attempt
                                      (Candidate,
                                       Clear_Bit,
                                       Location (Item, Value_Index),
                                       Accepted);
                                    if Accepted then
                                       return True;
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         return False;
      end Try_Clear_Bit;

      function Try_Redistribute_Bit return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
               begin
                  for High in reverse 1 .. 63 loop
                     for Low in 0 .. High - 1 loop
                        declare
                           High_Mask : constant Choice_Value :=
                             Interfaces.Shift_Left (1, High);
                           Low_Mask  : constant Choice_Value :=
                             Interfaces.Shift_Left (1, Low);
                        begin
                           if (Original and High_Mask) /= 0
                             and then (Original and Low_Mask) = 0
                           then
                              declare
                                 Replacement : constant Choice_Value :=
                                   (Original and not High_Mask) or Low_Mask;
                              begin
                                 if Simpler_Value (Replacement, Original) then
                                    declare
                                       Candidate : Choice_Tape := Current;
                                       Item      : Fork_Record :=
                                         Candidate.Forks (Fork_Index);
                                       Accepted  : Boolean;
                                    begin
                                       Item.Values.Replace_Element
                                         (Value_Index, Replacement);
                                       Candidate.Forks.Replace_Element
                                         (Fork_Index, Item);
                                       Attempt
                                         (Candidate,
                                          Redistribute_Bit,
                                          Location (Item, Value_Index),
                                          Accepted);
                                       if Accepted then
                                          return True;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
         return False;
      end Try_Redistribute_Bit;

      function Try_Minimize_Duplicates return Boolean is

         function Try_Replacement
           (Original    : Choice_Value;
            Replacement : Choice_Value;
            Fork_Index  : Natural;
            Value_Index : Natural) return Boolean
         is
            Candidate : Choice_Tape := Current;
            Accepted  : Boolean;
         begin
            if not Simpler_Value (Replacement, Original) then
               return False;
            end if;
            for Index in
              Candidate.Forks.First_Index .. Candidate.Forks.Last_Index
            loop
               declare
                  Item : Fork_Record := Candidate.Forks (Index);
               begin
                  for Position in
                    Item.Values.First_Index .. Item.Values.Last_Index
                  loop
                     if Item.Values (Position) = Original then
                        Item.Values.Replace_Element (Position, Replacement);
                     end if;
                  end loop;
                  Candidate.Forks.Replace_Element (Index, Item);
               end;
            end loop;
            Attempt
              (Candidate,
               Minimize_Duplicates,
               Location (Current.Forks (Fork_Index), Value_Index),
               Accepted);
            return Accepted;
         end Try_Replacement;

      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
                  Count    : Natural := 0;
               begin
                  for Index in
                    Current.Forks.First_Index .. Current.Forks.Last_Index
                  loop
                     for Position in
                       Current.Forks (Index).Values.First_Index
                       .. Current.Forks (Index).Values.Last_Index
                     loop
                        if Current.Forks (Index).Values (Position) = Original
                        then
                           Count := Count + 1;
                        end if;
                     end loop;
                  end loop;
                  if Count > 1 then
                     for Replacement of Small_Values loop
                        if Try_Replacement
                             (Original, Replacement, Fork_Index, Value_Index)
                        then
                           return True;
                        end if;
                     end loop;
                     for Replacement of Boundaries loop
                        if Try_Replacement
                             (Original, Replacement, Fork_Index, Value_Index)
                        then
                           return True;
                        end if;
                     end loop;
                     if Try_Replacement
                          (Original, Original / 2, Fork_Index, Value_Index)
                     then
                        return True;
                     end if;
                     for Bit in reverse 0 .. 63 loop
                        declare
                           Mask : constant Choice_Value :=
                             Interfaces.Shift_Left (1, Bit);
                        begin
                           if (Original and Mask) /= 0
                             and then Try_Replacement
                                        (Original,
                                         Original and not Mask,
                                         Fork_Index,
                                         Value_Index)
                           then
                              return True;
                           end if;
                        end;
                     end loop;
                     for High in reverse 1 .. 63 loop
                        for Low in 0 .. High - 1 loop
                           declare
                              High_Mask : constant Choice_Value :=
                                Interfaces.Shift_Left (1, High);
                              Low_Mask  : constant Choice_Value :=
                                Interfaces.Shift_Left (1, Low);
                           begin
                              if (Original and High_Mask) /= 0
                                and then (Original and Low_Mask) = 0
                                and then Try_Replacement
                                           (Original,
                                            (Original and not High_Mask)
                                            or Low_Mask,
                                            Fork_Index,
                                            Value_Index)
                              then
                                 return True;
                              end if;
                           end;
                        end loop;
                     end loop;
                     declare
                        Low  : Choice_Value := 0;
                        High : constant Choice_Value := Original;
                     begin
                        while Low < High loop
                           declare
                              Middle : constant Choice_Value :=
                                Low + (High - Low) / 2;
                           begin
                              if Try_Replacement
                                   (Original, Middle, Fork_Index, Value_Index)
                              then
                                 return True;
                              end if;
                              Low := Middle + 1;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end loop;
         return False;
      end Try_Minimize_Duplicates;

      function Try_Binary_Search return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            for Value_Index in
              Current.Forks (Fork_Index).Values.First_Index
              .. Current.Forks (Fork_Index).Values.Last_Index
            loop
               declare
                  Original : constant Choice_Value :=
                    Current.Forks (Fork_Index).Values (Value_Index);
                  Low      : Choice_Value := 0;
                  High     : constant Choice_Value := Original;
               begin
                  while Low < High loop
                     declare
                        Middle : constant Choice_Value :=
                          Low + (High - Low) / 2;
                     begin
                        if Simpler_Value (Middle, Original) then
                           declare
                              Candidate : Choice_Tape := Current;
                              Item      : Fork_Record :=
                                Candidate.Forks (Fork_Index);
                              Accepted  : Boolean;
                           begin
                              Item.Values.Replace_Element
                                (Value_Index, Middle);
                              Candidate.Forks.Replace_Element
                                (Fork_Index, Item);
                              Attempt
                                (Candidate,
                                 Binary_Search,
                                 Location (Item, Value_Index),
                                 Accepted);
                              if Accepted then
                                 return True;
                              end if;
                           end;
                        end if;
                        Low := Middle + 1;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         return False;
      end Try_Binary_Search;

      function Try_Lower_And_Delete return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            declare
               Length : constant Natural :=
                 Natural (Current.Forks (Fork_Index).Values.Length);
            begin
               for Value_Index in
                 Current.Forks (Fork_Index).Values.First_Index
                 .. Current.Forks (Fork_Index).Values.Last_Index
               loop
                  declare
                     Original : constant Choice_Value :=
                       Current.Forks (Fork_Index).Values (Value_Index);
                  begin
                     if Original > 0
                       and then Simpler_Value (Original - 1, Original)
                     then
                        for Delete_Count in reverse
                          0 .. Length - Value_Index - 1
                        loop
                           declare
                              Candidate : Choice_Tape := Current;
                              Item      : Fork_Record :=
                                Candidate.Forks (Fork_Index);
                              Accepted  : Boolean;
                           begin
                              Item.Values.Replace_Element
                                (Value_Index, Original - 1);
                              for Unused in 1 .. Delete_Count loop
                                 Item.Values.Delete (Value_Index + 1);
                              end loop;
                              Candidate.Forks.Replace_Element
                                (Fork_Index, Item);
                              Attempt
                                (Candidate,
                                 Lower_And_Delete,
                                 Location (Item, Value_Index),
                                 Accepted);
                              if Accepted then
                                 return True;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         return False;
      end Try_Lower_And_Delete;

      function Try_Reorder_Values return Boolean is
      begin
         for Fork_Index in
           Current.Forks.First_Index .. Current.Forks.Last_Index
         loop
            declare
               Length : constant Natural :=
                 Natural (Current.Forks (Fork_Index).Values.Length);
            begin
               if Length > 1 then
                  for Left_Index in 0 .. Length - 2 loop
                     for Right_Index in Left_Index + 1 .. Length - 1 loop
                        declare
                           Left  : constant Choice_Value :=
                             Current.Forks (Fork_Index).Values (Left_Index);
                           Right : constant Choice_Value :=
                             Current.Forks (Fork_Index).Values (Right_Index);
                        begin
                           if Simpler_Value (Right, Left) then
                              declare
                                 Candidate : Choice_Tape := Current;
                                 Item      : Fork_Record :=
                                   Candidate.Forks (Fork_Index);
                                 Accepted  : Boolean;
                              begin
                                 Item.Values.Replace_Element
                                   (Left_Index, Right);
                                 Item.Values.Replace_Element
                                   (Right_Index, Left);
                                 Candidate.Forks.Replace_Element
                                   (Fork_Index, Item);
                                 Attempt
                                   (Candidate,
                                    Reorder_Values,
                                    Location (Item, Left_Index),
                                    Accepted);
                                 if Accepted then
                                    return True;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  end loop;
               end if;
            end;
         end loop;
         return False;
      end Try_Reorder_Values;
   begin
      loop
         declare
            Changed : constant Boolean :=
              Try_Delete_Subtree
              or else Try_Delete_Fork
              or else Try_Delete_Chunk
              or else Try_Values (Small_Values, Small_Value)
              or else Try_Values (Boundaries, Boundary_Value)
              or else Try_Halve_Value
              or else Try_Clear_Bit
              or else Try_Redistribute_Bit
              or else Try_Binary_Search
              or else Try_Minimize_Duplicates
              or else Try_Lower_And_Delete
              or else Try_Reorder_Values;
         begin
            exit when not Changed;
            Current.Root_Seed := Pending.Root_Seed;
            Current.Bounded := Pending.Bounded;
            Fork_Vectors.Move
              (Target => Current.Forks, Source => Pending.Forks);
         end;
      end loop;
      Result.Root_Seed := Current.Root_Seed;
      Result.Bounded := Current.Bounded;
      Fork_Vectors.Move (Target => Result.Forks, Source => Current.Forks);
      if Stopped /= null then
         Stopped (Fixed_Point);
      end if;
   exception
      when Stop_Shrinking =>
         Result.Root_Seed := Current.Root_Seed;
         Result.Bounded := Current.Bounded;
         Fork_Vectors.Move (Target => Result.Forks, Source => Current.Forks);
         if Stopped /= null then
            Stopped (Stop_Reason);
         end if;
   end Shrink;

end Counterweave.Choices;
