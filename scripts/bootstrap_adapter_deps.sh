#!/bin/sh
set -eu

deps_root=${PARTIAL_COMPLETION_DEPS_DIR:-deps}
mkdir -p "$deps_root"

ensure_checkout() {
  name=$1
  repository=$2
  commit=$3
  directory="$deps_root/$name"
  newly_cloned=0

  if [ ! -d "$directory/.git" ]; then
    if [ -e "$directory" ]; then
      echo "adapter dependency path is not a Git checkout: $directory" >&2
      exit 1
    fi
    git clone --quiet --no-checkout --filter=blob:none "$repository" "$directory"
    newly_cloned=1
  fi
  if [ "$newly_cloned" -eq 0 ] && [ -n "$(git -C "$directory" status --porcelain)" ]; then
    echo "adapter dependency checkout is dirty: $directory" >&2
    exit 1
  fi

  if ! git -C "$directory" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$directory" fetch --quiet --depth 1 origin "$commit"
  fi
  git -C "$directory" checkout --quiet --detach "$commit"
  actual=$(git -C "$directory" rev-parse HEAD)
  if [ "$actual" != "$commit" ]; then
    echo "adapter dependency pin mismatch for $name: $actual" >&2
    exit 1
  fi
  if [ -n "$(git -C "$directory" status --porcelain)" ]; then
    echo "adapter dependency checkout changed during bootstrap: $directory" >&2
    exit 1
  fi
}

ensure_checkout plenary.nvim https://github.com/nvim-lua/plenary.nvim.git 74b06c6c75e4eeb3108ec01852001636d85a932b
ensure_checkout telescope.nvim https://github.com/nvim-telescope/telescope.nvim.git 5255aa27c422de944791318024167ad5d40aad20
ensure_checkout blink.cmp https://github.com/Saghen/blink.cmp.git 78336bc89ee5365633bcf754d93df01678b5c08f
ensure_checkout nvim-cmp https://github.com/hrsh7th/nvim-cmp.git 8c82d0bd31299dbff7f8e780f5e06d2283de9678

echo "Pinned adapter dependencies are ready"
