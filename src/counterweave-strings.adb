with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Counterweave.JSON;
with GNAT.OS_Lib;

package body Counterweave.Strings is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;

   protected Temporary_Names is
      procedure Next (Value : out Natural);
   private
      Serial : Natural := 0;
   end Temporary_Names;

   protected body Temporary_Names is
      procedure Next (Value : out Natural) is
      begin
         Serial := Serial + 1;
         Value := Serial;
      end Next;
   end Temporary_Names;

   function Read_File
     (Path : String; Maximum_Bytes : Natural := 16 * 1_024 * 1_024)
      return String
   is
      package IO renames Ada.Streams.Stream_IO;
      File   : IO.File_Type;
      Length : Ada.Streams.Stream_IO.Count;
      Result : Unbounded_String;
      Data   : Ada.Streams.Stream_Element_Array (1 .. 16 * 1_024);
      Last   : Ada.Streams.Stream_Element_Offset;
      Total  : Natural := 0;
   begin
      IO.Open (File, IO.In_File, Path);
      Length := IO.Size (File);
      if Length > Ada.Streams.Stream_IO.Count (Maximum_Bytes) then
         IO.Close (File);
         raise Format_Error
           with "file exceeds configured capture limit: " & Path;
      end if;

      while not IO.End_Of_File (File) loop
         IO.Read (File, Data, Last);
         declare
            Chunk_Length : constant Natural :=
              Natural (Last - Data'First + 1);
         begin
            if Chunk_Length > Maximum_Bytes - Total then
               IO.Close (File);
               raise Format_Error
                 with "file exceeds configured capture limit: " & Path;
            end if;
            Total := Total + Chunk_Length;
         end;
         for Index in Data'First .. Last loop
            Append (Result, Character'Val (Data (Index)));
         end loop;
      end loop;
      IO.Close (File);
      return To_String (Result);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Read_File;

   procedure Write_File_Atomically (Path : String; Content : String) is
      Serial    : Natural;
      File      : Ada.Text_IO.File_Type;
      Renamed   : Boolean;
   begin
      Temporary_Names.Next (Serial);
      declare
         Temporary : constant String :=
           Path
           & ".tmp-"
           & Ada.Strings.Fixed.Trim
               (Integer'Image
                  (GNAT.OS_Lib.Pid_To_Integer
                     (GNAT.OS_Lib.Current_Process_Id)),
                Ada.Strings.Both)
           & "-"
           & Ada.Strings.Fixed.Trim (Natural'Image (Serial), Ada.Strings.Both);
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Temporary);
         Ada.Text_IO.Put (File, Content);
         Ada.Text_IO.Close (File);
         GNAT.OS_Lib.Rename_File (Temporary, Path, Renamed);
         if not Renamed then
            raise Program_Error with "could not replace artifact: " & Path;
         end if;
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
            if Ada.Directories.Exists (Temporary) then
               Ada.Directories.Delete_File (Temporary);
            end if;
            raise;
      end;
   end Write_File_Atomically;

   function JSON_String (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String (String'(1 => '"'));
   begin
      for Item of Value loop
         case Item is
            when '"'                       =>
               Append (Result, '\');
               Append (Result, '"');

            when '\'                       =>
               Append (Result, '\');
               Append (Result, '\');

            when Ada.Characters.Latin_1.LF =>
               Append (Result, '\');
               Append (Result, 'n');

            when Ada.Characters.Latin_1.CR =>
               Append (Result, '\');
               Append (Result, 'r');

            when Ada.Characters.Latin_1.HT =>
               Append (Result, '\');
               Append (Result, 't');

            when others                    =>
               if Character'Pos (Item) < 32 then
                  raise Format_Error
                    with "unsupported control character in JSON string";
               end if;
               Append (Result, Item);
         end case;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end JSON_String;

   function Compact_Image (Value : Long_Long_Integer) return String is
   begin
      return
        Ada.Strings.Fixed.Trim
          (Long_Long_Integer'Image (Value), Ada.Strings.Both);
   end Compact_Image;

   function Compact_Image (Value : Interfaces.Unsigned_64) return String is
   begin
      return
        Ada.Strings.Fixed.Trim
          (Interfaces.Unsigned_64'Image (Value), Ada.Strings.Both);
   end Compact_Image;

   function Extract_First_JSON (Source : String) return String is
      Last : Natural;
   begin
      for Index in Source'Range loop
         if Source (Index) = '{' or else Source (Index) = '[' then
            begin
               declare
                  Ignored : constant Counterweave.JSON.Value :=
                    Counterweave.JSON.Parse_At (Source, Index, Last);
               begin
                  pragma Unreferenced (Ignored);
                  return Source (Index .. Last);
               end;
            exception
               when Counterweave.JSON.JSON_Error =>
                  null;
            end;
         end if;
      end loop;
      raise Format_Error with "no complete JSON value found";
   end Extract_First_JSON;

   function Extract_Only_JSON (Source : String) return String is
      First : Natural := Source'First;
      Last  : Natural := Source'Last;
   begin
      while First <= Source'Last
        and then Source (First) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then Source (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
      loop
         Last := Last - 1;
      end loop;
      if First > Last then
         raise Format_Error with "adapter emitted no JSON value";
      end if;
      declare
         Clean : constant String := Source (First .. Last);
         Ignored : constant Counterweave.JSON.Value :=
           Counterweave.JSON.Parse (Clean);
      begin
         pragma Unreferenced (Ignored);
         return Clean;
      end;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Format_Error with "adapter output is not one valid JSON value";
   end Extract_Only_JSON;

   function Find_Integer
     (Source : String; Key : String) return Long_Long_Integer
   is
      Root : constant Counterweave.JSON.Value := Counterweave.JSON.Parse (Source);
   begin
      return
        Counterweave.JSON.As_Integer
          (Source, Counterweave.JSON.Member (Source, Root, Key));
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Format_Error with "invalid JSON integer field: " & Key;
   end Find_Integer;

   function Find_Boolean (Source : String; Key : String) return Boolean is
      Root : constant Counterweave.JSON.Value := Counterweave.JSON.Parse (Source);
   begin
      return
        Counterweave.JSON.As_Boolean
          (Source, Counterweave.JSON.Member (Source, Root, Key));
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Format_Error with "invalid JSON Boolean field: " & Key;
   end Find_Boolean;

   function Find_String (Source : String; Key : String) return String is
      Root : constant Counterweave.JSON.Value := Counterweave.JSON.Parse (Source);
   begin
      return
        To_String
          (Counterweave.JSON.As_String
             (Source, Counterweave.JSON.Member (Source, Root, Key)));
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Format_Error with "invalid JSON string field: " & Key;
   end Find_String;

end Counterweave.Strings;
