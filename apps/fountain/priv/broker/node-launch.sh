# Sprite's PATH entry is an NVM shell launcher. Its exact default can be
# resolved without sourcing NVM; aliases and unfamiliar layouts use the
# launcher itself. Never choose a different installed version or override a
# custom Node earlier on PATH. Ordinary images (including E2B) use PATH.
relay_node() {
  local selected nvm_dir version candidate
  selected=$(command -v node) || return 1
  if [ "$selected" = "/.sprite/bin/node" ]; then
    nvm_dir=${NVM_DIR:-/.sprite/languages/node/nvm}
    # Match the Sprite launcher's fallback when an inherited NVM_DIR is stale.
    [ -s "$nvm_dir/nvm.sh" ] || nvm_dir="/.sprite/languages/node/nvm"
    if [ -s "$nvm_dir/nvm.sh" ] && [ -r "$nvm_dir/alias/default" ]; then
      version=$(cat "$nvm_dir/alias/default")
      if [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        candidate="$nvm_dir/versions/node/v${version#v}/bin/node"
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then selected=$candidate; fi
      fi
    fi
  fi
  printf '%s\n' "$selected"
}
