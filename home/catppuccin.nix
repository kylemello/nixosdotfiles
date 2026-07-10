{ inputs, ... }:

{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
  ];
  # These are your specific settings for the theme.
  catppuccin = {
    enable = true;
    # `enable` is becoming a global on/off toggle; `autoEnable` is the new
    # per-port auto-enroll switch. Set it explicitly (matching the old `enable`
    # behaviour) to keep every port themed and silence the migration warning.
    autoEnable = true;
    flavor = "mocha";
  };
}
