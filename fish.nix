{ config, pkgs, ... }:

{
  programs.fish = {
    enable = true;

    plugins = [
      {
        name = "plugin-git";
        src = pkgs.fishPlugins.plugin-git.src;
      }
      {
        name = "fzf";
        src = pkgs.fishPlugins.fzf;
      }
      {
        name = "tide"; 
        src = pkgs.fishPlugins.tide.src;
      }
      {
        name = "tmux-budimanjojo";
        src = pkgs.fetchFromGitHub {
          owner = "budimanjojo";
          repo = "tmux.fish";
          rev = "db0030b7f4f78af4053dc5c032c7512406961ea5";
          sha256 = "sha256-rRibn+FN8VNTSC1HmV05DXEa6+3uOHNx03tprkcjjs8=";
        };
      }
      {
        name = "zoxide-kidonng";
        src = pkgs.fetchFromGitHub {
          owner = "kidonng";
          repo = "zoxide.fish";
          rev = "bfd5947bcc7cd01beb23c6a40ca9807c174bba0e";
          sha256 = "sha256-Hq9UXB99kmbWKUVFDeJL790P8ek+xZR5LDvS+Qih+N4=";
        };
      }
    ];

    interactiveShellInit = ''
      fish_vi_key_bindings
      set -g fish_greeting


      _tide_left_items 'os'  'pwd'  'git'  'newline'  'character'
      _tide_prompt_17535 \e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m…
      _tide_prompt_28006 \e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m…
      _tide_prompt_3751 \e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m…
      _tide_prompt_7734 \e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m\e\(B\e\[m…
      _tide_right_items 'status'  'cmd_duration'  'context'  'jobs'  'node'  'python…
      tide_aws_bg_color normal
      tide_aws_color FF9900
      tide_aws_icon 
      tide_character_color 5FD700
      tide_character_color_failure FF0000
      tide_character_icon ❯
      tide_character_vi_icon_default ❮
      tide_character_vi_icon_replace ▶
      tide_character_vi_icon_visual V
      tide_cmd_duration_bg_color normal
      tide_cmd_duration_color 87875F
      tide_cmd_duration_decimals 0
      tide_cmd_duration_icon 
      tide_cmd_duration_threshold 3000
      tide_context_always_display false
      tide_context_bg_color normal
      tide_context_color_default D7AF87
      tide_context_color_root D7AF00
      tide_context_color_ssh D7AF87
      tide_context_hostname_parts 1
      tide_crystal_bg_color normal
      tide_crystal_color FFFFFF
      tide_crystal_icon 
      tide_direnv_bg_color normal
      tide_direnv_bg_color_denied normal
      tide_direnv_color D7AF00
      tide_direnv_color_denied FF0000
      tide_direnv_icon ▼
      tide_distrobox_bg_color normal
      tide_distrobox_color FF00FF
      tide_distrobox_icon 󰆧
      tide_docker_bg_color normal
      tide_docker_color 2496ED
      tide_docker_default_contexts 'default'  'colima'
      tide_docker_icon 
      tide_elixir_bg_color normal
      tide_elixir_color 4E2A8E
      tide_elixir_icon 
      tide_gcloud_bg_color normal
      tide_gcloud_color 4285F4
      tide_gcloud_icon 󰊭
      tide_git_bg_color normal
      tide_git_bg_color_unstable normal
      tide_git_bg_color_urgent normal
      tide_git_color_branch 5FD700
      tide_git_color_conflicted FF0000
      tide_git_color_dirty D7AF00
      tide_git_color_operation FF0000
      tide_git_color_staged D7AF00
      tide_git_color_stash 5FD700
      tide_git_color_untracked 00AFFF
      tide_git_color_upstream 5FD700
      tide_git_icon 
      tide_git_truncation_length 24
      tide_git_truncation_strategy
      tide_go_bg_color normal
      tide_go_color 00ACD7
      tide_go_icon 
      tide_java_bg_color normal
      tide_java_color ED8B00
      tide_java_icon 
      tide_jobs_bg_color normal
      tide_jobs_color 5FAF00
      tide_jobs_icon 
      tide_jobs_number_threshold 1000
      tide_kubectl_bg_color normal
      tide_kubectl_color 326CE5
      tide_kubectl_icon 󱃾
      tide_left_prompt_frame_enabled false
      tide_left_prompt_items 'os'  'pwd'  'git'  'newline'  'character'
      tide_left_prompt_prefix
      tide_left_prompt_separator_diff_color ' '
      tide_left_prompt_separator_same_color ' '
      tide_left_prompt_suffix ' '
      tide_nix_shell_bg_color normal
      tide_nix_shell_color 7EBAE4
      tide_nix_shell_icon 
      tide_node_bg_color normal
      tide_node_color 44883E
      tide_node_icon 
      tide_os_bg_color normal
      tide_os_color normal
      tide_os_icon 
      tide_php_bg_color normal
      tide_php_color 617CBE
      tide_php_icon 
      tide_private_mode_bg_color normal
      tide_private_mode_color FFFFFF
      tide_private_mode_icon 󰗹
      tide_prompt_add_newline_before false
      tide_prompt_color_frame_and_connection 444444
      tide_prompt_color_separator_same_color 949494
      tide_prompt_icon_connection ·
      tide_prompt_min_cols 34
      tide_prompt_pad_items false
      tide_prompt_transient_enabled true
      tide_pulumi_bg_color normal
      tide_pulumi_color F7BF2A
      tide_pulumi_icon 
      tide_pwd_bg_color normal
      tide_pwd_color_anchors 00AFFF
      tide_pwd_color_dirs 0087AF
      tide_pwd_color_truncated_dirs 8787AF
      tide_pwd_icon 
      tide_pwd_icon_home 
      tide_pwd_icon_unwritable 
      tide_pwd_markers '.bzr'  '.citc'  '.git'  '.hg'  '.node-version'  '.python-ve…
      tide_python_bg_color normal
      tide_python_color 00AFAF
      tide_python_icon 󰌠
      tide_right_prompt_frame_enabled false
      tide_right_prompt_items 'status'  'cmd_duration'  'context'  'jobs'  'direnv'  'node…
      tide_right_prompt_prefix ' '
      tide_right_prompt_separator_diff_color ' '
      tide_right_prompt_separator_same_color ' '
      tide_right_prompt_suffix
      tide_ruby_bg_color normal
      tide_ruby_color B31209
      tide_ruby_icon 
      tide_rustc_bg_color normal
      tide_rustc_color F74C00
      tide_rustc_icon 
      tide_shlvl_bg_color normal
      tide_shlvl_color d78700
      tide_shlvl_icon 
      tide_shlvl_threshold 1
      tide_status_bg_color normal
      tide_status_bg_color_failure normal
      tide_status_color 5FAF00
      tide_status_color_failure D70000
      tide_status_icon ✔
      tide_status_icon_failure ✘
      tide_terraform_bg_color normal
      tide_terraform_color 844FBA
      tide_terraform_icon 󱁢
      tide_time_bg_color normal
      tide_time_color 5F8787
      tide_time_format '%r'
      tide_toolbox_bg_color normal
      tide_toolbox_color 613583
      tide_toolbox_icon 
      tide_vi_mode_bg_color_default normal
      tide_vi_mode_bg_color_insert normal
      tide_vi_mode_bg_color_replace normal
      tide_vi_mode_bg_color_visual normal
      tide_vi_mode_color_default 949494
      tide_vi_mode_color_insert 87AFAF
      tide_vi_mode_color_replace 87AF87
      tide_vi_mode_color_visual FF8700
      tide_vi_mode_icon_default D
      tide_vi_mode_icon_insert I
      tide_vi_mode_icon_replace R
      tide_vi_mode_icon_visual V
      tide_zig_bg_color normal
      tide_zig_color F7A41D
      tide_zig_icon 
    '';
  };
}
