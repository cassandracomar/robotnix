#!/usr/bin/env nix-shell
#!nix-shell -i bash -p cachix -I nixpkgs=./pkgs
# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

OUTPUTS=$(./build.sh ./release.nix -A cached --no-out-link $@)

cachix push robotnix ${OUTPUTS[@]}
nix copy --to file:///mnt/cache/nix ${OUTPUTS[@]}
