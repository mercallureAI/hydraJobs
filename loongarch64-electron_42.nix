{ nixpkgs }:

let
  pkgs = import nixpkgs {
    system = "loongarch64-linux";
  };
in
{
  electron_42 = pkgs.electron_42;
}
