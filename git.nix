{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName = "kylemello";
    userEmail = "kylemello98@gmail.com";
    
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
    
    extraConfig = {
      init.defaultBranch = "master";
      core = {
        editor = "nvim";
        # sshCommand = "ssh.exe";
        pager = "delta";
      };
      
      gpg = {
        format = "ssh";
        # ssh.program = "/mnt/c/Users/kylem/AppData/Local/1Password/app/8/op-ssh-sign.exe";
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
      
      maintenance.repo = "/home/kyle/.oh-my-zsh/repos/zsh-snap";
    };
  };
}
