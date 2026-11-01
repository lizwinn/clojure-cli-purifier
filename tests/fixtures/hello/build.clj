(ns build
  (:require [clojure.tools.build.api :as b]))

(def lib 'example/hello)
(def version "1.0.0")
(def class-dir "target/classes")
(def basis (delay (b/create-basis {:project "deps.edn"})))
(def uber-file (format "target/%s-%s-standalone.jar" (name lib) version))
(def jar-file (format "target/%s-%s.jar" (name lib) version))

(defn clean [_] (b/delete {:path "target"}))

(defn jar [_]
  (b/write-pom {:class-dir class-dir :lib lib :version version :basis @basis :src-dirs ["src"]})
  (b/copy-dir {:src-dirs ["src"] :target-dir class-dir})
  (b/jar {:class-dir class-dir :jar-file jar-file}))

(defn uber [_]
  (b/copy-dir {:src-dirs ["src"] :target-dir class-dir})
  (b/compile-clj {:basis @basis :ns-compile '[hello.core] :class-dir class-dir})
  (b/uber {:class-dir class-dir :uber-file uber-file :basis @basis :main 'hello.core}))
