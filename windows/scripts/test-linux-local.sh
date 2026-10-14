#!/usr/bin/env bash
# Validação local no Fedora/Ubuntu antes de confiar no pacote ou no CI.
# Uso: ./scripts/test-linux-local.sh
#      ./scripts/test-linux-local.sh package   # inclui tauri build (demorado)
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

fail=0
run() {
  if "$@"; then
    green "OK: $*"
  else
    red "FALHOU: $*"
    fail=1
  fi
}

step "Dependências de sistema (pkg-config)"
missing=
for pc in gtk+-3.0 webkit2gtk-4.1; do
  if ! pkg-config --exists "$pc" 2>/dev/null; then
    missing="$missing $pc"
  fi
done
# Fedora: appindicator3-0.1 (libappindicator-gtk3-devel)
# Debian/Ubuntu: ayatana-appindicator3-0.1 (libayatana-appindicator3-dev)
if ! pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null \
  && ! pkg-config --exists appindicator3-0.1 2>/dev/null; then
  missing="$missing appindicator3-0.1|ayatana-appindicator3-0.1"
fi
if [ -n "$missing" ]; then
  red "Pacotes de desenvolvimento em falta (pkg-config):$missing"
  echo "Fedora: sudo dnf install webkit2gtk4.1-devel gtk3-devel libappindicator-gtk3-devel librsvg2-devel"
  echo "Debian/Ubuntu: sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev"
  exit 1
fi
green "OK: bibliotecas GTK/WebKit encontradas"

step "Testes Node (UI)"
run node scripts/check-ui-scripts.mjs
run node --test test-codex-headline.cjs
run node --test test-carry.cjs
run node --test test-light-surface.cjs

step "Rust: hook"
run cargo test --locked -p codenotch-hook

step "Rust: codenotch (unitários)"
run cargo test --locked -p codenotch

step "Build release + doctor (sem GUI longa)"
run cargo build --release --locked -p codenotch
run env GDK_BACKEND=x11 "$root/target/release/codenotch" doctor

if [ "${1:-}" = package ]; then
  step "Empacotamento Tauri (deb + AppImage nesta máquina)"
  run ./scripts/package-linux.sh
  deb=$(find target/release/bundle/deb -name '*.deb' 2>/dev/null | head -1)
  appimage=$(find target/release/bundle/appimage -name '*.AppImage' 2>/dev/null | head -1)
  [ -n "$deb" ] && green "Deb: $deb"
  [ -n "$appimage" ] && green "AppImage: $appimage"
  if [ -n "$appimage" ]; then
    run env GDK_BACKEND=x11 "$appimage" doctor
  fi
fi

step "Teste manual (você)"
echo "1. ./scripts/run-linux.sh          — notch na borda direita"
echo "2. ./scripts/run-linux.sh doctor   — mesmo que acima, explícito"
echo "3. Settings → Install hooks        — exige codenotch-hook ao lado do binário (pacote .deb)"
echo "4. GNOME: extensão AppIndicator Support para ver a bandeja"
echo "5. Opcional: sudo dnf install wmctrl — foco no terminal ao clicar sessão"

if [ "$fail" -ne 0 ]; then
  red "Alguns passos automáticos falharam."
  exit 1
fi
green "Passos automáticos concluídos."
