set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

bootstrap:
    ./Scripts/bootstrap.sh

fetch-models:
    ./Scripts/fetch-models.sh

verify-models:
    ./Scripts/verify-models.sh

build-whisper:
    ./Scripts/build-whisper-xcframework.sh

smoke-model:
    ./Scripts/smoke-test-model.sh

build:
    ./Scripts/run-swift.sh build

test:
    ./Scripts/run-swift.sh test

format:
    swift format format --in-place --recursive Hae Tests Package.swift

lint:
    swift format lint --strict --recursive Hae Tests Package.swift
    shellcheck Scripts/*.sh
    jq empty Hae/Core/Models/ModelManifest.json Hae/Resources/WhisperBuild.json flake.lock
    plutil -lint Hae/Info.plist Hae/Hae.entitlements Hae.xcodeproj/project.pbxproj
    xmllint --noout Hae.xcodeproj/xcshareddata/xcschemes/Hae.xcscheme

validate-yaml:
    ./Scripts/validate-yaml.sh

ci: lint validate-yaml test build

package-release:
    ./Scripts/package-release.sh
