with Ada.Strings.Unbounded;
with Interfaces;

package Counterweave.JSON is

   type Value_Kind is
     (Null_Value, Boolean_Value, Number_Value, String_Value, Array_Value, Object_Value);

   type Value is private;

   function Parse (Source : String) return Value;

   function Parse_At
     (Source : String;
      First  : Positive;
      Last   : out Natural) return Value;

   function Kind (Item : Value) return Value_Kind;

   function Image (Source : String; Item : Value) return String;

   function Has_Member
     (Source : String; Item : Value; Name : String) return Boolean;

   function Member
     (Source : String; Item : Value; Name : String) return Value;

   function Length (Source : String; Item : Value) return Natural;

   function Element
     (Source : String; Item : Value; Index : Natural) return Value;

   function As_String
     (Source : String; Item : Value)
      return Ada.Strings.Unbounded.Unbounded_String;

   function As_Integer
     (Source : String; Item : Value) return Long_Long_Integer;

   function As_Unsigned
     (Source : String; Item : Value) return Interfaces.Unsigned_64;

   function As_Boolean (Source : String; Item : Value) return Boolean;

   JSON_Error : exception;

private

   type Value is record
      First : Natural := 0;
      Last  : Natural := 0;
      Form  : Value_Kind := Null_Value;
   end record;

end Counterweave.JSON;
