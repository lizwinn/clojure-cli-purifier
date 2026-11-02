#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise native locking and execution with a Nix-provided JVM module."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(
    ['nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(
    ['nix', 'flake', 'metadata', '--json', '--no-write-lock-file', 'path:' + str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix="purifier-native-composition-") as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store', '--add-root', str(temporary/'source'), '--realise', snapshot], check=True)
    package = subprocess.check_output(
        ['nix', 'build', str(root) + '#default', '--print-out-paths',
         '--out-link', str(temporary / 'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package) / 'bin/clojure-cli-purifier'
    workspace = temporary / 'project'
    shutil.copytree(root / 'tests/fixtures/hello', workspace)
    (workspace / 'clojure-cli-purifier.lock.json').unlink(missing_ok=True)
    # A runtime git library, not merely the test/build tool's separate basis.
    definition = workspace/'deps.edn'
    definition.write_text(definition.read_text().replace(':deps {org.clojure/clojure',
        ':deps {io.github.cognitect-labs/test-runner {:git/tag "v0.5.1" :git/sha "dfb30dd"} '
        'org.clojure/clojure', 1))
    reference='path:'+snapshot+'#checks.'+system+'.composition.provider'
    def run(*args):
        subprocess.run([str(x) for x in args],cwd=workspace,check=True)
    run(cli,'lock','--input',reference,'--build','-T:build jar','--build','-T:build uber',
        '--test','-M:test','--test','-M:range','--test','-M:snapshot')
    locked=json.loads((workspace/'clojure-cli-purifier.lock.json').read_text())
    assert len(locked['projectInputs'])==1
    assert not any(entry['path'].startswith('org/clojure/data.json/') for entry in locked['artifacts'])
    run(cli,'prefetch')
    run(workspace/'.clojure-cli-purifier/bin/clojure','-M:test')
    run(workspace/'.clojure-cli-purifier/bin/clojure','-T:build','jar')
    shutil.rmtree(workspace/'target/classes', ignore_errors=True)
    repository = temporary/'published'
    run(cli, 'publish', '--repository', 'test='+repository.as_uri())
    assert not (workspace/'target/classes').exists(), 'publishing compiled the working tree'
    for group, name in [('local', 'greet'), ('io/github/cognitect-labs', 'test-runner')]:
        assert next((repository/group/name).glob('*/*-nix-*.jar')).is_file()
    publication = next((repository/'example/hello').glob('*/*.pom'))
    tools_expression = """let
      f = builtins.getFlake ("path:" + builtins.getEnv "COMPOSITION_FLAKE");
      p = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
    in p.runCommand "clojure-downstream-tools" {} ''
      mkdir -p $out/bin
      ln -s ${p.maven}/bin/mvn $out/bin/mvn
      ln -s ${p.jdk21_headless.home} $out/jdk
    '' """
    tools = temporary/'tools'
    subprocess.run(['nix', 'build', '--impure', '--out-link', str(tools), '--expr', tools_expression],
        env=dict(os.environ, COMPOSITION_FLAKE=snapshot), check=True)
    downstream = temporary/'downstream'
    source = downstream/'src/main/java/Downstream.java'
    source.parent.mkdir(parents=True)
    source.write_text("""import clojure.java.api.Clojure;
      public final class Downstream { public static void main(String[] args) {
        Clojure.var("clojure.core", "require").invoke(Clojure.read("hello.core"));
        Clojure.var("hello.core", "-main").invoke();
        Clojure.var("clojure.core", "require").invoke(Clojure.read("cognitect.test-runner"));
        for (String resource : new String[]{"clojure/data/json.clj", "greet/core.clj", "cognitect/test_runner.clj"}) {
          String location = Thread.currentThread().getContextClassLoader().getResource(resource).toString();
          if (!location.contains("-nix-")) throw new AssertionError(location);
        }
        System.out.println("ORDINARY MAVEN CLOJURE LOCAL AND GIT COMPOSITION PASSED");
      } }""")
    (downstream/'pom.xml').write_text(f"""<project><modelVersion>4.0.0</modelVersion>
      <groupId>example</groupId><artifactId>downstream</artifactId><version>1</version>
      <properties><maven.compiler.release>21</maven.compiler.release></properties>
      <repositories><repository><id>projected</id><url>{repository.as_uri()}</url></repository></repositories>
      <dependencies><dependency><groupId>example</groupId><artifactId>hello</artifactId>
      <version>{publication.parent.name}</version></dependency></dependencies></project>""")
    plain = dict(os.environ, JAVA_HOME=str(tools/'jdk'))
    subprocess.run([str(tools/'bin/mvn'), '-B', '-Dmaven.repo.local='+str(temporary/'ordinary-m2'),
        'package', 'dependency:build-classpath', '-Dmdep.outputFile=classpath'], cwd=downstream, env=plain, check=True)
    subprocess.run([str(tools/'jdk/bin/java'), '-cp', str(downstream/'target/classes')+os.pathsep
        +(downstream/'classpath').read_text().strip(), 'Downstream'], cwd=downstream, env=plain, check=True)
    print('CLOJURE NATIVE, PURE PUBLICATION, AND ORDINARY MAVEN PASSED')
