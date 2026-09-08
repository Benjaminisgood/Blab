#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
wardrobe_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/blab-wardrobe-tests.XXXXXX")"
trap 'rm -rf "$wardrobe_test_dir"' EXIT
wardrobe_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$wardrobe_developer_dir/Platforms/MacOSX.platform" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    wardrobe_developer_dir=/Applications/Xcode.app/Contents/Developer
fi
wardrobe_swiftc="$(DEVELOPER_DIR="$wardrobe_developer_dir" xcrun --find swiftc)"
wardrobe_sdk="$(DEVELOPER_DIR="$wardrobe_developer_dir" xcrun --sdk macosx --show-sdk-path)"
wardrobe_macro="$wardrobe_developer_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftDataMacros.dylib"
if [[ ! -f "$wardrobe_macro" ]]; then
    print -u2 'SwiftData persistence tests require full Xcode; set DEVELOPER_DIR to its Contents/Developer directory.'
    exit 1
fi
"$wardrobe_swiftc" -sdk "$wardrobe_sdk" Blab/Models/WardrobeTypes.swift \
    Blab/Services/OutfitRecommendationService.swift \
    Tests/WardrobeDomain/RecommendationTests.swift \
    -o "$wardrobe_test_dir/recommendation-tests"
"$wardrobe_test_dir/recommendation-tests"
"$wardrobe_swiftc" -sdk "$wardrobe_sdk" -load-plugin-library "$wardrobe_macro" \
    Blab/Models/DomainTypes.swift Blab/Models/DomainModels.swift \
    Blab/Models/WardrobeTypes.swift Blab/Models/WardrobeModels.swift \
    Blab/App/AppPersistence.swift Blab/Services/SeedDataService.swift \
    Blab/Services/OutfitRecommendationService.swift \
    Tests/WardrobeDomain/PersistenceTests.swift \
    -o "$wardrobe_test_dir/persistence-tests"
"$wardrobe_test_dir/persistence-tests" legacy "$wardrobe_test_dir/legacy.store"
"$wardrobe_test_dir/persistence-tests" migrate "$wardrobe_test_dir/legacy.store"
"$wardrobe_test_dir/persistence-tests" verify "$wardrobe_test_dir/legacy.store"
"$wardrobe_test_dir/persistence-tests" seed "$wardrobe_test_dir/fresh.store"
