(ns hello.range
  (:require [clojure.core.memoize :as memo]))

(defn -main [& _]
  (let [square (memo/memo (fn [x] (* x x)))]
    (println "range" (square 7))))
