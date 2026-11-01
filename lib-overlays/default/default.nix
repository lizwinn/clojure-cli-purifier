# SPDX-License-Identifier: MIT
#
# The `clojure-cli-purifier` library namespace. It holds nothing, because
# the builder needs a package set: it is the package
# `buildClojureCliProject` that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    clojure-cli-purifier = prev.clojure-cli-purifier or { };
  };

}
