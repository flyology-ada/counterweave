with Ada.Containers.Indefinite_Vectors;
with Interfaces;

package Counterweave.Strings is

   package String_Vectors is new
     Ada.Containers.Indefinite_Vectors
       (Index_Type   => Natural,
        Element_Type => String);

   subtype String_Vector is String_Vectors.Vector;

   function Read_File
     (Path : String; Maximum_Bytes : Natural := 16 * 1_024 * 1_024)
      return String;

   procedure Write_File_Atomically (Path : String; Content : String);

   function JSON_String (Value : String) return String;

   function Compact_Image (Value : Long_Long_Integer) return String;

   function Compact_Image (Value : Interfaces.Unsigned_64) return String;

   function Extract_First_JSON (Source : String) return String;

   function Extract_Only_JSON (Source : String) return String;

   function Find_Integer
     (Source : String; Key : String) return Long_Long_Integer;

   function Find_Boolean (Source : String; Key : String) return Boolean;

   function Find_String (Source : String; Key : String) return String;

   Format_Error : exception;
end Counterweave.Strings;
