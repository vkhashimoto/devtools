{
  description = "devtools.el: databases, clusters and APIs inside Emacs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems =
        f:
        lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system}
        );

      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./devtools.el
          ./devtools-profiles.el
          ./devtools-sql.el
          ./devtools-sql-result.el
          ./devtools-sql-schema.el
          ./devtools-menu.el
          ./examples
          ./scripts
          ./test
          ./run-tests.sh
        ];
      };

      # Elisp dependencies, shared by the package and the tests.
      elispDeps = epkgs: [ epkgs.transient ];

      mkDevtools =
        epkgs:
        epkgs.trivialBuild {
          pname = "devtools";
          version = "0.1.0";
          inherit src;
          packageRequires = elispDeps epkgs;
        };
    in
    {
      # Builds against the consumer's Emacs: emacsPackages.devtools.
      overlays.default = final: prev: {
        emacsPackagesFor =
          emacs:
          (prev.emacsPackagesFor emacs).overrideScope (
            efinal: eprev: { devtools = mkDevtools efinal; }
          );
      };

      packages = forAllSystems (pkgs: {
        default = mkDevtools pkgs.emacsPackages;
      });

      # psql and the demo database server, and Go for server/ (its
      # dependencies come from go.mod, so it also builds without Nix).
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.postgresql
            pkgs.go
          ];
        };
      });

      # Byte-compile and run every test, Postgres ones included.
      checks = forAllSystems (pkgs: {
        default =
          pkgs.runCommand "devtools-tests"
            {
              nativeBuildInputs = [
                (pkgs.emacs.pkgs.withPackages elispDeps)
                pkgs.postgresql
              ];
            }
            ''
              export HOME=$TMPDIR
              cp -r ${src} src && chmod -R u+w src && cd src
              bash scripts/demo-db.sh start
              trap 'bash scripts/demo-db.sh stop' EXIT
              DEVTOOLS_PG_PORT=54329 bash run-tests.sh
              touch $out
            '';
      });
    };
}
