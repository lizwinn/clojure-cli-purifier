(ns hello.snapshot
  (:require [hiccup.core :as h]))

(defn -main [& _]
  (println (h/html [:b "snapshot"])))
