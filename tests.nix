{ nixpkgs ? ./nix/nixpkgs.nix
, pkgs ? import nixpkgs { config = { }; }
  # Path to nixpkgs for running/building the integration tests
  # created with the "buildTest" function (e.g. those in the buildTestConfigs array)
  # and not for building crate2nix etc itself.
, buildTestNixpkgs ? nixpkgs
, buildTestPkgs ? import buildTestNixpkgs { config = { }; }
, lib ? pkgs.lib
, stdenv ? pkgs.stdenv
}:
let
  crate2nix = pkgs.callPackage ./default.nix { };
  tools = pkgs.callPackage ./tools.nix { };
  buildTest =
    { name
    , src
    , cargoToml ? "Cargo.toml"
    , features ? [ "default" ]
    , skip ? false
    , expectedOutput ? null
    , expectedTestOutputs ? [ ]
    , pregeneratedBuild ? null
    , additionalCargoNixArgs ? [ ]
    , customBuild ? null
    , derivationAttrPath ? [ "rootCrate" ]
    , # Substitute nix-prefetch-url during generation.
      nixPrefetchUrl ? ''
        echo ./tests.nix: NO URL FETCH ALLOWED: "'$*'" >&2
        exit 1
      ''
    , # Substitute nix-prefetch-git during generation.
      nixPrefetchGit ? ''
        echo ./tests.nix: NO GIT FETCH ALLOWED: "'$*'" >&2
        exit 1
      ''
    }:
    let
      generatedCargoNix =
        if builtins.isNull pregeneratedBuild
        then
          let
            autoGeneratedCargoNix = tools.generatedCargoNix {
              name = "buildTest_test_${name}";
              inherit src cargoToml additionalCargoNixArgs;
            };
          in
          autoGeneratedCargoNix.overrideAttrs
            (
              oldAttrs: {
                buildInputs = oldAttrs.buildInputs ++ [
                  (pkgs.writeShellScriptBin "nix-prefetch-url" nixPrefetchUrl)
                  (pkgs.writeShellScriptBin "nix-prefetch-git" nixPrefetchGit)
                ];
              }
            )
        else
          ./. + "/${pregeneratedBuild}";
      derivationAttr =
        lib.attrByPath
          derivationAttrPath
          null
          (buildTestPkgs.callPackage generatedCargoNix { release = true; });
      derivation =
        if builtins.isNull customBuild
        then
          derivationAttr.build.override
            {
              inherit features;
            }
        else
          buildTestPkgs.callPackage (./. + "/${customBuild}") {
            inherit generatedCargoNix;
          };
      debug = derivationAttr.debug.internal;
      # We could easily use a mapAttrs here but then the error
      # output is aweful if things go wrong :(
      debugFile =
        attrName: pkgs.writeTextFile {
          name = "${name}_${attrName}.json";
          text = builtins.toJSON debug."${attrName}";
        };
      testDerivation = pkgs.stdenv.mkDerivation {
        name = "${name}_buildTest";
        phases = [ "buildPhase" ];
        buildInputs = [ derivation ];
        inherit derivation generatedCargoNix;

        sanitizedBuildTree = debugFile "sanitizedBuildTree";
        buildPhase =
          # Need tests if there is expected test output
          assert lib.length expectedTestOutputs > 0 -> derivation ? test;
          ''
                      echo === DEBUG INFO
                      echo ${debugFile "sanitizedBuildTree"}
                      echo ${debugFile "dependencyTree"}
                      echo ${debugFile "mergedPackageFeatures"}
                      echo ${debugFile "diffedDefaultPackageFeatures"}

                      mkdir -p $out

                      ${if expectedOutput == null then ''
                        echo === SKIP RUNNING
                        echo "(no executables)"
                      '' else ''
                        echo === RUNNING
                        ${derivation.crateName} | tee $out/run.log
                        echo === VERIFYING expectedOutput
                        grep '${expectedOutput}' $out/run.log || {
                          echo '${expectedOutput}' not found in:
                          cat $out/run.log
                          exit 23
                        }
                      ''}

                      ${if lib.length expectedTestOutputs == 0 then ''
                        echo === SKIP RUNNING TESTS
                        echo "(no tests)"
                      '' else ''
                        echo === RUNNING TESTS
                        cp ${derivation.test} $out/tests.log
                        echo === VERIFYING expectedTestOutputs
                      ''}
                      ${lib.concatMapStringsSep "\n"
                        (
                            output: ''
                            grep '${output}' $out/tests.log || {
                              echo '${output}' not found in:
                              cat $out/tests.log
                              exit 23
                            }
                          ''
                          )
            expectedTestOutputs}
          '';
      };
    in
    if skip
    then
      pkgs.runCommandNoCCLocal "skip_${name}"
        {
          passthru = { forceSkipped = testDerivation; };
        } ''
        echo SKIPPED
        touch $out
      ''
    else testDerivation;

  buildTestConfigs = [

    #
    # BASIC
    #
    # Artificial tests that tend to test only a few features.
    #

    {
      name = "bin";
      src = ./sample_projects/bin;
      expectedOutput = "Hello, world!";
    }

    {
      name = "lib_and_bin";
      src = ./sample_projects/lib_and_bin;
      expectedOutput = "Hello, lib_and_bin!";
    }

    {
      name = "bin_with_lib_dep";
      src = ./sample_projects;
      cargoToml = "bin_with_lib_dep/Cargo.toml";
      expectedOutput = "Hello, bin_with_lib_dep!";
    }

    {
      name = "bin_with_default_features";
      src = ./sample_projects;
      cargoToml = "bin_with_default_features/Cargo.toml";
      expectedOutput = "Hello, bin_with_default_features!";
    }

    {
      name = "bin_with_NON_default_features";
      src = ./sample_projects;
      cargoToml = "bin_with_default_features/Cargo.toml";
      features = [ "default" "do_not_activate" ];
      expectedOutput = "Hello, bin_with_default_features, do_not_activate!";
    }

    {
      name = "bin_with_NON_default_ROOT_features";
      src = ./sample_projects;
      cargoToml = "bin_with_default_features/Cargo.toml";
      expectedOutput = "Hello, bin_with_default_features, do_not_activate!";
      customBuild = "sample_projects/bin_with_default_features/override-root-features.nix";
    }

    {
      name = "bin_required_features";
      src = ./sample_projects/bin_required_features;
      expectedOutput = "Hello from bin_required_features default binary";
      features = [ "compilemainbinary" ];
    }

    {
      name = "bin_with_lib_git_dep";
      src = ./sample_projects/bin_with_lib_git_dep;
      expectedOutput = "Hello world from bin_with_lib_git_dep!";
    }

    {
      name = "bin_with_git_branch_dep";
      src = ./sample_projects/bin_with_git_branch_dep;
      expectedOutput = "Hello world from bin_with_git_branch_dep!";
    }

    {
      name = "bin_with_rerenamed_lib_dep";
      src = ./sample_projects;
      cargoToml = "bin_with_rerenamed_lib_dep/Cargo.toml";
      expectedOutput = "Hello, bin_with_rerenamed_lib_dep!";
    }

    {
      name = "bin_with_dep_features";
      src = ./sample_projects;
      cargoToml = "bin_with_dep_features/Cargo.toml";
      expectedOutput = "Hello, bin_with_dep_features!";
    }

    {
      name = "sub_dir_crates";
      src = ./sample_projects/sub_dir_crates;
      expectedOutput = "main with lib1 lib2";
      pregeneratedBuild = "sample_projects/sub_dir_crates/Cargo.nix";
    }

    {
      name = "cfg_test";
      src = ./sample_projects/cfg-test;
      cargoToml = "Cargo.toml";
      expectedOutput = "Hello, cfg-test!";
    }

    {
      name = "cfg_test-with-tests";
      src = ./sample_projects/cfg-test;
      cargoToml = "Cargo.toml";
      expectedOutput = "Hello, cfg-test!";
      expectedTestOutputs = [
        "test echo_foo_test ... ok"
        "test lib_test ... ok"
        "test in_source_dir ... ok"
        "test exec_cowsay ... ok"
      ];
      customBuild = "sample_projects/cfg-test/test.nix";
    }

    {
      name = "test_flag_passing";
      src = ./sample_projects/test_flag_passing;
      cargoToml = "Cargo.toml";
      expectedTestOutputs = [
        "test this_must_run ... ok"
        "1 filtered out"
      ];
      expectedOutput = "Banana is a veggie and tomato is a fruit";
      customBuild = "sample_projects/test_flag_passing/test.nix";
    }

    {
      name = "renamed_build_deps";
      src = ./sample_projects/renamed_build_deps;
      expectedOutput = "Hello, renamed_build_deps!";
    }

    {
      name = "renamed_dev_deps";
      src = ./sample_projects/renamed_dev_deps;
      expectedTestOutputs = [
        "test test::ran_a_test ... ok"
      ];
      customBuild = "sample_projects/renamed_dev_deps/test.nix";
    }

    {
      name = "sample_workspace";
      src = ./sample_workspace;
      expectedOutput = "Hello, with_tera!";
      derivationAttrPath = [ "workspaceMembers" "with_tera" ];
    }

    {
      name = "sample_workspace";
      src = ./sample_workspace;
      expectedOutput = lib.optionalString
        stdenv.hostPlatform.isUnix
        "Hello, bin_with_cond_lib_dep!";
      derivationAttrPath = [ "workspaceMembers" "bin_with_cond_lib_dep" ];
    }

    {
      name = "bin_with_git_dep_in_workspace";
      src = ./sample_projects/bin_with_git_dep_in_workspace;
      expectedOutput = "v0.1.6";
    }

    {
      name = "bin_with_git_submodule_dep";
      src = ./sample_projects/bin_with_git_submodule_dep;
      pregeneratedBuild = "sample_projects/bin_with_git_submodule_dep/Cargo.nix";
      customBuild = "sample_projects/bin_with_git_submodule_dep/default.nix";
      expectedOutput = "Hello world from with_git_submodule_dep!";
    }

    {
      name = "bin_with_git_submodule_dep_customBuildRustCrate";
      src = ./sample_projects/bin_with_git_submodule_dep;
      pregeneratedBuild = "sample_projects/bin_with_git_submodule_dep/Cargo.nix";
      customBuild = "sample_projects/bin_with_git_submodule_dep/default-with-customBuildRustCrate.nix";
      expectedOutput = "Hello world from with_git_submodule_dep!";
    }

    {
      name = "bin_with_git_submodule_dep_customBuildRustCrateForPkgs";
      src = ./sample_projects/bin_with_git_submodule_dep;
      pregeneratedBuild = "sample_projects/bin_with_git_submodule_dep/Cargo.nix";
      customBuild = "sample_projects/bin_with_git_submodule_dep/default-with-customBuildRustCrateForPkgs.nix";
      expectedOutput = "Hello world from with_git_submodule_dep!";
    }

    {
      name = "conditional_features_bye";
      src = ./sample_projects/conditional_features;
      expectedOutput = "Bye, not foo!";
    }

    {
      name = "conditional_features_bye_foo";
      src = ./sample_projects/conditional_features;
      features = [ "foo" ];
      expectedOutput = "Bye, foo!";
    }

    {
      name = "conditional_features_hello";
      src = ./sample_projects/conditional_features;
      features = [ "hello" "allow-build" ];
      expectedOutput = "Hello, not foo!";
    }

    {
      name = "conditional_features_hello_foo";
      src = ./sample_projects/conditional_features;
      features = [ "hello" "allow-build" "foo" ];
      expectedOutput = "Hello, foo!";
    }

    {
      name = "cdylib";
      src = ./sample_projects/cdylib;
      customBuild = "sample_projects/cdylib/test.nix";
      expectedOutput = "cdylib test";
      # Disable this on Mac OS. FIXME: https://github.com/kolloch/crate2nix/issues/116
      skip = stdenv.hostPlatform.isDarwin;
    }

    {
      name = "numtest_new_cargo_lock";
      src = ./sample_projects/numtest_new_cargo_lock;
      expectedOutput = "Hello from numtest, world!";
    }

    {
      name = "integration_test";
      src = ./sample_projects/integration_test;
      cargoToml = "Cargo.toml";
      customBuild = "sample_projects/integration_test/test.nix";
      expectedOutput = "expected one argument";
      expectedTestOutputs = [
        "test read_source_file ... ok"
        "test write_output_file ... ok"
      ];
    }

    {
      name = "cross_compile_build_dependencies";
      src = ./sample_projects/cross_compile_build_dependencies;
      customBuild = "sample_projects/cross_compile_build_dependencies/default.nix";
    }

    #
    # Prefetch tests
    #

    {
      name = "simple_dep_prefetch_test";
      src = ./sample_projects/simple_dep;
      additionalCargoNixArgs = [ "--no-cargo-lock-checksums" ];
      expectedOutput = "Hello, simple_dep!";
      nixPrefetchUrl = ''
        case "$@" in
          "https://static.crates.io/crates/nix-base32/nix-base32-0.1.1.crate --name nix-base32-0.1.1")
            echo "04jnq6arig0amz0scadavbzn9bg9k4zphmrm1562n6ygfj1dnj45"
            ;;
          *)
            echo -e "\e[31mUnrecognized fetch:\e[0m $(basename $0) $@" >&2
            exit 1
            ;;
        esac
      '';
    }

    {
      name = "git_prefetch_test";
      src = ./sample_projects/bin_with_lib_git_dep;
      expectedOutput = "Hello world from bin_with_lib_git_dep!";
      additionalCargoNixArgs = [
        "--dont-read-crate-hashes"
      ];
      nixPrefetchGit = ''
        case "$@" in
          "--url https://github.com/kolloch/nix-base32 --fetch-submodules --rev 42f5544e51187f0c7535d453fcffb4b524c99eb2")
            echo '
            {
              "url": "https://github.com/kolloch/nix-base32",
              "rev": "42f5544e51187f0c7535d453fcffb4b524c99eb2",
              "date": "2019-11-29T22:22:24+01:00",
              "sha256": "011f945b48xkilkqbvbsxazspz5z23ka0s90ms4jiqjbhiwll1nw",
              "fetchSubmodules": true
            }
            '
            ;;
          *)
            echo -e "\e[31mUnrecognized fetch:\e[0m $(basename $0) $@" >&2
            exit 1
            ;;
        esac
      '';
    }

    #
    # Compatibility tests with "real" crates
    #

    {
      name = "futures_compat_test";
      src = ./sample_projects/futures_compat;
      cargoToml = "Cargo.toml";
      expectedOutput = "Hello, futures_compat!";
    }

    {
      name = "futures_util_multiple_version";
      src = ./sample_projects/futures_compat;
      cargoToml = "Cargo.toml";
      expectedOutput = "Hello, futures_compat!";
    }

    {
      name = "numtest";
      src = ./sample_projects/numtest;
      expectedOutput = "Hello from numtest, world!";
    }

    {
      name = "renaming";
      src = ./sample_projects/renaming;
      expectedOutput = "Hello, world!";
    }

    {
      name = "codegen";
      src = ./sample_projects/codegen;
      expectedOutput = "Hello, World!";
      pregeneratedBuild = "sample_projects/codegen/Cargo.nix";
    }

    {
      name = "dependency_issue_65_all_features";
      src = ./sample_projects/dependency_issue_65;
      # This will not work with only default features.
      # Therefore, it tests that the default is really --all-features.
      customBuild = "sample_projects/dependency_issue_65/default.nix";
      expectedOutput = "Hello, dependency_issue_65!";
    }

    {
      name = "dependency_issue_65_sqlite_no_default_feature";
      additionalCargoNixArgs = [ "--no-default-features" "--features" "sqlite" ];
      src = ./sample_projects/dependency_issue_65;
      customBuild = "sample_projects/dependency_issue_65/default.nix";
      expectedOutput = "Hello, dependency_issue_65";
    }

    {
      name = "dependency_issue_65_sqlite_default_features";
      additionalCargoNixArgs = [ "--default-features" "--features" "sqlite" ];
      src = ./sample_projects/dependency_issue_65;
      customBuild = "sample_projects/dependency_issue_65/default.nix";
      expectedOutput = "Hello, dependency_issue_65";
    }

    {
      name = "workspace_with_nondefault_lib";
      src = ./sample_projects/workspace_with_nondefault_lib;
      expectedOutput = "Hello, workspace_with_nondefault_lib";
      derivationAttrPath = [ "workspaceMembers" "main" ];
    }

    {
      name = "with_problematic_crates";
      src = ./sample_projects/with_problematic_crates;
      expectedOutput = "Hello, with_problematic_crates!";
      customBuild = "sample_projects/with_problematic_crates/default.nix";
      # Disable this on Mac OS. FIXME: https://github.com/kolloch/crate2nix/issues/116
      skip = stdenv.hostPlatform.isDarwin;
    }

    {
      name = "future_util_multi_version";
      src = ./sample_projects/future_util_multi_version;
      expectedOutput = "Hello, world!";
      # FIXME: https://github.com/kolloch/crate2nix/issues/83
      skip = true;
    }

    {
      name = "empty_cross";
      src = ./sample_projects/empty_cross;
      cargoToml = "Cargo.toml";
      customBuild = "sample_projects/empty_cross/default.nix";
      # # FIXME: https://github.com/nix-community/crate2nix/issues/319
      skip = true;
    }

    {
      name = "aliased_dependencies";
      src = ./sample_projects/aliased-dependencies;
      expectedOutput = "Hello World !\nHello World !";
    }
  ];
  buildTestDerivationAttrSet =
    let
      buildTestDerivations =
        builtins.map
          (c: { name = c.name; value = buildTest c; })
          buildTestConfigs;
    in
    builtins.listToAttrs buildTestDerivations;
in
{
  help = pkgs.stdenv.mkDerivation {
    name = "help";
    phases = [ "buildPhase" ];
    buildPhase = ''
      mkdir -p $out
      ${crate2nix}/bin/crate2nix help >$out/crate2nix.log
      echo grepping
      grep USAGE $out/crate2nix.log
    '';
  };

  fail = pkgs.stdenv.mkDerivation {
    name = "fail";
    phases = [ "buildPhase" ];
    buildPhase = ''
      mkdir -p $out
      ${crate2nix}/bin/crate2nix 2>$out/crate2nix.log \
          && exit 23 || echo expect error
      echo grepping
      grep USAGE $out/crate2nix.log
    '';
  };

  buildNixTestWithLatestCrate2nix = pkgs.callPackage ./nix/nix-test-runner.nix {
    inherit tools;
  };

  inherit buildTestConfigs;
}
// {
  #
  # "source add" tests
  #

  sourceAddGit = pkgs.stdenv.mkDerivation {
    name = "source_add_git";
    src = pkgs.symlinkJoin { name = "empty"; paths = [ ]; };
    buildInputs = [
      crate2nix
      pkgs.jq
      (
        pkgs.writeShellScriptBin "nix-prefetch-git" ''
          case "$@" in
            "--url https://github.com/kolloch/nix-base32.git --fetch-submodules --rev 42f5544e51187f0c7535d453fcffb4b524c99eb2")
              echo '
              {
                "url": "https://github.com/kolloch/nix-base32.git",
                "rev": "42f5544e51187f0c7535d453fcffb4b524c99eb2",
                "date": "2019-11-29T22:22:24+01:00",
                "sha256": "011f945b48xkilkqbvbsxazspz5z23ka0s90ms4jiqjbhiwll1nw",
                "fetchSubmodules": true
              }
              '
              ;;
            *)
              echo -e "\e[31mUnrecognized fetch:\e[0m $(basename $0) $@" >&2
              exit 1
              ;;
          esac
        ''
      )
    ];
    phases = [ "buildPhase" ];
    expectedSources = pkgs.writeTextFile {
      name = "expected-sources.json";
      text = ''
        {
          "nix-base32": {
            "type": "Git",
            "url": "https://github.com/kolloch/nix-base32.git",
            "rev": "42f5544e51187f0c7535d453fcffb4b524c99eb2",
            "sha256": "011f945b48xkilkqbvbsxazspz5z23ka0s90ms4jiqjbhiwll1nw"
          },
          "other-name": {
            "type": "Git",
            "url": "https://github.com/kolloch/nix-base32.git",
            "rev": "42f5544e51187f0c7535d453fcffb4b524c99eb2",
            "sha256": "011f945b48xkilkqbvbsxazspz5z23ka0s90ms4jiqjbhiwll1nw"
          }
        }
      '';
    };
    buildPhase = ''
      mkdir $out
      jq . $expectedSources >$out/expected-sources.json

      crate2nix source add git https://github.com/kolloch/nix-base32.git \
        --rev 42f5544e51187f0c7535d453fcffb4b524c99eb2
      crate2nix source add git --name other-name https://github.com/kolloch/nix-base32.git \
        --rev 42f5544e51187f0c7535d453fcffb4b524c99eb2

      jq .sources <crate2nix.json >$out/sources.json
      diff -u $out/expected-sources.json $out/sources.json
    '';
  };

  sourceAddCratesIo = pkgs.stdenv.mkDerivation {
    name = "source_add_crates_io";
    src = pkgs.symlinkJoin { name = "empty"; paths = [ ]; };
    buildInputs = [
      crate2nix
      pkgs.jq
      (
        pkgs.writeShellScriptBin "nix-prefetch-url" ''
          case "$@" in
            "https://static.crates.io/crates/ripgrep/ripgrep-12.0.1.crate --name ripgrep-12.0.1")
              echo "1arw9pk1qiih0szd26wq76bc0wwbcmhyyy3d4dnwcflka8kfkikx"
              ;;
            *)
              echo -e "\e[31mUnrecognized fetch:\e[0m $(basename $0) $@" >&2
              exit 1
              ;;
          esac
        ''
      )
    ];
    phases = [ "buildPhase" ];
    expectedSources = pkgs.writeTextFile {
      name = "expected-sources.json";
      text = ''
        {
          "other-name": {
            "type": "CratesIo",
            "name": "ripgrep",
            "version": "12.0.1",
            "sha256": "1arw9pk1qiih0szd26wq76bc0wwbcmhyyy3d4dnwcflka8kfkikx"
          },
          "ripgrep": {
            "type": "CratesIo",
            "name": "ripgrep",
            "version": "12.0.1",
            "sha256": "1arw9pk1qiih0szd26wq76bc0wwbcmhyyy3d4dnwcflka8kfkikx"
          }
        }
      '';
    };
    buildPhase = ''
      mkdir $out
      jq . $expectedSources >$out/expected-sources.json

      crate2nix source add cratesIo ripgrep 12.0.1
      crate2nix source add cratesIo --name other-name ripgrep 12.0.1

      jq .sources <crate2nix.json >$out/sources.json
      diff -u $out/expected-sources.json $out/sources.json
    '';
  };

  sourceAddNix = pkgs.stdenv.mkDerivation {
    name = "source_add_nix";
    src = pkgs.symlinkJoin { name = "empty"; paths = [ ]; };
    buildInputs = [
      crate2nix
      pkgs.jq
    ];
    phases = [ "buildPhase" ];
    expectedSources = pkgs.writeTextFile {
      name = "expected-sources.json";
      text = ''
        {
          "import-sources": {
            "type": "Nix",
            "import": "sources.nix"
          },
          "import-sources-attr": {
            "type": "Nix",
            "import": "sources2.nix",
            "attr": "attr.path"
          },
          "name-from-attr": {
            "type": "Nix",
            "package": "sources.nix",
            "attr": "attr.path.name-from-attr"
          },
          "name-from-attr2": {
            "type": "Nix",
            "import": "sources.nix",
            "attr": "attr.path.name-from-attr2"
          },
          "package-sources": {
            "type": "Nix",
            "package": "package.nix"
          },
          "package-sources-attr": {
            "type": "Nix",
            "package": "package2.nix",
            "attr": "attr.path"
          }
        }
      '';
    };
    buildPhase = ''
      mkdir $out
      jq . $expectedSources >$out/expected-sources.json

      crate2nix source add nix --name import-sources --import sources.nix
      crate2nix source add nix --name import-sources-attr --import sources2.nix attr.path
      crate2nix source add nix --package sources.nix attr.path.name-from-attr
      crate2nix source add nix --import sources.nix attr.path.name-from-attr2
      crate2nix source add nix --name package-sources --package package.nix
      crate2nix source add nix --name package-sources-attr --package package2.nix attr.path

      jq .sources <crate2nix.json >$out/sources.json
      diff -u $out/expected-sources.json $out/sources.json
    '';
  };
}
// rec {
  #
  # "source generate" tests
  #
  withFetchedSources = pkgs.runCommandNoCCLocal "with-fetched-sources" { } ''
    mkdir $out
    ln -s ${crate2nixJsonWithRipgrep}/* $out
    ln -s ${sourcesMemberDirectory} $out/crate2nix-sources
  '';

  generatedWithFetchedSources = tools.generatedCargoNix {
    name = "generatedWithFetchedSources";
    src = withFetchedSources;
  };

  # buildSourcesProject =
  #   (pkgs.callPackage generatedCargoFilesUpdateProject { }).workspaceMembers.ripgrep;

  # Test support
  #
  # It is to have them directly as attributes for testing.

  registryGit = pkgs.fetchgit {
    url = "https://github.com/rust-lang/crates.io-index";
    rev = "18e3f063f594fc08a078f0de2bb3f94beed16ae2";
    sha256 = "0rpv12ifgnni55phlkb5ppmala7y3zrsc9dl8l99pbsjpqx95vmj";
  };

  registry = pkgs.linkFarm "crates.io-index" [
    { name = "index"; path = registryGit; }
  ];

  cargoConfigWithLocalRegistry = pkgs.writeTextFile {
    name = "cargo_config";
    destination = "/.cargo/config";
    text = ''
      [source]
      [source.crates-io]
      replace-with = "local-copy"
      [source.local-copy]
      local-registry = "${registry}"
    '';
  };

  crate2nixJsonWithRipgrep = pkgs.writeTextFile {
    name = "crate2nix_json";
    destination = "/crate2nix.json";
    text = ''
      {
        "sources": {
          "ripgrep": {
            "type": "CratesIo",
            "name": "ripgrep",
            "version": "12.0.1",
            "sha256": "1arw9pk1qiih0szd26wq76bc0wwbcmhyyy3d4dnwcflka8kfkikx"
          }
        }
      }
    '';
  };

  sourcesMemberDirectory = (pkgs.callPackage sourcesNix { }).fetchedSources;

  sourcesNix = pkgs.stdenv.mkDerivation {
    name = "crate2nix-sources_nix";
    src = crate2nixJsonWithRipgrep;
    buildInputs = [ crate2nix ];
    phases = [ "buildPhase" ];
    buildPhase = ''
      ln -s $src/crate2nix.json .
      crate2nix source generate
      mkdir $out
      ln -s $src/crate2nix.json $out
      cp crate2nix-sources.nix $out/default.nix
    '';
  };

} // buildTestDerivationAttrSet
