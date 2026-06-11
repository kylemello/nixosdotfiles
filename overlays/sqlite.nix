self: super: {
  sqlite = super.sqlite.overrideAttrs (old: {
    version = "3.53.1";
    src = super.fetchurl {
      url = "https://sqlite.org/2026/sqlite-autoconf-3530100.tar.gz";
      hash = "sha256-g+ayAgoDTpp61Kcv7qWeGtUvFi4Jy9JnNaP/uYNZ/E8=";
    };
  });
}
