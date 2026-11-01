# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    # The `packages` output holds the derivations of the scope.
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];
  purifier.scope = "rebar3-purifier";

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope is the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
  };

  # `nix run github:nix-purifiers/rebar3-purifier -- lock` locks the rebar3
  # project in the current directory.
  #
  # `nix develop github:nix-purifiers/rebar3-purifier` gives a shell whose
  # `rebar3` runs against the project's locked downloads.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.rebar3-purifier.toolchain;
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.rebar3-purifier.toolchain ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.erlfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              purifierSrc = self.inputs.purifier.outPath;
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.erlfmt.enable = true;
          };
      };
  };

}
