with Flyology_TUI.Surfaces;
with Flyology_TUI.Themes;

package Counterweave.Trace_Views is

   function Matched_Mark return Wide_Wide_String;

   function Diverged_Mark return Wide_Wide_String;

   function Violated_Mark return Wide_Wide_String;

   function Step_Count (Source : String) return Natural;

   function Render
     (Source       : String;
      Width        : Positive;
      Theme        : Flyology_TUI.Themes.Theme;
      Maximum_Rows : Positive := 8;
      Compact      : Boolean := False) return Flyology_TUI.Surfaces.Surface;

end Counterweave.Trace_Views;
