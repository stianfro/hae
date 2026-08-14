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

generate-icon:
    ./Scripts/generate-app-icon.sh

smoke-model:
    ./Scripts/smoke-test-model.sh

build:
    ./Scripts/run-swift.sh build

test:
    ./Scripts/run-swift.sh test

format:
    swift format format --in-place --recursive Hae Tests Package.swift
    swift format format --in-place Scripts/draw-app-icon.swift

lint:
    swift format lint --strict --recursive Hae Tests Package.swift
    swift format lint --strict Scripts/draw-app-icon.swift
    shellcheck Scripts/*.sh
    ./Scripts/validate-licenses.sh
    jq empty Hae/Core/Models/ModelManifest.json Hae/Resources/WhisperBuild.json Hae/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json flake.lock
    ruby -c Packaging/Casks/hae.rb.in
    plutil -lint Hae/Info.plist Hae/Hae.entitlements Hae.xcodeproj/project.pbxproj
    xmllint --noout Hae.xcodeproj/xcshareddata/xcschemes/Hae.xcscheme

validate-yaml:
    ./Scripts/validate-yaml.sh

ci: lint validate-yaml test build

package-release:
    ./Scripts/package-release.sh

notarize-release:
    HAE_REQUIRE_DISTRIBUTION=1 ./Scripts/package-release.sh

generate-cask:
    ./Scripts/generate-cask.sh

verify-release:
    ./Scripts/verify-release.sh .cache/release/DerivedData/Build/Products/Release/Hae.app
