(ns mono.lib
  (:require [clojure.data.json :as json]))

(defn message []
  (json/write-str {:from "lib"}))
