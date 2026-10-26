#!/usr/bin/env bash
# Prepara o projeto J.A.R.V.I.S. no Mac: baixa o código, gera o projeto do Xcode e abre.
# Uso: curl -fsSL https://raw.githubusercontent.com/willimoreira/gh-auth-login/claude/jarvis-virtual-assistant-gemma-e1v5u0/scripts/setup-mac.sh | bash
set -euo pipefail

REPO="https://github.com/willimoreira/gh-auth-login.git"
BRANCH="claude/jarvis-virtual-assistant-gemma-e1v5u0"
DEST="${JARVIS_DIR:-$HOME/Developer/Jarvis}"

echo "▶ J.A.R.V.I.S. — preparando em $DEST"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "✖ Este script precisa rodar num Mac." >&2; exit 1
fi

if ! xcode-select -p >/dev/null 2>&1 || [[ ! -d /Applications/Xcode.app && -z "$(ls -d /Applications/Xcode*.app 2>/dev/null)" ]]; then
  echo "✖ Instale o Xcode 26 ou mais novo pela App Store e rode este script de novo." >&2
  open "macappstore://apps.apple.com/app/xcode/id497799835" || true
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "▶ Instalando Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

command -v xcodegen >/dev/null 2>&1 || { echo "▶ Instalando XcodeGen…"; brew install xcodegen; }

if [[ -d "$DEST/.git" ]]; then
  echo "▶ Atualizando código existente…"
  git -C "$DEST" fetch origin "$BRANCH"
  git -C "$DEST" checkout "$BRANCH"
  git -C "$DEST" pull --ff-only origin "$BRANCH"
else
  echo "▶ Baixando código…"
  mkdir -p "$(dirname "$DEST")"
  git clone -b "$BRANCH" "$REPO" "$DEST"
fi

cd "$DEST"
echo "▶ Gerando Jarvis.xcodeproj…"
xcodegen generate

echo "▶ Baixando dependências Swift (MLX, Hugging Face)… pode levar alguns minutos"
xcodebuild -resolvePackageDependencies -project Jarvis.xcodeproj -scheme Jarvis >/dev/null \
  || echo "⚠ Não consegui resolver os pacotes agora; o Xcode tentará ao abrir."

open Jarvis.xcodeproj

cat <<'MSG'

✔ Pronto! O Xcode foi aberto. Faltam 3 cliques:
  1. Target "Jarvis" › Signing & Capabilities › escolha seu Team (Apple ID).
  2. Se aparecer, clique em "Trust & Enable" para os macros do MLXHuggingFace.
  3. Product › Scheme › Edit Scheme › Run › Build Configuration = Release,
     conecte o iPhone (Modo Desenvolvedor ativo) e aperte ▶ Run.
MSG
