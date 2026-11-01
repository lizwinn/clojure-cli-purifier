(ns app.core
  (:require [mono.lib :as lib]))

(defn -main [& _]
  (println (lib/message)))
