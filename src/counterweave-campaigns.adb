with Ada.Directories;
with Counterweave.Artifacts;
with Counterweave.Hashes;
with Counterweave.JSON;

package body Counterweave.Campaigns is

   use type Counterweave.JSON.Value_Kind;

   function Optional_String (Value : String) return String
   is (if Value'Length = 0
       then "null"
       else Counterweave.Strings.JSON_String (Value));

   function Optional_File_Hash (Path : String) return String
   is (if Path'Length = 0 or else not Ada.Directories.Exists (Path)
       then "null"
       else
         Counterweave.Strings.JSON_String
           (Counterweave.Hashes.SHA256_File (Path)));

   function Optional_Case_Replay_Hash (Path : String) return String
   is (if Path'Length = 0 or else not Ada.Directories.Exists (Path)
       then "null"
       else
         Counterweave.Strings.JSON_String
           (Counterweave.Artifacts.Case_Replay_SHA256
              (Counterweave.Strings.Read_File (Path))));

   function Strings_JSON
     (Items : Counterweave.Strings.String_Vector) return String
   is
      Result : Unbounded_String := To_Unbounded_String ("[");
      First  : Boolean := True;
   begin
      for Item of Items loop
         if First then
            First := False;
         else
            Append (Result, ",");
         end if;
         Append (Result, Counterweave.Strings.JSON_String (Item));
      end loop;
      Append (Result, "]");
      return To_String (Result);
   end Strings_JSON;

   procedure Start
     (Log               : out Campaign_Log;
      Root_Seed         : Interfaces.Unsigned_64;
      Maximum_Trials    : Positive;
      Model_Path        : String;
      Data_Path         : String;
      Solver            : String;
      Pack_Name         : String;
      Pack_Version      : String;
      Intent            : String;
      Target            : String;
      Adapter           : String;
      Draws             : Counterweave.Strings.String_Vector;
      Adapter_Arguments : Counterweave.Strings.String_Vector;
      Solver_Timeout    : Positive;
      Adapter_Timeout   : Positive;
      Case_Output       : String;
      Run_Output        : String) is
   begin
      Log.Root_Seed := Root_Seed;
      Log.Maximum_Trials := Maximum_Trials;
      Log.Model_Path := To_Unbounded_String (Model_Path);
      Log.Model_SHA256 :=
        To_Unbounded_String (Counterweave.Hashes.SHA256_File (Model_Path));
      Log.Data_Path := To_Unbounded_String (Data_Path);
      if Data_Path'Length > 0 then
         Log.Data_SHA256 :=
           To_Unbounded_String (Counterweave.Hashes.SHA256_File (Data_Path));
      end if;
      Log.Solver := To_Unbounded_String (Solver);
      Log.Pack_Name := To_Unbounded_String (Pack_Name);
      Log.Pack_Version := To_Unbounded_String (Pack_Version);
      Log.Intent := To_Unbounded_String (Intent);
      Log.Target := To_Unbounded_String (Target);
      Log.Adapter := To_Unbounded_String (Adapter);
      Log.Adapter_SHA256 :=
        To_Unbounded_String
          (Counterweave.Artifacts.Executable_SHA256 (Adapter));
      Log.Draws := Draws;
      Log.Adapter_Arguments := Adapter_Arguments;
      Log.Solver_Timeout := Solver_Timeout;
      Log.Adapter_Timeout := Adapter_Timeout;
      Log.Case_Output := To_Unbounded_String (Case_Output);
      Log.Run_Output := To_Unbounded_String (Run_Output);
      Log.Status := To_Unbounded_String ("running");
      Log.Attempts_JSON := To_Unbounded_String ("[");
      Log.First_Attempt := True;
   end Start;

   procedure Append_Attempt
     (Log                 : in out Campaign_Log;
      Index               : Positive;
      Seed                : Interfaces.Unsigned_64;
      Outcome             : String;
      Detail              : String;
      Property_Name       : String;
      Failure_Fingerprint : String;
      Case_Path           : String;
      Run_Path            : String) is
   begin
      if Log.First_Attempt then
         Log.First_Attempt := False;
      else
         Append (Log.Attempts_JSON, ",");
      end if;
      Append
        (Log.Attempts_JSON,
         "{""index"":"
         & Counterweave.Strings.Compact_Image (Long_Long_Integer (Index))
         & ",""seed"":"
         & Counterweave.Strings.JSON_String
             (Counterweave.Strings.Compact_Image (Seed))
         & ",""outcome"":"
         & Counterweave.Strings.JSON_String (Outcome)
         & ",""detail"":"
         & Counterweave.Strings.JSON_String (Detail)
         & ",""property"":"
         & Optional_String (Property_Name)
         & ",""failure_fingerprint"":"
         & Optional_String (Failure_Fingerprint)
         & ",""case_sha256"":"
         & Optional_File_Hash (Case_Path)
         & ",""case_replay_sha256"":"
         & Optional_Case_Replay_Hash (Case_Path)
         & ",""run_sha256"":"
         & Optional_File_Hash (Run_Path)
         & "}");
   end Append_Attempt;

   procedure Set_Status (Log : in out Campaign_Log; Status : String) is
   begin
      Log.Status := To_Unbounded_String (Status);
   end Set_Status;

   procedure Write (Path : String; Log : Campaign_Log) is
      Content : constant String :=
        "{"
        & ASCII.LF
        & "  ""format"": ""counterweave.campaign/2"","
        & ASCII.LF
        & "  ""root_seed"": "
        & Counterweave.Strings.JSON_String
            (Counterweave.Strings.Compact_Image (Log.Root_Seed))
        & ","
        & ASCII.LF
        & "  ""maximum_trials"": "
        & Counterweave.Strings.Compact_Image
            (Long_Long_Integer (Log.Maximum_Trials))
        & ","
        & ASCII.LF
        & "  ""status"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Status))
        & ","
        & ASCII.LF
        & "  ""configuration"": {"
        & ASCII.LF
        & "    ""model"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Model_Path))
        & ", ""model_sha256"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Model_SHA256))
        & ","
        & ASCII.LF
        & "    ""data"": "
        & Optional_String (To_String (Log.Data_Path))
        & ", ""data_sha256"": "
        & Optional_String (To_String (Log.Data_SHA256))
        & ","
        & ASCII.LF
        & "    ""solver"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Solver))
        & ", ""pack"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Pack_Name))
        & ", ""pack_version"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Pack_Version))
        & ","
        & ASCII.LF
        & "    ""intent"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Intent))
        & ", ""target"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Target))
        & ","
        & ASCII.LF
        & "    ""adapter"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Adapter))
        & ", ""adapter_sha256"": "
        & Optional_String (To_String (Log.Adapter_SHA256))
        & ","
        & ASCII.LF
        & "    ""draws"": "
        & Strings_JSON (Log.Draws)
        & ", ""adapter_arguments"": "
        & Strings_JSON (Log.Adapter_Arguments)
        & ","
        & ASCII.LF
        & "    ""solver_timeout_ms"": "
        & Counterweave.Strings.Compact_Image
            (Long_Long_Integer (Log.Solver_Timeout))
        & ", ""adapter_timeout_ms"": "
        & Counterweave.Strings.Compact_Image
            (Long_Long_Integer (Log.Adapter_Timeout))
        & ","
        & ASCII.LF
        & "    ""case_output"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Case_Output))
        & ", ""run_output"": "
        & Counterweave.Strings.JSON_String (To_String (Log.Run_Output))
        & ASCII.LF
        & "  },"
        & ASCII.LF
        & "  ""attempts"": "
        & To_String (Log.Attempts_JSON)
        & "]"
        & ASCII.LF
        & "}"
        & ASCII.LF;
   begin
      Counterweave.Strings.Write_File_Atomically (Path, Content);
   end Write;

   function Replay_Arguments
     (Source          : String;
      Case_Output     : String;
      Run_Output      : String;
      Campaign_Output : String) return Counterweave.Strings.String_Vector
   is
      Root              : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Source);
      Configuration     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Root, "configuration");
      Draws             : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Configuration, "draws");
      Adapter_Arguments : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Configuration, "adapter_arguments");

      function String_Member
        (Item : Counterweave.JSON.Value; Name : String) return String
      is (To_String
            (Counterweave.JSON.As_String
               (Source, Counterweave.JSON.Member (Source, Item, Name))));

      function Integer_Member
        (Item : Counterweave.JSON.Value; Name : String) return String
      is (Counterweave.Strings.Compact_Image
            (Counterweave.JSON.As_Integer
               (Source, Counterweave.JSON.Member (Source, Item, Name))));

      Format         : constant String := String_Member (Root, "format");
      Model          : constant String :=
        String_Member (Configuration, "model");
      Model_Hash     : constant String :=
        String_Member (Configuration, "model_sha256");
      Adapter        : constant String :=
        String_Member (Configuration, "adapter");
      Adapter_Hash   : constant String :=
        String_Member (Configuration, "adapter_sha256");
      Retained_Case  : constant String :=
        String_Member (Configuration, "case_output");
      Retained_Run   : constant String :=
        String_Member (Configuration, "run_output");
      Data_Node      : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Configuration, "data");
      Data_Hash_Node : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Source, Configuration, "data_sha256");
      Result         : Counterweave.Strings.String_Vector;
   begin
      if Format /= "counterweave.campaign/2" then
         raise Campaign_Error with "unsupported campaign artifact format";
      elsif Counterweave.Hashes.SHA256_File (Model) /= Model_Hash then
         raise Campaign_Error with "campaign model hash has changed";
      elsif Counterweave.Artifacts.Executable_SHA256 (Adapter) /= Adapter_Hash
      then
         raise Campaign_Error with "campaign adapter hash has changed";
      end if;
      if Counterweave.JSON.Kind (Data_Node) = Counterweave.JSON.String_Value
      then
         declare
            Data_Path : constant String :=
              To_String (Counterweave.JSON.As_String (Source, Data_Node));
            Data_Hash : constant String :=
              To_String (Counterweave.JSON.As_String (Source, Data_Hash_Node));
         begin
            if Counterweave.Hashes.SHA256_File (Data_Path) /= Data_Hash then
               raise Campaign_Error with "campaign data hash has changed";
            end if;
         end;
      elsif Counterweave.JSON.Kind (Data_Node) /= Counterweave.JSON.Null_Value
        or else Counterweave.JSON.Kind (Data_Hash_Node)
                /= Counterweave.JSON.Null_Value
      then
         raise Campaign_Error with "campaign data provenance is malformed";
      end if;

      declare
         Inputs  : Counterweave.Strings.String_Vector;
         Outputs : Counterweave.Strings.String_Vector;
      begin
         Inputs.Append (Model);
         Inputs.Append (Counterweave.Artifacts.Executable_Path (Adapter));
         Inputs.Append (Counterweave.Artifacts.Executable_Path ("minizinc"));
         Inputs.Append (Retained_Case);
         Inputs.Append (Retained_Run);
         if Counterweave.JSON.Kind (Data_Node) = Counterweave.JSON.String_Value
         then
            Inputs.Append
              (To_String (Counterweave.JSON.As_String (Source, Data_Node)));
         end if;
         Outputs.Append (Case_Output);
         Outputs.Append (Run_Output);
         Outputs.Append (Campaign_Output);
         Counterweave.Strings.Validate_Output_Paths
           (Inputs, Outputs, "campaign replay");
      exception
         when Counterweave.Strings.Format_Error =>
            raise Campaign_Error
              with "campaign replay output aliases retained input";
      end;

      Result.Append ("search");
      Result.Append ("--model");
      Result.Append (Model);
      if Counterweave.JSON.Kind (Data_Node) = Counterweave.JSON.String_Value
      then
         Result.Append ("--data");
         Result.Append
           (To_String (Counterweave.JSON.As_String (Source, Data_Node)));
      end if;
      Result.Append ("--solver");
      Result.Append (String_Member (Configuration, "solver"));
      Result.Append ("--pack");
      Result.Append (String_Member (Configuration, "pack"));
      Result.Append ("--pack-version");
      Result.Append (String_Member (Configuration, "pack_version"));
      Result.Append ("--intent");
      Result.Append (String_Member (Configuration, "intent"));
      Result.Append ("--target");
      Result.Append (String_Member (Configuration, "target"));
      Result.Append ("--adapter");
      Result.Append (Adapter);
      Result.Append ("--seed");
      Result.Append (String_Member (Root, "root_seed"));
      Result.Append ("--trials");
      Result.Append (Integer_Member (Root, "maximum_trials"));
      Result.Append ("--solver-timeout-ms");
      Result.Append (Integer_Member (Configuration, "solver_timeout_ms"));
      Result.Append ("--adapter-timeout-ms");
      Result.Append (Integer_Member (Configuration, "adapter_timeout_ms"));
      for Index in 0 .. Counterweave.JSON.Length (Source, Draws) loop
         exit when Index = Counterweave.JSON.Length (Source, Draws);
         Result.Append ("--draw");
         Result.Append
           (To_String
              (Counterweave.JSON.As_String
                 (Source, Counterweave.JSON.Element (Source, Draws, Index))));
      end loop;
      for Index in 0 .. Counterweave.JSON.Length (Source, Adapter_Arguments)
      loop
         exit when
           Index = Counterweave.JSON.Length (Source, Adapter_Arguments);
         Result.Append ("--adapter-arg");
         Result.Append
           (To_String
              (Counterweave.JSON.As_String
                 (Source,
                  Counterweave.JSON.Element
                    (Source, Adapter_Arguments, Index))));
      end loop;
      Result.Append ("--case-output");
      Result.Append (Case_Output);
      Result.Append ("--run-output");
      Result.Append (Run_Output);
      Result.Append ("--campaign-output");
      Result.Append (Campaign_Output);
      return Result;
   exception
      when Counterweave.JSON.JSON_Error | Counterweave.Strings.Format_Error =>
         raise Campaign_Error with "malformed campaign artifact";
   end Replay_Arguments;

   procedure Verify_Replay (Original : String; Replayed : String) is
      Original_Root     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Original);
      Replayed_Root     : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Parse (Replayed);
      Original_Attempts : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Original, Original_Root, "attempts");
      Replayed_Attempts : constant Counterweave.JSON.Value :=
        Counterweave.JSON.Member (Replayed, Replayed_Root, "attempts");

      function Member_Image
        (Source : String; Item : Counterweave.JSON.Value; Name : String)
         return String
      is (Counterweave.JSON.Image
            (Source, Counterweave.JSON.Member (Source, Item, Name)));
   begin
      if Member_Image (Original, Original_Root, "format")
        /= """counterweave.campaign/2"""
        or else Member_Image (Replayed, Replayed_Root, "format")
                /= """counterweave.campaign/2"""
        or else Member_Image (Original, Original_Root, "root_seed")
                /= Member_Image (Replayed, Replayed_Root, "root_seed")
        or else Member_Image (Original, Original_Root, "maximum_trials")
                /= Member_Image (Replayed, Replayed_Root, "maximum_trials")
        or else Member_Image (Original, Original_Root, "status")
                /= Member_Image (Replayed, Replayed_Root, "status")
        or else Counterweave.JSON.Length (Original, Original_Attempts)
                /= Counterweave.JSON.Length (Replayed, Replayed_Attempts)
      then
         raise Campaign_Error with "replayed campaign summary differs";
      end if;

      for Index in 0 .. Counterweave.JSON.Length (Original, Original_Attempts)
      loop
         exit when
           Index = Counterweave.JSON.Length (Original, Original_Attempts);
         declare
            Left  : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Element (Original, Original_Attempts, Index);
            Right : constant Counterweave.JSON.Value :=
              Counterweave.JSON.Element (Replayed, Replayed_Attempts, Index);
         begin
            if Member_Image (Original, Left, "index")
              /= Member_Image (Replayed, Right, "index")
              or else Member_Image (Original, Left, "seed")
                      /= Member_Image (Replayed, Right, "seed")
              or else Member_Image (Original, Left, "outcome")
                      /= Member_Image (Replayed, Right, "outcome")
              or else Member_Image (Original, Left, "property")
                      /= Member_Image (Replayed, Right, "property")
              or else Member_Image (Original, Left, "failure_fingerprint")
                      /= Member_Image (Replayed, Right, "failure_fingerprint")
              or else Member_Image (Original, Left, "case_replay_sha256")
                      /= Member_Image (Replayed, Right, "case_replay_sha256")
            then
               raise Campaign_Error
                 with
                   "replayed campaign differs at trial "
                   & Counterweave.Strings.Compact_Image
                       (Long_Long_Integer (Index + 1));
            end if;
         end;
      end loop;
   exception
      when Counterweave.JSON.JSON_Error =>
         raise Campaign_Error with "malformed replayed campaign artifact";
   end Verify_Replay;

end Counterweave.Campaigns;
