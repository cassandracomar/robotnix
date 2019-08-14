{ config, pkgs, lib, ... }:


with lib;
let
  vendorImgs = {
    marlin = pkgs.fetchurl {
      url = "https://dl.google.com/dl/android/aosp/marlin-pq3a.190801.002-factory-13dbb265.zip";
      sha256 = "13dbb265fb7ab74473905705d2e34d019ffc0bae601d1193e71661133aba9653";
    };
    crosshatch = pkgs.fetchurl {
      url = "https://dl.google.com/dl/android/aosp/crosshatch-pq3a.190801.002-factory-15db810d.zip";
      sha256 = "15db810de7d3aa3ad660ffe6bcd572178c8d7c3fa363fef308cde29e0225b6c1";
    };
  };
in
{
  options = {
    vendor.img = mkOption {
      type = types.path;
      description = "A .img from upstream whose vendor contents should be extracted and included in the build";
    };

    vendor.full = mkOption {
      default = false;
      type = types.bool;
      description = "Include non-essential OEM blobs to be compatible with GApps";
    };

    vendor.files = mkOption {
      internal = true;
      default = pkgs.callPackage ./android-prepare-vendor {
        inherit (config) device;
        inherit (config.vendor) img full;
      };
    };
  };

  # TODO: Allow not setting this
  config = {
    vendor.img = mkDefault vendorImgs."${config.deviceFamily}";

    source.dirs."vendor/google_devices/${config.device}".contents = "${config.vendor.files}/vendor/google_devices/${config.device}";
    source.dirs."vendor_overlay/google_devices/${config.device}".contents = "${config.vendor.files}/vendor_overlay/google_devices/${config.device}";
  };
}