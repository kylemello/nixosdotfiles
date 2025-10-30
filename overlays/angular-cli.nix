self: super: {
  nodePackages."@angular/cli" = super.nodePackages."@angular/cli".overrideAttrs (oldAttrs: rec {
    version = "20.3.7";
    src = super.fetchurl {
      url = "https://registry.npmjs.org/@angular/cli/-/cli-${version}.tgz";
      sha512 = "sha512-hNurF7g/e9cDHFBRCKLPSmQJs0n28jZsC3sTl/XuWE8PYtv5egh2EuqrxdruYB5GdANpIqSQNgDGQJrKrk/XnQ==";
    };
  });
}
