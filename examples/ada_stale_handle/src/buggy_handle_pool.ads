package Buggy_Handle_Pool is

   Max_Capacity : constant := 8;

   subtype Slot_Number is Positive range 1 .. Max_Capacity;

   type Handle is record
      Slot       : Slot_Number := Slot_Number'First;
      Generation : Natural := 0;
   end record;

   type Pool (Capacity : Slot_Number) is limited private;

   procedure Initialize (Container : out Pool);

   function Allocate (Container : in out Pool) return Handle;

   procedure Write (Container : in out Pool; Item : Handle; Value : Integer);

   function Read (Container : Pool; Item : Handle) return Integer;

   procedure Release (Container : in out Pool; Item : Handle);

   Stale_Handle   : exception;
   Pool_Exhausted : exception;

private
   type Slot_State is record
      Active     : Boolean := False;
      Generation : Natural := 0;
      Value      : Integer := 0;
   end record;

   type Slot_Array is array (Slot_Number range <>) of Slot_State;

   type Pool (Capacity : Slot_Number) is limited record
      Slots : Slot_Array (1 .. Capacity);
   end record;

end Buggy_Handle_Pool;
