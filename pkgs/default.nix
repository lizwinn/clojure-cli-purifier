# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The clojure-cli-purifier command, with the Clojure CLI of this package
  # set.
  cli = callPackage ./clojure-cli-purifier { };
  clojure = callPackage ./clojure { };
}
