(ns hello.core-test
  (:require [clojure.test :refer [deftest is]]
            [greet.core :as greet]))

(deftest greets (is (= "Hello, Nix" (greet/greeting "Nix"))))
