#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Instalador do Unificador VR
#  Dê dois cliques neste arquivo no Finder.
#  Se o macOS bloquear: botão direito → Abrir (ou arraste este
#  arquivo para uma janela do Terminal e aperte Enter).
#  Serve também para ATUALIZAR: baixe a versão nova e rode de novo.
# ─────────────────────────────────────────────────────────────
cd "$(dirname "$0")" || exit 1
LOG="$HOME/Desktop/UnificadorVR_instalacao.log"

bold=$'\e[1m'; red=$'\e[31m'; green=$'\e[32m'; yellow=$'\e[33m'; reset=$'\e[0m'
step() { echo; echo "${bold}▸ $*${reset}"; }
fail() {
  echo; echo "${red}${bold}✗ $*${reset}"
  echo "  O registro completo está em: $LOG"
  echo "  Mande esse arquivo (ou a mensagem acima) para quem está te ajudando."
  echo; read -r -p "Aperte Enter para fechar…"; exit 1
}

clear
echo "${bold}Instalador do Unificador VR${reset}"
echo "Isso leva de 2 a 5 minutos (mais, se precisar baixar as ferramentas da Apple)."

# 1. Sistema
step "Conferindo o macOS…"
[[ "$(uname)" == "Darwin" ]] || fail "Este instalador só funciona no Mac."
OSV="$(sw_vers -productVersion)"
[[ "${OSV%%.*}" -ge 13 ]] || fail "Precisa do macOS 13 (Ventura) ou mais novo. Este Mac tem $OSV."
echo "  macOS $OSV, $(uname -m) — ok"

# 2. Ferramentas de desenvolvimento da Apple (Swift)
step "Conferindo as ferramentas da Apple (Swift)…"
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "${yellow}  As ferramentas da Apple não estão instaladas.${reset}"
  echo "  Vai abrir uma janela do macOS: clique em ${bold}Instalar${reset} e aceite a licença."
  echo "  (Download de ~1 GB. Este instalador espera e continua sozinho.)"
  xcode-select --install >/dev/null 2>&1
  for _ in $(seq 1 360); do   # até 60 minutos
    xcrun --find swift >/dev/null 2>&1 && break
    sleep 10
  done
  xcrun --find swift >/dev/null 2>&1 || fail "As ferramentas não terminaram de instalar. Rode este instalador de novo quando a instalação da Apple acabar."
fi
SWV="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)"
read -r SMAJ SMIN <<< "$SWV"
if [[ -z "$SMAJ" ]] || (( SMAJ < 5 || (SMAJ == 5 && SMIN < 9) )); then
  fail "O Swift deste Mac é antigo (${SMAJ:-?}.${SMIN:-?}); precisa 5.9 ou mais novo. Atualize o Xcode ou as Command Line Tools em Ajustes do Sistema › Geral › Atualização de Software."
fi
echo "  Swift $SMAJ.$SMIN — ok"

# 3. Compilar, testar e instalar
step "Compilando, testando e instalando (pode demorar alguns minutos na primeira vez)…"
chmod +x ./build_app.sh
if ! ./build_app.sh --install > "$LOG" 2>&1; then
  tail -25 "$LOG"
  fail "Algo deu errado na compilação."
fi
grep -E "Executed .* tests" "$LOG" | tail -1 | sed 's/^[[:space:]]*/  /'
APP_PATH="$(cat build/.installed_path 2>/dev/null)"
[[ -d "$APP_PATH" ]] || fail "O app não foi encontrado depois da instalação."

# 4. Pronto
echo
echo "${green}${bold}✓ Unificador VR instalado em: $APP_PATH${reset}"
echo "  Ele aparece no Launchpad e na pasta Aplicativos."
echo "  Na primeira vez, o macOS pode pedir permissão para acessar cartões e discos: clique em Permitir."
open "$APP_PATH"
echo; read -r -p "Aperte Enter para fechar esta janela…"
