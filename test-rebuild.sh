#!/bin/sh

pushd ~/nixos
sudo nixos-rebuild test --flake .#default
popd
