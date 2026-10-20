# nixpkgs moved python3Packages.invoke to 3.x and marked fabric broken
# (fabric/fabric#2376), which takes azure-cli down with it. fabric pins
# invoke<3, but the only invoke 3 change that touches it is Call.make_context,
# which breaks the `fab` CLI and its executor (so their tests are skipped);
# azure-cli only uses fabric.Connection, whose tests pass on invoke 3.
# Giving fabric its own invoke 2 instead doesn't work: azure-cli also depends
# on paramiko, which brings invoke 3, and the two would share one PYTHONPATH.
# Drop this once nixpkgs ships a fabric that supports invoke 3.
self: super: {
  pythonPackagesExtensions = super.pythonPackagesExtensions ++ [
    (pyself: pysuper: {
      fabric = pysuper.fabric.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "invoke" ];
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          "tests/main.py::Fab_"
          "tests/executor.py::Executor_::expand_calls"
        ];
        meta = old.meta // { broken = false; };
      });
    })
  ];
}
