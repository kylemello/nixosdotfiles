{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user.email = "kylemello98@gmail.com";
      user.name = "kylemello";
      init.defaultBranch = "master";
      core = {
        editor = "nvim";
        pager = "delta";
      };
      
      gpg = {
        format = "ssh";
      };
      
      interactive.diffFilter = "delta --color-only";
      
      delta = {
        navigate = true;
        dark = true;
      };
      
      filter.lfs = {
        required = true;
        clean = "git-lfs clean -- %f";
        smudge = "git-lfs smudge -- %f";
        process = "git-lfs filter-process";
      };
    };
    
    signing = {
      key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUALOKH2pGfuaVbh3J/UlFPJOLx6CpraE8qcaWbkE5D";
      signByDefault = true;
    };
    
    includes = [
      {
        condition = "gitdir:~/work/";
        path = "~/work/.gitconfig";
      }
    ];
  };
}
