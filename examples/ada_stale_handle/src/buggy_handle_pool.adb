package body Buggy_Handle_Pool is

   procedure Validate (Container : Pool; Item : Handle) is
   begin
      if Item.Slot > Container.Capacity
        or else not Container.Slots (Item.Slot).Active
        or else Container.Slots (Item.Slot).Generation /= Item.Generation
      then
         raise Stale_Handle;
      end if;
   end Validate;

   procedure Initialize (Container : out Pool) is
   begin
      Container.Slots := [others => <>];
   end Initialize;

   function Allocate (Container : in out Pool) return Handle is
   begin
      for Slot in Container.Slots'Range loop
         if not Container.Slots (Slot).Active then
            Container.Slots (Slot).Active := True;
            if Container.Slots (Slot).Generation = 0 then
               Container.Slots (Slot).Generation := 1;
            end if;
            --  Intentional example bug: reuse must increment Generation here.
            return
              (Slot => Slot, Generation => Container.Slots (Slot).Generation);
         end if;
      end loop;
      raise Pool_Exhausted;
   end Allocate;

   procedure Write (Container : in out Pool; Item : Handle; Value : Integer) is
   begin
      Validate (Container, Item);
      Container.Slots (Item.Slot).Value := Value;
   end Write;

   function Read (Container : Pool; Item : Handle) return Integer is
   begin
      Validate (Container, Item);
      return Container.Slots (Item.Slot).Value;
   end Read;

   procedure Release (Container : in out Pool; Item : Handle) is
   begin
      Validate (Container, Item);
      Container.Slots (Item.Slot).Active := False;
   end Release;

end Buggy_Handle_Pool;
