generic
   Title : String;
   with procedure Action;
package Counterweave.Terminal_UI is

   function Interactive return Boolean;

   procedure Run;

   Action_Error : exception;

end Counterweave.Terminal_UI;
