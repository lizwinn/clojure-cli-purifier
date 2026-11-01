(ns hello.core
  (:require [clojure.data.json :as json]
            [hiccup2.core :as h]
            [greet.core :as greet])
  (:gen-class))

(defn -main [& _]
  (println (json/write-str {:hello (greet/greeting "Nix")}))
  (println (str (h/html [:p "purified"]))))
