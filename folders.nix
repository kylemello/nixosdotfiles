{ config, pkgs, ... }:

{
  # Create the directories and files using home.file.
  home.file = {
    "personal" = {
      type = "directory";
    };

    "work" = {
      type = "directory";
    };

    "work/.gitconfig" = {
      text = ''
        [user]
          email = kmello@broadriverrehab.com
      '';
    };
  };
}

