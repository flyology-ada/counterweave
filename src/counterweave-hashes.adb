with Ada.Streams;
with Ada.Streams.Stream_IO;
with GNAT.SHA256;

package body Counterweave.Hashes is

   use type Ada.Streams.Stream_Element_Offset;

   function SHA256 (Content : String) return String is
   begin
      return GNAT.SHA256.Digest (Content);
   end SHA256;

   function SHA256_File (Path : String) return String is
      package IO renames Ada.Streams.Stream_IO;
      File    : IO.File_Type;
      Context : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 16 * 1_024);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      IO.Open (File, IO.In_File, Path);
      while not IO.End_Of_File (File) loop
         IO.Read (File, Buffer, Last);
         GNAT.SHA256.Update (Context, Buffer (Buffer'First .. Last));
      end loop;
      IO.Close (File);
      return GNAT.SHA256.Digest (Context);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end SHA256_File;

end Counterweave.Hashes;
