;; SPDX-License-Identifier: MIT
;;
;; Helpers of the clojure-cli-purifier command that need to read EDN or XML.
;; The command runs this file with the tools jar of the Clojure CLI, which
;; holds Clojure itself, so it needs no download:
;;
;;   aliases DEPS-EDN...
;;     Prints the alias keywords that the deps.edn files define, one per
;;     line.
;;   repos BASIS...
;;     Prints "<id>\t<url>" for each Maven repository of the basis files the
;;     Clojure CLI wrote.
;;   snapshot-name METADATA FILE
;;     Prints the remote file name of FILE, a "-SNAPSHOT" file of the local
;;     Maven repository, from the maven-metadata file of its directory.
(ns clojure-cli-purifier.helper
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.xml :as xml]))

(defn- read-edn [file]
  (edn/read-string {:default tagged-literal} (slurp file)))

(defn- aliases [files]
  (doseq [alias (sort (distinct (mapcat (comp keys :aliases read-edn) files)))]
    (println alias)))

(defn- mvn-requests [files]
  (doseq [[group name version]
          (sort (distinct
                 (for [file files
                       entry (tree-seq coll? seq (read-edn file))
                       :when (map-entry? entry)
                       :let [[library coordinate] entry]
                       :when (and (symbol? library) (map? coordinate)
                                  (string? (:mvn/version coordinate)))]
                   [(or (namespace library) (name library))
                    (name library) (:mvn/version coordinate)])))]
    (println (str group "\t" name "\t" version))))

(defn- merge-input-config [[file supplied]]
  (let [configuration (if (seq supplied) (edn/read-string supplied) {})
        overrides (read-edn file)]
    (prn (update configuration :aliases merge (:aliases overrides)))))

(defn- repos [files]
  (doseq [[id {:keys [url]}] (distinct (mapcat (comp :mvn/repos read-edn) files))
          :when url]
    (println (str id "\t" url))))

(defn- children [node tag]
  (filter #(= tag (:tag %)) (:content node)))

(defn- child [node tag]
  (first (children node tag)))

(defn- text [node]
  (when node (str/trim (apply str (filter string? (:content node))))))

;; Maven names a snapshot file <artifactId>-<version>[-<classifier>].<ext> in
;; the local repository, and <artifactId>-<timestamped version>[...] in the
;; remote one. The metadata lists the timestamped version of each file in
;; <snapshotVersions>, or, in the older format, only a timestamp and build
;; number that every file of the version shares.
(defn- snapshot-name [metadata-file file-name]
  (let [metadata (xml/parse (io/file metadata-file))
        artifact-id (text (child metadata :artifactId))
        base-version (text (child metadata :version))
        versioning (child metadata :versioning)
        prefix (str artifact-id "-" base-version)
        _ (when-not (str/starts-with? file-name prefix)
            (throw (ex-info (str file-name " is not a file of " prefix) {})))
        rest-name (subs file-name (count prefix))
        entries (some-> (child versioning :snapshotVersions) (children :snapshotVersion))
        local-name (fn [entry]
                     (let [classifier (text (child entry :classifier))]
                       (str prefix
                            (when (seq classifier) (str "-" classifier))
                            "." (text (child entry :extension)))))
        matching (first (filter #(= file-name (local-name %)) entries))]
    (println
     (if matching
       (str/replace-first file-name base-version (text (child matching :value)))
       (let [snapshot (child versioning :snapshot)
             timestamp (text (child snapshot :timestamp))
             build-number (text (child snapshot :buildNumber))]
         (when-not (and timestamp build-number)
           (throw (ex-info (str metadata-file " names no timestamped version for " file-name) {})))
         (str artifact-id "-"
              (str/replace base-version #"SNAPSHOT$" (str timestamp "-" build-number))
              rest-name))))))

(let [[command & args] *command-line-args*]
  (case command
    "aliases" (aliases args)
    "mvn-requests" (mvn-requests args)
    "merge-input-config" (merge-input-config args)
    "repos" (repos args)
    "snapshot-name" (apply snapshot-name args)))
