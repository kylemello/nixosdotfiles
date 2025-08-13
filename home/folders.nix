{ lib, config, pkgs, ... }:

{
  home.activation.createDirsAndFiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "$HOME/personal"
    $DRY_RUN_CMD mkdir -p "$HOME/work"
    $DRY_RUN_CMD cat > "$HOME/work/.gitconfig" <<EOF
    [user]
      email = kmello@broadriverrehab.com
    EOF
  '';
}

