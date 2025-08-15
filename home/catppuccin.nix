{ inputs, ... }:

{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
  ];
  # These are your specific settings for the theme.
  catppuccin = {
    enable = true;
    flavor = "mocha";
  };
}
