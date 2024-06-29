{ 
  services.kmonad = {
    enable = true;
    config = {
      mappings = {
        "CapsLock" = "LeftTab";
        "LeftTab" = "CapsLock";
      };
    };
  };
 }