with Counterweave.Strings;
with Counterweave.JSON;

package body Counterweave.Choices is

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
      Tape := (Root_Seed => Root_Seed, Forks => Fork_Vectors.Empty_Vector);
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
      Threshold  : Choice_Value;
      Value      : Choice_Value;
   begin
      if Maximum = Choice_Value'Last then
         return Draw (Tape, Path);
      end if;
      Range_Size := Maximum + 1;
      Threshold := (-Range_Size) mod Range_Size;
      loop
         Value := Draw (Tape, Path);
         if Value >= Threshold then
            return Value mod Range_Size;
         end if;
      end loop;
   end Draw_Bounded;

   function Seed (Tape : Choice_Tape) return Choice_Value is
   begin
      return Tape.Root_Seed;
   end Seed;

   function To_JSON (Tape : Choice_Tape) return String is
      Result     : Unbounded_String :=
        To_Unbounded_String
          ("{""format"":""counterweave.choices/1"",""algorithm"":""splitmix64-v1"",""root_seed"":"
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
             (Source, Counterweave.JSON.Member (Source, Root_Value, "format")));
      Algorithm  : constant String :=
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root_Value, "algorithm")));
      Forks      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root_Value, "forks");
      Result     : Choice_Tape;
   begin
      if Format /= "counterweave.choices/1" then
         raise Choice_Error with "unsupported choice tape format";
      elsif Algorithm /= "splitmix64-v1" then
         raise Choice_Error with "unsupported choice algorithm";
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
                (Source, Counterweave.JSON.Member (Source, Fork_Value, "path"));
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
            for Value_Index in 0 .. Counterweave.JSON.Length (Source, Values) loop
               exit when Value_Index = Counterweave.JSON.Length (Source, Values);
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

end Counterweave.Choices;
