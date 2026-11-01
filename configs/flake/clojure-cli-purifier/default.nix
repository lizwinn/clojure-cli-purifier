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
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # The scope is the `default` entry of this flake's package overlay
  # registry (pkg-overlays/): the package set applies it by default, and
  # the flake exports it as `pkgOverlays` and as the plain
  # `overlays.default`. The module purifier-packages of the shared purifier
  # library publishes the derivations of the scope as the flake's packages.
  purifier.scope = "clojure-cli-purifier";

  # `default` is the command: `nix run
  # github:nix-purifiers/clojure-cli-purifier -- lock` locks the project in
  # the current directory.
  perSystem =
    { config, ... }:
    {
      packages.default = config.packages.cli;
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
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib.clojure-cli-purifier) readLock;
              inherit (self.packages.${system}) cli;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
