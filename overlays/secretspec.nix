# secretspec 0.21.0's claude_integration tests assert on substrings of a miette
# error message that embeds the temp project path. Darwin's Nix build dir
# (/nix/var/nix/builds/nix-<pid>-<rand>/...) is long enough to push miette's
# 80-column wrap into the middle of "managed by SecretSpec" / "outside
# SecretSpec", so the assertions fail here but pass on Linux's short /build.
self: super: {
  secretspec = super.secretspec.overrideAttrs (old: {
    checkFlags = (old.checkFlags or [ ]) ++ [
      "--skip=configure_refuses_to_replace_an_unmanaged_helper"
      "--skip=unconfigure_refuses_to_remove_an_edited_managed_helper"
    ];
  });
}
