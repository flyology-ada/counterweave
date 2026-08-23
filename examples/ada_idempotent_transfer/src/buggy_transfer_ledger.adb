package body Buggy_Transfer_Ledger is

   procedure Check_Account (Item : Ledger; Account : Account_Id) is
   begin
      if Account > Item.Account_Count then
         raise Invalid_Account;
      end if;
   end Check_Account;

   procedure Initialize (Item : in out Ledger; Initial_Balance : Natural) is
   begin
      Item.Balances := [others => Initial_Balance];
      Item.Seen := [others => False];
   end Initialize;

   procedure Deposit
     (Item : in out Ledger; Account : Account_Id; Value : Amount) is
   begin
      Check_Account (Item, Account);
      Item.Balances (Account) := Item.Balances (Account) + Value;
   end Deposit;

   procedure Transfer
     (Item        : in out Ledger;
      Transaction : Transaction_Id;
      Source      : Account_Id;
      Destination : Account_Id;
      Value       : Amount;
      Applied     : out Boolean) is
   begin
      Check_Account (Item, Source);
      Check_Account (Item, Destination);
      if Transaction > Item.Transaction_Capacity then
         raise Invalid_Transaction;
      elsif Item.Balances (Source) < Value then
         raise Insufficient_Funds;
      end if;

      -- The defect: a seen transaction should return Applied = False before
      -- touching either balance. This implementation records the key but
      -- applies every retry again.
      Item.Seen (Transaction) := True;
      Item.Balances (Source) := Item.Balances (Source) - Value;
      Item.Balances (Destination) := Item.Balances (Destination) + Value;
      Applied := True;
   end Transfer;

   function Balance (Item : Ledger; Account : Account_Id) return Natural is
   begin
      Check_Account (Item, Account);
      return Item.Balances (Account);
   end Balance;

end Buggy_Transfer_Ledger;
