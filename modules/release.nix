# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{ config, pkgs, lib, ... }:

let
  inherit (lib) mkIf mkDefault mkOption types optional optionalString;

  otaTools = config.build.otaTools;

  wrapScript = { commands, keysDir }:
    let
      jre = if (config.androidVersion >= 11) then pkgs.jdk11_headless else pkgs.jre8_headless;
      deps = with pkgs;
        [
          otaTools
          openssl
          jre
          zip
          unzip
          pkgs.getopt
          which
          toybox
          vboot_reference
          utillinux
          python3 # ota_from_target_files invokes, brillo_update_payload which has "truncate_file" which invokes python
        ];
    in
    config.build.signing.withKeys keysDir ''
      export PATH=${lib.makeBinPath deps}:$PATH
      export EXT2FS_NO_MTAB_OK=yes

      ${commands}
    '';

  runWrappedCommand = name: script: args: pkgs.runCommand "${config.device}-${name}-${config.buildNumber}.zip"
    {
      nativeBuildInputs = with pkgs; [ sops age gnupg config.build.checkTargetFiles ];
    }
    (wrapScript {
      commands = script (args // { out = "$out"; });
      keysDir = config.signing.keyStorePath;
    });

  fileSigningEnvironment = name: script: args: config.build.mkAndroid {
    name = "${config.device}-${name}-${config.buildNumber}.zip";
    outputs = [ "out" ];
    nativeBuildInputs = with pkgs; [ sops age gnupg config.build.checkTargetFiles ];
    buildPhase = wrapScript {
      commands = script (args // { out = "$out"; });
      keysDir = config.signing.keyStorePath;
    };

    installPhase = "true";
  };

  signedTargetFilesScript = { targetFiles, out }: ''
    OUT=$(realpath ${out})
    sign_target_files_apks \
      -o ${toString config.signing.signTargetFilesArgs} \
      ${targetFiles} $OUT
  '';
  otaScript = { targetFiles, prevTargetFiles ? null, out }: ''
    ota_from_target_files  \
      ${toString config.otaArgs} \
      ${lib.optionalString (prevTargetFiles != null) "-i ${prevTargetFiles}"} \
      ${targetFiles} ${out}
  '';
  imgScript = { targetFiles, out }: ''img_from_target_files ${targetFiles} ${out}'';
  factoryImgScript = { targetFiles, img, out }: ''
    ln -s ${targetFiles} ${config.device}-target_files-${config.buildNumber}.zip
    ${pkgs.coreutils}/bin/cp -rL --copy-contents ${img} ${config.device}-img-${config.buildNumber}.zip || true

    export DEVICE=${config.device}
    export PRODUCT=${config.device}
    export BUILD=${config.buildNumber}
    export VERSION=${lib.toLower config.buildNumber}

    get_radio_image() {
      ${lib.getBin pkgs.libarchive}/bin/bsdtar xvf ${targetFiles} -O OTA/android-info.txt  \
        |  grep "require version-$1" | cut -d'=' -f2 | tr '[:upper:]' '[:lower:]' || exit 1
    }
    export BOOTLOADER=$(get_radio_image bootloader)
    export RADIO=$(get_radio_image baseband)

    export PATH=${lib.getBin pkgs.zip}/bin:${lib.getBin pkgs.unzip}/bin:$PATH
    ${pkgs.runtimeShell} ${config.source.dirs."device/common".src}/generate-factory-images-common.sh
    ${pkgs.coreutils}/bin/cp -rL --copy-contents ${config.device}-factory-${config.buildNumber}.zip ${out} || true
  '';
in
{
  options = {
    channel = mkOption {
      default = "stable";
      type = types.enum [ "stable" "beta" ];
      description = "Default channel to use for updates (can be modified in app)";
    };

    incremental = mkOption {
      default = false;
      type = types.bool;
      description = "Whether to include an incremental build in `otaDir` output";
    };

    retrofit = mkOption {
      default = false;
      type = types.bool;
      description = ''
        Generate a retrofit OTA for upgrading a device without dynamic partitions.
        See also https://source.android.com/devices/tech/ota/dynamic_partitions/ab_legacy#generating-update-packages
      '';
    };

    otaArgs = mkOption {
      default = [ ];
      type = types.listOf types.str;
      internal = true;
    };

    # Build products. Put here for convenience--but it's not a great interface
    prevBuildDir = mkOption { type = types.str; internal = true; };
    prevBuildNumber = mkOption { type = types.str; internal = true; };
    prevTargetFiles = mkOption { type = types.path; internal = true; };
  };

  config = {
    prevBuildNumber =
      let
        metadata = builtins.readFile (config.prevBuildDir + "/${config.device}-${config.channel}");
      in
      mkDefault (lib.head (lib.splitString " " metadata));
    prevTargetFiles = mkDefault (config.prevBuildDir + "/${config.device}-target_files-${config.prevBuildNumber}.zip");

    otaArgs =
      [ "--block" ]
      ++ lib.optional config.retrofit "--retrofit_dynamic_partitions";
  };

  config.build = rec {
    # These can be used to build these products inside nix. Requires putting the secret keys under /keys in the sandbox
    unsignedTargetFiles = config.build.android + "/${config.productName}-target_files-${config.buildNumber}.zip";
    signedTargetFiles = fileSigningEnvironment "signed_target_files" signedTargetFilesScript { targetFiles = unsignedTargetFiles; };
    targetFiles = if config.signing.enable then signedTargetFiles else unsignedTargetFiles;
    ota = runWrappedCommand "ota_update" otaScript { inherit targetFiles; };
    incrementalOta = runWrappedCommand "incremental-${config.prevBuildNumber}" otaScript { inherit targetFiles; inherit (config) prevTargetFiles; };
    img = runWrappedCommand "img" imgScript { inherit targetFiles; };
    factoryImg = runWrappedCommand "factory" factoryImgScript { inherit targetFiles img; };
    unpackedImg = pkgs.robotnix.unpackImg config.build.img;

    # Pull this out of target files, because (at least) verity key gets put into boot ramdisk
    bootImg = pkgs.runCommand "boot.img" { } "${pkgs.unzip}/bin/unzip -p ${targetFiles} IMAGES/boot.img > $out";
    recoveryImg = pkgs.runCommand "recovery.img" { } "${pkgs.unzip}/bin/unzip -p ${targetFiles} IMAGES/recovery.img > $out";

    # BUILDID_PLACEHOLDER below was originally config.apv.buildID, but we don't want to have to depend on setting a buildID generally.
    otaMetadata = (rec {
      grapheneos = pkgs.writeText "${config.device}-${config.channel}" ''
        ${config.buildNumber} ${toString config.buildDateTime} ${
          if config.apv.enable
          then config.apv.buildID
          else
            if config.adevtool.enable
            then config.adevtool.buildID
            else "BUILDID_PLACEHOLDER"
        } ${config.channel}
      '';
      lineageos = pkgs.writeText "lineageos-${config.device}.json" (
        # https://github.com/LineageOS/android_packages_apps_Updater#server-requirements
        builtins.toJSON {
          response = [
            {
              "datetime" = config.buildDateTime;
              "filename" = ota.name;
              "id" = config.buildNumber;
              "romtype" = config.envVars.RELEASE_TYPE;
              "size" = "ROM_SIZE";
              "url" = "${config.apps.updater.url}${ota.name}";
              "version" = config.flavorVersion;
            }
          ];
        }
      );
    }).${config.apps.updater.flavor};

    writeOtaMetadata = { otaFile, path }: {
      grapheneos = ''
        cat ${otaMetadata} > ${path}/${config.device}-${config.channel}
      '';
      lineageos = ''
        sed -e "s:\"ROM_SIZE\":$(du -b ${otaFile} | cut -f1):" ${otaMetadata} > ${path}/lineageos-${config.device}.json
      '';
    }.${config.apps.updater.flavor};

    # TODO: target-files aren't necessary to publish--but are useful to include if prevBuildDir is set to otaDir output
    otaDir = pkgs.runCommand "${config.device}-otaDir" { } ''
      mkdir -p $out
      ln -s "${ota}" "$out/${ota.name}"
      ln -s "${targetFiles}" "$out/${config.device}-target_files-${config.buildNumber}.zip"
      ${lib.optionalString config.incremental ''ln -s ${incrementalOta} "$out/${incrementalOta.name}"''}

      ${writeOtaMetadata { otaFile = ota; path = placeholder "out"; }}
    '';

    # TODO: Do this in a temporary directory. It's ugly to make build dir and ./tmp/* dir gets cleared in these scripts too.
    releaseScript =
      (if (!config.signing.enable) then lib.warn "releaseScript should be used only if signing.enable = true; Otherwise, the build might be using incorrect keys / certificate metadata" else lib.id)
        pkgs.writeShellScript "release.sh"
        (''
          set -eo pipefail

          if [[ $# -ge 1 ]]; then
            PREV_BUILDNUMBER="$1"
          else
            PREV_BUILDNUMBER=""
          fi
        '' + (wrapScript {
          keysDir = config.signing.keyStorePath;
          commands = ''
            echo Signing target files
            ${pkgs.coreutils}/bin/cp -rL --copy-contents ${signedTargetFiles} ${signedTargetFiles.name}
            echo Building OTA zip
            ${otaScript { targetFiles=signedTargetFiles.name; out=ota.name; }}
            if [[ ! -z "$PREV_BUILDNUMBER" ]] && [[ ${if builtins.toString config.incremental == "true" then "true" else "false"} == "true" ]]; then
              echo Building incremental OTA zip
              ${otaScript {
                targetFiles=signedTargetFiles.name;
                prevTargetFiles="${config.device}-target_files-$PREV_BUILDNUMBER.zip";
                out="${config.device}-incremental-$PREV_BUILDNUMBER-${config.buildNumber}.zip";
              }}
            fi
            echo Building .img file
            ${imgScript { targetFiles=signedTargetFiles.name; out=img.name; }}
            echo Building factory image
            ${factoryImgScript { targetFiles=signedTargetFiles.name; img=img.name; out=factoryImg.name; }}
          '' + lib.optionalString config.apps.updater.enable ''
            echo Writing updater metadata
            ${writeOtaMetadata { otaFile=ota.name; path = "."; }}
          '';
        }));
  };
}
