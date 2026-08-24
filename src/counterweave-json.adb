with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Fixed;

package body Counterweave.JSON is

   use Ada.Strings.Unbounded;

   package String_Sets is new
     Ada.Containers.Indefinite_Ordered_Sets (Element_Type => String);

   package Canonical_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => String);

   procedure Skip_Whitespace (Source : String; Cursor : in out Natural) is
   begin
      while Cursor <= Source'Last
        and then Source (Cursor) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
      loop
         Cursor := Cursor + 1;
      end loop;
   end Skip_Whitespace;

   function Hex_Value (Item : Character) return Natural is
   begin
      case Item is
         when '0' .. '9' =>
            return Character'Pos (Item) - Character'Pos ('0');

         when 'a' .. 'f' =>
            return Character'Pos (Item) - Character'Pos ('a') + 10;

         when 'A' .. 'F' =>
            return Character'Pos (Item) - Character'Pos ('A') + 10;

         when others     =>
            raise JSON_Error with "invalid hexadecimal JSON escape";
      end case;
   end Hex_Value;

   function Hex_Code (Source : String; First : Positive) return Natural is
      Result : Natural := 0;
   begin
      if First + 3 > Source'Last then
         raise JSON_Error with "truncated Unicode JSON escape";
      end if;
      for Index in First .. First + 3 loop
         Result := Result * 16 + Hex_Value (Source (Index));
      end loop;
      return Result;
   end Hex_Code;

   procedure Append_UTF8 (Result : in out Unbounded_String; Code : Natural) is
   begin
      if Code <= 16#7F# then
         Append (Result, Character'Val (Code));
      elsif Code <= 16#7FF# then
         Append (Result, Character'Val (16#C0# + Code / 64));
         Append (Result, Character'Val (16#80# + Code mod 64));
      elsif Code <= 16#FFFF# then
         Append (Result, Character'Val (16#E0# + Code / 4_096));
         Append (Result, Character'Val (16#80# + (Code / 64) mod 64));
         Append (Result, Character'Val (16#80# + Code mod 64));
      elsif Code <= 16#10FFFF# then
         Append (Result, Character'Val (16#F0# + Code / 262_144));
         Append (Result, Character'Val (16#80# + (Code / 4_096) mod 64));
         Append (Result, Character'Val (16#80# + (Code / 64) mod 64));
         Append (Result, Character'Val (16#80# + Code mod 64));
      else
         raise JSON_Error with "Unicode JSON escape is out of range";
      end if;
   end Append_UTF8;

   procedure Parse_String_End (Source : String; Cursor : in out Natural) is
   begin
      if Cursor > Source'Last or else Source (Cursor) /= '"' then
         raise JSON_Error with "expected JSON string";
      end if;
      Cursor := Cursor + 1;
      while Cursor <= Source'Last loop
         case Source (Cursor) is
            when '"'    =>
               Cursor := Cursor + 1;
               return;

            when '\'    =>
               Cursor := Cursor + 1;
               if Cursor > Source'Last
                 or else Source (Cursor)
                         not in '"'
                              | '\'
                              | '/'
                              | 'b'
                              | 'f'
                              | 'n'
                              | 'r'
                              | 't'
                              | 'u'
               then
                  raise JSON_Error with "invalid JSON string escape";
               end if;
               if Source (Cursor) = 'u' then
                  if Cursor + 4 > Source'Last then
                     raise JSON_Error with "truncated Unicode JSON escape";
                  end if;
                  for Index in Cursor + 1 .. Cursor + 4 loop
                     declare
                        Ignored : constant Natural :=
                          Hex_Value (Source (Index));
                     begin
                        pragma Unreferenced (Ignored);
                     end;
                  end loop;
                  Cursor := Cursor + 4;
               end if;
               Cursor := Cursor + 1;

            when others =>
               if Character'Pos (Source (Cursor)) < 32 then
                  raise JSON_Error with "control character in JSON string";
               end if;
               Cursor := Cursor + 1;
         end case;
      end loop;
      raise JSON_Error with "unterminated JSON string";
   end Parse_String_End;

   procedure Parse_Value
     (Source : String; Cursor : in out Natural; Item : out Value);

   function Decode_String
     (Source : String; Item : Value) return Unbounded_String;

   procedure Expect_Literal
     (Source : String; Cursor : in out Natural; Literal : String) is
   begin
      if Cursor + Literal'Length - 1 > Source'Last
        or else Source (Cursor .. Cursor + Literal'Length - 1) /= Literal
      then
         raise JSON_Error with "invalid JSON literal";
      end if;
      Cursor := Cursor + Literal'Length;
   end Expect_Literal;

   procedure Parse_Number_End (Source : String; Cursor : in out Natural) is
   begin
      if Source (Cursor) = '-' then
         Cursor := Cursor + 1;
         if Cursor > Source'Last then
            raise JSON_Error with "truncated JSON number";
         end if;
      end if;
      if Source (Cursor) = '0' then
         Cursor := Cursor + 1;
         if Cursor <= Source'Last and then Source (Cursor) in '0' .. '9' then
            raise JSON_Error with "leading zero in JSON number";
         end if;
      elsif Source (Cursor) in '1' .. '9' then
         while Cursor <= Source'Last and then Source (Cursor) in '0' .. '9'
         loop
            Cursor := Cursor + 1;
         end loop;
      else
         raise JSON_Error with "invalid JSON number";
      end if;
      if Cursor <= Source'Last and then Source (Cursor) = '.' then
         Cursor := Cursor + 1;
         if Cursor > Source'Last or else Source (Cursor) not in '0' .. '9' then
            raise JSON_Error with "invalid JSON fraction";
         end if;
         while Cursor <= Source'Last and then Source (Cursor) in '0' .. '9'
         loop
            Cursor := Cursor + 1;
         end loop;
      end if;
      if Cursor <= Source'Last and then Source (Cursor) in 'e' | 'E' then
         Cursor := Cursor + 1;
         if Cursor <= Source'Last and then Source (Cursor) in '+' | '-' then
            Cursor := Cursor + 1;
         end if;
         if Cursor > Source'Last or else Source (Cursor) not in '0' .. '9' then
            raise JSON_Error with "invalid JSON exponent";
         end if;
         while Cursor <= Source'Last and then Source (Cursor) in '0' .. '9'
         loop
            Cursor := Cursor + 1;
         end loop;
      end if;
   end Parse_Number_End;

   procedure Parse_Array_End (Source : String; Cursor : in out Natural) is
      Child : Value;
   begin
      Cursor := Cursor + 1;
      Skip_Whitespace (Source, Cursor);
      if Cursor <= Source'Last and then Source (Cursor) = ']' then
         Cursor := Cursor + 1;
         return;
      end if;
      loop
         Parse_Value (Source, Cursor, Child);
         Skip_Whitespace (Source, Cursor);
         if Cursor > Source'Last then
            raise JSON_Error with "unterminated JSON array";
         elsif Source (Cursor) = ']' then
            Cursor := Cursor + 1;
            return;
         elsif Source (Cursor) /= ',' then
            raise JSON_Error with "expected comma in JSON array";
         end if;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
      end loop;
   end Parse_Array_End;

   procedure Parse_Object_End (Source : String; Cursor : in out Natural) is
      Child : Value;
      Seen  : String_Sets.Set;
   begin
      Cursor := Cursor + 1;
      Skip_Whitespace (Source, Cursor);
      if Cursor <= Source'Last and then Source (Cursor) = '}' then
         Cursor := Cursor + 1;
         return;
      end if;
      loop
         declare
            Key_First : constant Natural := Cursor;
         begin
            Parse_String_End (Source, Cursor);
            declare
               Key : constant String :=
                 To_String
                   (Decode_String
                      (Source,
                       (First => Key_First,
                        Last  => Cursor - 1,
                        Form  => String_Value)));
            begin
               if Seen.Contains (Key) then
                  raise JSON_Error with "duplicate JSON object member: " & Key;
               end if;
               Seen.Insert (Key);
            end;
         end;
         Skip_Whitespace (Source, Cursor);
         if Cursor > Source'Last or else Source (Cursor) /= ':' then
            raise JSON_Error with "expected colon in JSON object";
         end if;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
         Parse_Value (Source, Cursor, Child);
         Skip_Whitespace (Source, Cursor);
         if Cursor > Source'Last then
            raise JSON_Error with "unterminated JSON object";
         elsif Source (Cursor) = '}' then
            Cursor := Cursor + 1;
            return;
         elsif Source (Cursor) /= ',' then
            raise JSON_Error with "expected comma in JSON object";
         end if;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
      end loop;
   end Parse_Object_End;

   procedure Parse_Value
     (Source : String; Cursor : in out Natural; Item : out Value)
   is
      First : Natural;
      Form  : Value_Kind;
   begin
      Skip_Whitespace (Source, Cursor);
      if Cursor > Source'Last then
         raise JSON_Error with "expected JSON value";
      end if;
      First := Cursor;
      case Source (Cursor) is
         when 'n'              =>
            Expect_Literal (Source, Cursor, "null");
            Form := Null_Value;

         when 't'              =>
            Expect_Literal (Source, Cursor, "true");
            Form := Boolean_Value;

         when 'f'              =>
            Expect_Literal (Source, Cursor, "false");
            Form := Boolean_Value;

         when '"'              =>
            Parse_String_End (Source, Cursor);
            Form := String_Value;

         when '['              =>
            Parse_Array_End (Source, Cursor);
            Form := Array_Value;

         when '{'              =>
            Parse_Object_End (Source, Cursor);
            Form := Object_Value;

         when '-' | '0' .. '9' =>
            Parse_Number_End (Source, Cursor);
            Form := Number_Value;

         when others           =>
            raise JSON_Error with "invalid JSON value";
      end case;
      Item := (First => First, Last => Cursor - 1, Form => Form);
   end Parse_Value;

   function Parse (Source : String) return Value is
      Cursor : Natural := Source'First;
      Result : Value;
   begin
      if Source'Length = 0 then
         raise JSON_Error with "empty JSON document";
      end if;
      Parse_Value (Source, Cursor, Result);
      Skip_Whitespace (Source, Cursor);
      if Cursor <= Source'Last then
         raise JSON_Error with "data follows JSON value";
      end if;
      return Result;
   end Parse;

   function Parse_At
     (Source : String; First : Positive; Last : out Natural) return Value
   is
      Cursor : Natural := First;
      Result : Value;
   begin
      Parse_Value (Source, Cursor, Result);
      Last := Result.Last;
      return Result;
   end Parse_At;

   function Kind (Item : Value) return Value_Kind
   is (Item.Form);

   function Image (Source : String; Item : Value) return String is
   begin
      if Item.First = 0
        or else Item.Last < Item.First
        or else Item.Last > Source'Last
      then
         raise JSON_Error with "invalid JSON value view";
      end if;
      return Source (Item.First .. Item.Last);
   end Image;

   function Quoted (Value : String) return String is
      Hex    : constant String := "0123456789abcdef";
      Result : Unbounded_String := To_Unbounded_String (String'(1 => '"'));
   begin
      for Item of Value loop
         if Item = '"' or else Item = '\' then
            Append (Result, '\');
            Append (Result, Item);
         elsif Character'Pos (Item) < 32 then
            Append
              (Result,
               "\u00"
               & Hex (Character'Pos (Item) / 16 + 1)
               & Hex (Character'Pos (Item) mod 16 + 1));
         else
            Append (Result, Item);
         end if;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Quoted;

   function Normalize_Decimal_Integer (Text : String) return String is
      Cursor   : Natural := Text'First;
      Negative : Boolean := False;
   begin
      if Cursor <= Text'Last and then Text (Cursor) in '+' | '-' then
         Negative := Text (Cursor) = '-';
         Cursor := Cursor + 1;
      end if;
      while Cursor <= Text'Last and then Text (Cursor) = '0' loop
         Cursor := Cursor + 1;
      end loop;
      if Cursor > Text'Last then
         return "0";
      end if;
      return (if Negative then "-" else "") & Text (Cursor .. Text'Last);
   end Normalize_Decimal_Integer;

   function Magnitude (Value : String) return String
   is (if Value (Value'First) = '-'
       then Value (Value'First + 1 .. Value'Last)
       else Value);

   function Add_Magnitudes (Left, Right : String) return String is
      Result      : String (1 .. Natural'Max (Left'Length, Right'Length) + 1);
      Left_Index  : Integer := Left'Last;
      Right_Index : Integer := Right'Last;
      Put_Index   : Natural := Result'Last;
      Carry       : Natural := 0;
   begin
      while Left_Index >= Left'First
        or else Right_Index >= Right'First
        or else Carry /= 0
      loop
         declare
            Digit : Natural := Carry;
         begin
            if Left_Index >= Left'First then
               Digit :=
                 Digit
                 + Character'Pos (Left (Left_Index))
                 - Character'Pos ('0');
               Left_Index := Left_Index - 1;
            end if;
            if Right_Index >= Right'First then
               Digit :=
                 Digit
                 + Character'Pos (Right (Right_Index))
                 - Character'Pos ('0');
               Right_Index := Right_Index - 1;
            end if;
            Result (Put_Index) :=
              Character'Val (Character'Pos ('0') + Digit mod 10);
            Carry := Digit / 10;
            Put_Index := Put_Index - 1;
         end;
      end loop;
      return Result (Put_Index + 1 .. Result'Last);
   end Add_Magnitudes;

   function Compare_Magnitudes (Left, Right : String) return Integer is
   begin
      if Left'Length < Right'Length then
         return -1;
      elsif Left'Length > Right'Length then
         return 1;
      elsif Left < Right then
         return -1;
      elsif Left > Right then
         return 1;
      end if;
      return 0;
   end Compare_Magnitudes;

   function Subtract_Magnitudes (Left, Right : String) return String is
      Result      : String (1 .. Left'Length);
      Left_Index  : Integer := Left'Last;
      Right_Index : Integer := Right'Last;
      Put_Index   : Natural := Result'Last;
      Borrow      : Integer := 0;
   begin
      while Left_Index >= Left'First loop
         declare
            Digit : Integer :=
              Character'Pos (Left (Left_Index)) - Character'Pos ('0') - Borrow;
         begin
            if Right_Index >= Right'First then
               Digit :=
                 Digit
                 - Character'Pos (Right (Right_Index))
                 + Character'Pos ('0');
               Right_Index := Right_Index - 1;
            end if;
            if Digit < 0 then
               Digit := Digit + 10;
               Borrow := 1;
            else
               Borrow := 0;
            end if;
            Result (Put_Index) := Character'Val (Character'Pos ('0') + Digit);
            Left_Index := Left_Index - 1;
            Put_Index := Put_Index - 1;
         end;
      end loop;
      declare
         First : Natural := Result'First;
      begin
         while First < Result'Last and then Result (First) = '0' loop
            First := First + 1;
         end loop;
         return Result (First .. Result'Last);
      end;
   end Subtract_Magnitudes;

   function Add_Decimal_Integer
     (Left : String; Right : Long_Long_Integer) return String
   is
      Normalized_Left  : constant String := Normalize_Decimal_Integer (Left);
      Normalized_Right : constant String :=
        Normalize_Decimal_Integer
          (Ada.Strings.Fixed.Trim
             (Long_Long_Integer'Image (Right), Ada.Strings.Both));
      Left_Negative    : constant Boolean :=
        Normalized_Left (Normalized_Left'First) = '-';
      Right_Negative   : constant Boolean :=
        Normalized_Right (Normalized_Right'First) = '-';
      Left_Magnitude   : constant String := Magnitude (Normalized_Left);
      Right_Magnitude  : constant String := Magnitude (Normalized_Right);
   begin
      if Normalized_Left = "0" then
         return Normalized_Right;
      elsif Normalized_Right = "0" then
         return Normalized_Left;
      elsif Left_Negative = Right_Negative then
         return
           (if Left_Negative then "-" else "")
           & Add_Magnitudes (Left_Magnitude, Right_Magnitude);
      end if;
      case Compare_Magnitudes (Left_Magnitude, Right_Magnitude) is
         when -1     =>
            return
              (if Right_Negative then "-" else "")
              & Subtract_Magnitudes (Right_Magnitude, Left_Magnitude);

         when 0      =>
            return "0";

         when others =>
            return
              (if Left_Negative then "-" else "")
              & Subtract_Magnitudes (Left_Magnitude, Right_Magnitude);
      end case;
   end Add_Decimal_Integer;

   function Canonical_Number (Text : String) return String is
      Cursor          : Natural := Text'First;
      Negative        : Boolean := False;
      Fraction_Length : Natural := 0;
      Digit_Buffer    : Unbounded_String;
      Exponent        : Unbounded_String := To_Unbounded_String ("0");
   begin
      if Text (Cursor) = '-' then
         Negative := True;
         Cursor := Cursor + 1;
      end if;
      while Cursor <= Text'Last and then Text (Cursor) in '0' .. '9' loop
         Append (Digit_Buffer, Text (Cursor));
         Cursor := Cursor + 1;
      end loop;
      if Cursor <= Text'Last and then Text (Cursor) = '.' then
         Cursor := Cursor + 1;
         while Cursor <= Text'Last and then Text (Cursor) in '0' .. '9' loop
            Append (Digit_Buffer, Text (Cursor));
            Fraction_Length := Fraction_Length + 1;
            Cursor := Cursor + 1;
         end loop;
      end if;
      if Cursor <= Text'Last and then Text (Cursor) in 'e' | 'E' then
         Exponent :=
           To_Unbounded_String
             (Normalize_Decimal_Integer (Text (Cursor + 1 .. Text'Last)));
      end if;

      declare
         All_Digits : constant String := To_String (Digit_Buffer);
         First      : Natural := All_Digits'First;
         Last       : Natural := All_Digits'Last;
         Removed    : Natural := 0;
      begin
         while First <= Last and then All_Digits (First) = '0' loop
            First := First + 1;
         end loop;
         if First > Last then
            return "0";
         end if;
         while Last > First and then All_Digits (Last) = '0' loop
            Last := Last - 1;
            Removed := Removed + 1;
         end loop;
         declare
            Adjusted_Exponent : constant String :=
              Add_Decimal_Integer
                (To_String (Exponent),
                 Long_Long_Integer (Removed)
                 - Long_Long_Integer (Fraction_Length));
            Significant       : constant String := All_Digits (First .. Last);
         begin
            return
              (if Negative then "-" else "")
              & Significant
              & (if Adjusted_Exponent = "0"
                 then ""
                 else "e" & Adjusted_Exponent);
         end;
      end;
   end Canonical_Number;

   function Canonical_Image (Source : String; Item : Value) return String is
      function Canonical (Node : Value) return String;

      function Canonical (Node : Value) return String is
      begin
         case Node.Form is
            when Null_Value    =>
               return "null";

            when Boolean_Value =>
               return (if As_Boolean (Source, Node) then "true" else "false");

            when Number_Value  =>
               return Canonical_Number (Image (Source, Node));

            when String_Value  =>
               return Quoted (To_String (Decode_String (Source, Node)));

            when Array_Value   =>
               declare
                  Cursor : Natural := Node.First + 1;
                  Child  : Value;
                  Result : Unbounded_String := To_Unbounded_String ("[");
                  First  : Boolean := True;
               begin
                  Skip_Whitespace (Source, Cursor);
                  while Cursor < Node.Last loop
                     Parse_Value (Source, Cursor, Child);
                     if First then
                        First := False;
                     else
                        Append (Result, ",");
                     end if;
                     Append (Result, Canonical (Child));
                     Skip_Whitespace (Source, Cursor);
                     exit when Cursor >= Node.Last;
                     Cursor := Cursor + 1;
                     Skip_Whitespace (Source, Cursor);
                  end loop;
                  Append (Result, "]");
                  return To_String (Result);
               end;

            when Object_Value  =>
               declare
                  Cursor  : Natural := Node.First + 1;
                  Key     : Value;
                  Child   : Value;
                  Members : Canonical_Maps.Map;
                  Result  : Unbounded_String := To_Unbounded_String ("{");
                  First   : Boolean := True;
               begin
                  Skip_Whitespace (Source, Cursor);
                  while Cursor < Node.Last loop
                     declare
                        Key_First : constant Natural := Cursor;
                     begin
                        Parse_String_End (Source, Cursor);
                        Key :=
                          (First => Key_First,
                           Last  => Cursor - 1,
                           Form  => String_Value);
                     end;
                     Skip_Whitespace (Source, Cursor);
                     Cursor := Cursor + 1;
                     Skip_Whitespace (Source, Cursor);
                     Parse_Value (Source, Cursor, Child);
                     Members.Insert
                       (To_String (Decode_String (Source, Key)),
                        Canonical (Child));
                     Skip_Whitespace (Source, Cursor);
                     exit when Cursor >= Node.Last;
                     Cursor := Cursor + 1;
                     Skip_Whitespace (Source, Cursor);
                  end loop;
                  for Position in Members.Iterate loop
                     if First then
                        First := False;
                     else
                        Append (Result, ",");
                     end if;
                     Append
                       (Result,
                        Quoted (Canonical_Maps.Key (Position))
                        & ":"
                        & Canonical_Maps.Element (Position));
                  end loop;
                  Append (Result, "}");
                  return To_String (Result);
               end;
         end case;
      end Canonical;
   begin
      return Canonical (Item);
   end Canonical_Image;

   function Decode_String
     (Source : String; Item : Value) return Unbounded_String
   is
      Cursor : Natural := Item.First + 1;
      Result : Unbounded_String;
   begin
      if Item.Form /= String_Value then
         raise JSON_Error with "JSON value is not a string";
      end if;
      while Cursor < Item.Last loop
         if Source (Cursor) /= '\' then
            Append (Result, Source (Cursor));
            Cursor := Cursor + 1;
         else
            Cursor := Cursor + 1;
            case Source (Cursor) is
               when '"' | '\' | '/' =>
                  Append (Result, Source (Cursor));
                  Cursor := Cursor + 1;

               when 'b'             =>
                  Append (Result, ASCII.BS);
                  Cursor := Cursor + 1;

               when 'f'             =>
                  Append (Result, ASCII.FF);
                  Cursor := Cursor + 1;

               when 'n'             =>
                  Append (Result, ASCII.LF);
                  Cursor := Cursor + 1;

               when 'r'             =>
                  Append (Result, ASCII.CR);
                  Cursor := Cursor + 1;

               when 't'             =>
                  Append (Result, ASCII.HT);
                  Cursor := Cursor + 1;

               when 'u'             =>
                  declare
                     Code : Natural := Hex_Code (Source, Cursor + 1);
                  begin
                     Cursor := Cursor + 5;
                     if Code in 16#D800# .. 16#DBFF# then
                        if Cursor + 5 >= Item.Last
                          or else Source (Cursor) /= '\'
                          or else Source (Cursor + 1) /= 'u'
                        then
                           raise JSON_Error
                             with "unpaired high Unicode surrogate";
                        end if;
                        declare
                           Low : constant Natural :=
                             Hex_Code (Source, Cursor + 2);
                        begin
                           if Low not in 16#DC00# .. 16#DFFF# then
                              raise JSON_Error
                                with "invalid low Unicode surrogate";
                           end if;
                           Code :=
                             16#10000#
                             + (Code - 16#D800#) * 1_024
                             + Low
                             - 16#DC00#;
                           Cursor := Cursor + 6;
                        end;
                     elsif Code in 16#DC00# .. 16#DFFF# then
                        raise JSON_Error with "unpaired low Unicode surrogate";
                     end if;
                     Append_UTF8 (Result, Code);
                  end;

               when others          =>
                  raise JSON_Error with "invalid JSON string escape";
            end case;
         end if;
      end loop;
      return Result;
   end Decode_String;

   function As_String (Source : String; Item : Value) return Unbounded_String
   is (Decode_String (Source, Item));

   function Member (Source : String; Item : Value; Name : String) return Value
   is
      Cursor     : Natural := Item.First + 1;
      Key        : Value;
      Value_Item : Value;
   begin
      if Item.Form /= Object_Value then
         raise JSON_Error with "JSON value is not an object";
      end if;
      Skip_Whitespace (Source, Cursor);
      while Cursor < Item.Last loop
         declare
            Key_First : constant Natural := Cursor;
         begin
            Parse_String_End (Source, Cursor);
            Key :=
              (First => Key_First, Last => Cursor - 1, Form => String_Value);
         end;
         Skip_Whitespace (Source, Cursor);
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
         Parse_Value (Source, Cursor, Value_Item);
         if Decode_String (Source, Key) = Name then
            return Value_Item;
         end if;
         Skip_Whitespace (Source, Cursor);
         exit when Cursor >= Item.Last;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
      end loop;
      raise JSON_Error with "JSON object member not found: " & Name;
   end Member;

   function Has_Member
     (Source : String; Item : Value; Name : String) return Boolean is
   begin
      declare
         Ignored : constant Value := Member (Source, Item, Name);
      begin
         pragma Unreferenced (Ignored);
         return True;
      end;
   exception
      when JSON_Error =>
         return False;
   end Has_Member;

   function Length (Source : String; Item : Value) return Natural is
      Cursor : Natural := Item.First + 1;
      Child  : Value;
      Result : Natural := 0;
   begin
      if Item.Form /= Array_Value then
         raise JSON_Error with "JSON value is not an array";
      end if;
      Skip_Whitespace (Source, Cursor);
      while Cursor < Item.Last loop
         Parse_Value (Source, Cursor, Child);
         Result := Result + 1;
         Skip_Whitespace (Source, Cursor);
         exit when Cursor >= Item.Last;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
      end loop;
      return Result;
   end Length;

   function Element
     (Source : String; Item : Value; Index : Natural) return Value
   is
      Cursor  : Natural := Item.First + 1;
      Child   : Value;
      Current : Natural := 0;
   begin
      if Item.Form /= Array_Value then
         raise JSON_Error with "JSON value is not an array";
      end if;
      Skip_Whitespace (Source, Cursor);
      while Cursor < Item.Last loop
         Parse_Value (Source, Cursor, Child);
         if Current = Index then
            return Child;
         end if;
         Current := Current + 1;
         Skip_Whitespace (Source, Cursor);
         exit when Cursor >= Item.Last;
         Cursor := Cursor + 1;
         Skip_Whitespace (Source, Cursor);
      end loop;
      raise JSON_Error with "JSON array index is out of range";
   end Element;

   function As_Integer (Source : String; Item : Value) return Long_Long_Integer
   is
   begin
      if Item.Form /= Number_Value then
         raise JSON_Error with "JSON value is not a number";
      end if;
      declare
         Text : constant String := Image (Source, Item);
      begin
         if (for some Character of Text => Character in '.' | 'e' | 'E') then
            raise JSON_Error with "JSON number is not an integer";
         end if;
         return Long_Long_Integer'Value (Text);
      exception
         when Constraint_Error =>
            raise JSON_Error with "JSON integer is out of range";
      end;
   end As_Integer;

   function As_Unsigned
     (Source : String; Item : Value) return Interfaces.Unsigned_64 is
   begin
      if Item.Form = String_Value then
         return
           Interfaces.Unsigned_64'Value
             (To_String (Decode_String (Source, Item)));
      elsif Item.Form = Number_Value then
         return Interfaces.Unsigned_64'Value (Image (Source, Item));
      else
         raise JSON_Error with "JSON value is not an unsigned integer";
      end if;
   exception
      when Constraint_Error =>
         raise JSON_Error with "JSON unsigned integer is out of range";
   end As_Unsigned;

   function As_Boolean (Source : String; Item : Value) return Boolean is
   begin
      if Item.Form /= Boolean_Value then
         raise JSON_Error with "JSON value is not a Boolean";
      end if;
      return Source (Item.First .. Item.Last) = "true";
   end As_Boolean;

end Counterweave.JSON;
