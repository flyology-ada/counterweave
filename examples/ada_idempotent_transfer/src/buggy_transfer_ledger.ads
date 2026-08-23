package Buggy_Transfer_Ledger is

   subtype Amount is Positive;
   subtype Account_Id is Positive;
   subtype Transaction_Id is Positive;

   type Ledger
     (Account_Count        : Positive;
      Transaction_Capacity : Positive)
   is
     limited private;

   procedure Initialize (Item : in out Ledger; Initial_Balance : Natural);

   procedure Deposit
     (Item : in out Ledger; Account : Account_Id; Value : Amount);

   procedure Transfer
     (Item        : in out Ledger;
      Transaction : Transaction_Id;
      Source      : Account_Id;
      Destination : Account_Id;
      Value       : Amount;
      Applied     : out Boolean);

   function Balance (Item : Ledger; Account : Account_Id) return Natural;

   Invalid_Account     : exception;
   Invalid_Transaction : exception;
   Insufficient_Funds  : exception;

private

   type Balance_Array is array (Positive range <>) of Natural;
   type Seen_Array is array (Positive range <>) of Boolean;

   type Ledger
     (Account_Count        : Positive;
      Transaction_Capacity : Positive)
   is limited record
      Balances : Balance_Array (1 .. Account_Count) := [others => 0];
      Seen     : Seen_Array (1 .. Transaction_Capacity) := [others => False];
   end record;

end Buggy_Transfer_Ledger;
