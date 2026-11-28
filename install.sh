#!/bin/bash
# ==============================================================================
#  install.sh — Instalador da rotina de vacuum/analyze PostgreSQL · MigraTI · versão 2.5
#
#  Uso:
#    sudo bash install.sh                         baixa o pacote do dia (sem token)
#    sudo bash install.sh --package pacote.tar.gz usa um pacote local
#    sudo bash install.sh --branch BRANCH         baixa de outro branch
#    sudo bash install.sh --uninstall             remove a rotina (mantém os logs)
#
#  Modos detectados automaticamente: instalação nova, migração da 1.x e
#  atualização da 2.x. Nada é alterado no servidor antes de o pacote ser
#  baixado e aberto com a chave de distribuição do dia (DIST_KEY_TODAY).
#  A rotina de backup (migra-wallet-pg) pode estar no mesmo diretório: os
#  arquivos dela nunca são alterados por este instalador.
# ==============================================================================
set -o pipefail
umask 077
export LC_ALL=C

VERSAO_INSTALADOR="2.5"
GITHUB_ORG="MigraTI"
GITHUB_REPO="vacuum-postgres-instalador"   # público: só install.sh + pacote cifrado (o código fica no repositório privado)
GITHUB_BRANCH="main"
PACOTE_NOME="migravacuum"                   # migravacuum.tar.gz, com a pasta migravacuum/
DIR_PADRAO="/etc/migrabkp"
BIN_CMD="${MIGRA_BIN_CMD:-/usr/bin}"         # comandos: /usr/bin está no PATH de qualquer usuário, root inclusive
LINK_TOOL="$BIN_CMD/migra-wallet-vacuum"
BIN_CMD_ANTIGO="/usr/local/bin"                          # 2.0 a 2.3 (fora do PATH do root em algumas distribuições)
LINK_TOOL_ANTIGO="$BIN_CMD_ANTIGO/migra-wallet-vacuum"
LINKS_BKP=("$BIN_CMD/migra-wallet-pg" /usr/local/bin/migra-wallet-pg)   # rotina de backup 2.x: só lido
WALLET_NOME="migra-vacuum.wallet"
AUTO_NOME="migra-vacuum.auto"
CRON_TAG="# Vacuum/Analyze PostgreSQL - MigraTI"   # comentário da 2.0/2.1 acima das linhas (trocado pela arte)
# Arte da rotina no crontab do root, acima das linhas dela e separada por uma linha em branco
# (mesma moldura da arte do backup: 58 colunas, bordas de 4 #)
CRON_ARTE=(
    '##########################################################'
    '####              Vacuum/Analyze MigraTI              ####'
    '####     Telefone para suporte (47) 3328-0996         ####'
    '####                www.migrati.com.br                ####'
    '##########################################################'
)
CRON_ARTE_22=(   # arte da 2.2 (44 colunas, sem linha em branco): trocada na atualização
    '############################################'
    '###         Vacuum/Analyze MigraTI       ###'
    '### Telefone para suporte (47) 3328-0996 ###'
    '###         www.migrati.com.br           ###'
    '############################################'
)
PENDENCIAS=()   # "texto|detalhe": ações que o técnico precisa fazer (mostradas no fim)
CONF_1X_LINK="/etc/migra_vacuum.conf"
SCRIPTS=(vacuum_analyze.sh migra-wallet-vacuum)
OPERACOES="analyze vacuum all freeze"
TS=$(date +%Y%m%d_%H%M%S)

# >>> MIGRA-CRYPT v2 >>>
# ------------------------------------------------------------------------------
# Bloco compartilhado: criptografia da wallet + schema da configuração.
# Fonte de verdade: lib/migra-crypt.sh. Ele é copiado, idêntico, para dentro de
# install.sh, vacuum_analyze.sh e migra-wallet-vacuum por scripts/sync-crypt-block.sh.
# NÃO edite a cópia dentro dos scripts: edite a lib e rode o sync.
# ------------------------------------------------------------------------------
MC_MAGIC='# MIGRA-WALLET-VACUUM v2'
MC_ITER=600000
MC_SECRET_KEYS=" PGPASSWORD "
# Chaves que já existiram e saíram do schema: ignoradas na leitura e removidas na
# atualização da wallet (T_KEY_ROTINA = Vacuum_Analyze, que não existe no Zabbix; saiu na 2.5).
MC_OBSOLETE_KEYS=" T_KEY_ROTINA "

# CHAVE|tipo|padrão|descrição
#   tipos: txt (livre)  req (obrigatório)  int (inteiro >= 0)  lvl (0-9)
#          yn (S/N)  path (absoluto ou vazio)
#          apath (absoluto obrigatório)  secret (senha; mascarada na exibição)
#          multi (pode repetir a linha; os valores ficam juntos, separados por quebra de linha)
MC_SCHEMA=(
    "VERSION|txt|2.5|Versão da rotina que gerou esta wallet"
    "PGHOST|req|localhost|Host do PostgreSQL (ou diretório do socket)"
    "PGPORT|int|5432|Porta do PostgreSQL"
    "PGUSER|req|migrabkp|Usuário do banco (superuser, ou membro de pg_maintain no PostgreSQL 17+)"
    "PGPASSWORD|secret||Senha do usuário (vira .pgpass temporário em RAM; nunca é exportada)"
    "PGDATABASE|req|postgres|Banco usado para conectar e listar as bases"
    "PG_BIN|apath|/usr/bin|Diretório do psql"
    "LOG_GERAL|apath|/var/log/backup/vacuum_analyze_geral.log|Log geral da rotina"
    "PARALLEL_JOBS|int|2|Tabelas processadas ao mesmo tempo (1 a 32)"
    "LOCK_TIMEOUT|int|300|Segundos esperando o lock de cada tabela antes de pular para a próxima (0 = sem limite)"
    "EXCLUDE_BASES|txt|postgres|Bases ignoradas, separadas por vírgula (templates nunca entram)"
    "EXCLUDE_TABLE|multi||Tabela ou schema ignorado, uma linha por item: base, schema, tabela (* = schema inteiro), motivo, usuário e data separados por barra vertical; base * vale para todas (use migra-wallet-vacuum -excludeTable)"
    "RETENCAO_LOG_DB|int|7|Retenção dos logs por base, em dias"
    "TITAN|yn|N|Enviar status ao Zabbix/Titan"
    "PATH_TITAN|path|/usr/bin|Diretório do zabbix_sender"
    "SENDER|txt|zabbix_sender|Nome do executável do sender"
    "T_CONF|path|/etc/zabbix/zabbix_agentd.conf|Configuração do agente Zabbix"
    "T_IP|txt||Servidor Zabbix/Titan"
    "T_HOST|txt||Hostname cadastrado no Zabbix"
    "T_KEY_VACUUM|txt|Vacuum|Chave no Zabbix do VACUUM (operações vacuum e all): 0 OK, 1 erro"
    "T_KEY_ANALYZE|txt|Analyze|Chave no Zabbix do ANALYZE (operações analyze e all): 0 OK, 1 erro"
    "T_KEY_FREEZE|txt|Freeze|Chave no Zabbix do VACUUM FREEZE (operação freeze): 0 OK, 1 erro"
)

# Arquivo temporário em RAM quando possível (chmod 600 garantido pelo umask 077 do chamador
# e reforçado aqui).
_mc_tmp() {
    local t=""
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        t=$(mktemp -p /dev/shm .migra.XXXXXXXXXX 2>/dev/null)
    fi
    if [ -z "$t" ]; then
        t=$(mktemp "${TMPDIR:-/tmp}/.migra.XXXXXXXXXX") || return 1
    fi
    chmod 600 "$t" && printf '%s\n' "$t"
}

# Chave da máquina = SHA-256 do machine-id. Retorna 1 se não houver machine-id válido
# (arquivo ausente OU vazio — imagens de VM costumam ter o arquivo vazio).
_mc_machine_key() {
    local f m=""
    for f in ${MC_MACHINE_ID_FILES:-/etc/machine-id /var/lib/dbus/machine-id}; do
        [ -r "$f" ] || continue
        m=$(tr -d '[:space:]' < "$f")
        [ -n "$m" ] && break
    done
    [ -n "$m" ] || return 1
    printf '%s' "$m" | openssl dgst -sha256 | awk '{print $NF}'
}

# OpenSSL >= 1.1.1 aceita -pbkdf2/-iter.
_mc_has_pbkdf2() {
    _MC_PASS=teste openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 1 \
        -pass env:_MC_PASS -in /dev/null -out /dev/null 2>/dev/null
}

# _mc_cipher <e|d> <legacy|pbkdf2> <iter> <senha> [entrada] [saida]
# "-" (ou omitido) = stdin/stdout. A senha vai por variável de ambiente, nunca por argumento.
_mc_cipher() {
    local mode="$1" kdf="$2" iter="$3" pass="$4" in="${5:--}" out="${6:--}"
    local -a args=(enc -aes-256-cbc -md sha256)
    if [ "$mode" = d ]; then args+=(-d); fi
    case "$kdf" in
        pbkdf2) args+=(-pbkdf2 -iter "$iter") ;;
        legacy) ;;
        *) return 1 ;;
    esac
    if [ "$in" != "-" ]; then args+=(-in "$in"); fi
    if [ "$out" != "-" ]; then args+=(-out "$out"); fi
    _MC_PASS="$pass" openssl "${args[@]}" -pass env:_MC_PASS 2>/dev/null
}

# _mc_write <arquivo> <WALLET|AUTO> <legacy|pbkdf2> <senha> <arquivo_texto>
# Gravação atômica: cifra num temporário do mesmo diretório e faz mv.
_mc_write() {
    local file="$1" kind="$2" kdf="$3" pass="$4" plain="$5" iter=0 tmp
    if [ "$kdf" = pbkdf2 ]; then iter=$MC_ITER; fi
    tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX") || return 1
    chmod 600 "$tmp"
    if { printf 'MIGRA%s 2 %s %s\n' "$kind" "$kdf" "$iter" \
         && _mc_cipher e "$kdf" "$iter" "$pass" "$plain" -; } > "$tmp"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _mc_read <arquivo> <senha>  -> texto em stdout
# Retorno: 0 ok | 1 senha/chave incorreta | 2 arquivo ausente ou formato inválido
_mc_read() {
    local file="$1" pass="$2" magic ver kdf iter hlen out
    [ -r "$file" ] || return 2
    read -r magic ver kdf iter < "$file" || return 2
    case "$magic" in MIGRAWALLET|MIGRAAUTO) ;; *) return 2 ;; esac
    [ "$ver" = 2 ] || return 2
    case "$kdf" in pbkdf2|legacy) ;; *) return 2 ;; esac
    [[ "$iter" =~ ^[0-9]+$ ]] || return 2
    hlen=$(head -n 1 "$file" | wc -c)
    # tr remove NUL: só aparece quando a chave está errada e o resultado é lixo.
    out=$(tail -c +"$((hlen + 1))" "$file" | _mc_cipher d "$kdf" "$iter" "$pass" | tr -d '\000') || return 1
    [ "${out%%$'\n'*}" = "$MC_MAGIC" ] || return 1
    printf '%s\n' "$out"
}

# Tipo de criptografia que a wallet deve usar nesta máquina.
_mc_wallet_kdf() {
    if _mc_has_pbkdf2; then echo pbkdf2; else echo legacy; fi
}

_mc_schema_field() { # <CHAVE> <n: 2=tipo 3=padrão 4=descrição>
    local e k t d s
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        if [ "$k" = "$1" ]; then
            case "$2" in 2) printf '%s' "$t" ;; 3) printf '%s' "$d" ;; 4) printf '%s' "$s" ;; esac
            return 0
        fi
    done
    return 1
}

_mc_known_key() { _mc_schema_field "$1" 2 >/dev/null; }
_mc_is_secret() { [[ "$MC_SECRET_KEYS" == *" $1 "* ]]; }
_mc_is_obsolete() { [[ "$MC_OBSOLETE_KEYS" == *" $1 "* ]]; }

# Define todas as variáveis do schema com o valor padrão.
_mc_defaults() {
    local e k t d s
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        printf -v "$k" '%s' "$d"
    done
}

# _mc_parse <texto> : atribui CHAVE=valor (literal, sem expansão). Nunca usa source/eval.
# Retorna 1 (com mensagens em stderr) se houver linha inválida ou chave desconhecida.
_mc_parse() {
    local line key val n=0 rc=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^[A-Z][A-Z0-9_]*= ]]; then
            echo "linha $n: formato inválido (use CHAVE=valor)" >&2
            rc=1; continue
        fi
        key="${line%%=*}"
        _mc_is_obsolete "$key" && continue
        if ! _mc_known_key "$key"; then
            echo "linha $n: chave desconhecida: $key" >&2
            rc=1; continue
        fi
        val="${line#*=}"
        if [ "$(_mc_schema_field "$key" 2)" = multi ]; then   # linhas repetidas se acumulam
            [ -n "$val" ] || continue
            if [ -n "${!key}" ]; then printf -v "$key" '%s\n%s' "${!key}" "$val"
            else printf -v "$key" '%s' "$val"; fi
            continue
        fi
        printf -v "$key" '%s' "$val"
    done <<< "$1"
    return $rc
}

# Valida os valores já carregados nas variáveis. Mensagens em stderr; retorna 1 se inválido.
_mc_validate() {
    local e k t d s v l a b c x n rc=0
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        v="${!k}"
        case "$t" in
            req)   [ -n "$v" ] || { echo "$k: obrigatório" >&2; rc=1; } ;;
            int)   [[ "$v" =~ ^[0-9]+$ ]] || { echo "$k: precisa ser número inteiro (atual: '$v')" >&2; rc=1; } ;;
            lvl)   [[ "$v" =~ ^[0-9]$ ]] || { echo "$k: precisa ser de 0 a 9 (atual: '$v')" >&2; rc=1; } ;;
            yn)    [[ "$v" =~ ^[SN]$ ]] || { echo "$k: use S ou N (atual: '$v')" >&2; rc=1; } ;;
            path)  [ -z "$v" ] || [[ "$v" == /* ]] || { echo "$k: precisa ser caminho absoluto (atual: '$v')" >&2; rc=1; } ;;
            apath) [[ "$v" == /* ]] || { echo "$k: precisa ser caminho absoluto (atual: '$v')" >&2; rc=1; } ;;
            multi)
                n=0
                while IFS= read -r l; do
                    [ -n "$l" ] || continue
                    n=$((n + 1))
                    IFS='|' read -r a b c x <<< "$l"
                    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
                        echo "$k (item $n): use base|schema|tabela|motivo|usuário|data, com * em tabela para o schema inteiro (atual: '$l')" >&2; rc=1
                    fi
                done <<< "$v" ;;
        esac
    done
    if [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && { [ "$PARALLEL_JOBS" -lt 1 ] || [ "$PARALLEL_JOBS" -gt 32 ]; }; then
        echo "PARALLEL_JOBS: use de 1 a 32 (atual: '$PARALLEL_JOBS')" >&2; rc=1
    fi
    if [ "$TITAN" = S ]; then
        [ -n "$T_IP" ] || { echo "T_IP: obrigatório com TITAN=S" >&2; rc=1; }
        [ -n "$T_HOST" ] || { echo "T_HOST: obrigatório com TITAN=S" >&2; rc=1; }
    fi
    return $rc
}

# _mc_txt_set <texto> <CHAVE> <valor> -> texto com a linha CHAVE= trocada (ou acrescentada)
_mc_txt_set() {
    local line found=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$2="* ]]; then
            printf '%s=%s\n' "$2" "$3"; found=1
        else
            printf '%s\n' "$line"
        fi
    done <<< "$1"
    if [ "$found" = 0 ]; then printf '%s=%s\n' "$2" "$3"; fi
}

# _mc_txt_get <texto> <CHAVE> -> valor (vazio se ausente)
_mc_txt_get() {
    local line v=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" == "$2="* ]]; then v="${line#*=}"; fi
    done <<< "$1"
    printf '%s' "$v"
}

# _mc_txt_sem_obsoletas <texto> -> texto sem as linhas das chaves obsoletas (e sem o
# comentário logo acima de cada uma, que é o que o _mc_render escreve)
_mc_txt_sem_obsoletas() {
    local line ant="" tem_ant=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]] && _mc_is_obsolete "${BASH_REMATCH[1]}"; then
            [[ "$ant" == \#* ]] && tem_ant=0
            continue
        fi
        [ "$tem_ant" = 1 ] && printf '%s\n' "$ant"
        ant="$line"; tem_ant=1
    done <<< "$1"
    [ "$tem_ant" = 1 ] && printf '%s\n' "$ant"
    return 0
}

# _mc_txt_merge <texto> -> tira as chaves obsoletas e acrescenta as do schema que faltam (com o padrão)
_mc_txt_merge() {
    local e k t d s out
    out=$(_mc_txt_sem_obsoletas "$1")
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        [ "$t" = multi ] && continue          # lista: ausente = vazia
        if ! grep -q "^${k}=" <<< "$out"; then
            out="${out}"$'\n\n'"# ${s}"$'\n'"${k}=${d}"
        fi
    done
    printf '%s\n' "$out"
}

# Gera o texto da wallet a partir das variáveis atuais (com comentários do schema).
_mc_render() {
    local e k t d s l
    printf '%s\n' "$MC_MAGIC"
    printf '# Gerado em %s. Formato: CHAVE=valor (valor literal, sem aspas).\n' "$(date '+%d/%m/%Y %T')"
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        if [ "$t" = multi ]; then
            printf '\n# %s\n# Exemplos: %s=vendas|public|log_auditoria|tabela grande, vacuum manual|vitor|16/11/2026\n#           %s=vendas|staging|*|schema de carga temporária|vitor|16/11/2026\n' "$s" "$k" "$k"
            if [ -n "${!k}" ]; then
                while IFS= read -r l; do [ -n "$l" ] && printf '%s=%s\n' "$k" "$l"; done <<< "${!k}"
            fi
            continue
        fi
        printf '\n# %s\n%s=%s\n' "$s" "$k" "${!k}"
    done
}

# Lista de tabelas ignoradas: helpers de texto (EXCLUDE_TABLE=base|schema|tabela|motivo|usuário|data)
# _mc_et_has <texto> <base> <schema> <tabela> : 0 se a tabela já está na lista
_mc_et_has() {
    local line a b c x
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == EXCLUDE_TABLE=* ]] || continue
        IFS='|' read -r a b c x <<< "${line#EXCLUDE_TABLE=}"
        [ "$a" = "$2" ] && [ "$b" = "$3" ] && [ "$c" = "$4" ] && return 0
    done <<< "$1"
    return 1
}

# _mc_et_del <texto> <base> <schema> <tabela> -> texto sem a linha da tabela
_mc_et_del() {
    local line a b c x
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == EXCLUDE_TABLE=* ]]; then
            IFS='|' read -r a b c x <<< "${line#EXCLUDE_TABLE=}"
            [ "$a" = "$2" ] && [ "$b" = "$3" ] && [ "$c" = "$4" ] && continue
        fi
        printf '%s\n' "$line"
    done <<< "$1"
}
# <<< MIGRA-CRYPT v2 <<<

# ------------------------------------------------------------------------------
# Interface
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi
log()    { echo -e "  ${GREEN}✔${NC}  $*"; }
info()   { echo -e "  ${CYAN}•${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}▲${NC}  $*"; }
err()    { echo -e "  ${RED}✖  $*${NC}" >&2; }
abort()  { err "$*"; exit 1; }

LINHA='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
header() {   # faixa de seção
    echo
    echo -e "  ${BLUE}${LINHA}${NC}"
    echo -e "   ${BOLD}$*${NC}"
    echo -e "  ${BLUE}${LINHA}${NC}"
}
dica_voltar() { echo -e "  ${DIM}Enter mantém o valor entre [ ]   ·   ← (seta para a esquerda) volta à pergunta anterior${NC}"; echo; }

como_responder() { # aviso mostrado logo no início
    echo
    echo -e "   ${BOLD}Como responder${NC}"
    echo -e "     ${CYAN}Enter${NC}   aceita o valor sugerido entre [ ]"
    echo -e "     ${CYAN}←${NC}       (seta para a esquerda, com o campo vazio) volta à pergunta anterior"
    echo -e "     ${CYAN}<${NC}       e Enter faz o mesmo, se a seta não funcionar no seu terminal"
    echo -e "     ${CYAN}Ctrl+C${NC}  cancela; nada é alterado até você confirmar o resumo no final"
}

banner() {   # só ASCII dentro da moldura, para as bordas alinharem em qualquer terminal
    echo
    echo -e "  ${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "  ${BLUE}║${NC}  ${BOLD}%-46s${NC}%14s${BLUE}║${NC}\n" "MigraTI  -  Vacuum/Analyze PostgreSQL" "versao $VERSAO_INSTALADOR  "
    printf "  ${BLUE}║${NC}  %-60s${BLUE}║${NC}\n" "Instalador da rotina"
    echo -e "  ${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# Largura visível de um texto UTF-8 (com LC_ALL=C, ${#s} conta bytes)
_vlen() { local s="$1" c; c="${s//[^$'\x80'-$'\xbf']/}"; echo $(( ${#s} - ${#c} )); }
linha_resumo() { # <rótulo> <valor> : coluna de valores alinhada
    local pad=$(( 24 - $(_vlen "$1") )); [ "$pad" -lt 1 ] && pad=1
    printf "   ${DIM}%s${NC}%*s%b\n" "$1" "$pad" "" "$2"
}

TTY=/dev/tty
STTY_ORIG=""
_restaura_tty() { [ -n "$STTY_ORIG" ] && stty "$STTY_ORIG" < "$TTY" 2>/dev/null; STTY_ORIG=""; }

# Lê uma linha do terminal, tecla por tecla, para reconhecer a seta ←.
#   ← com o campo vazio (ou "<" + Enter) = voltar (retorno 2). Backspace apaga; Ctrl+U limpa.
#   Sem terminal interativo (stty falha), cai no read comum.
_le_linha() { # <variável> <oculto 0|1>
    local _ll_b="" _ll_c _ll_r _ll_x _ll_u
    if ! STTY_ORIG=$(stty -g < "$TTY" 2>/dev/null) || ! stty -echo -icanon min 1 time 0 < "$TTY" 2>/dev/null; then
        STTY_ORIG=""
        if [ "$2" = 1 ]; then IFS= read -rs _ll_b < "$TTY"; printf '\n' > "$TTY"; else IFS= read -r _ll_b < "$TTY"; fi
        [ "$_ll_b" = "<" ] && return 2
        printf -v "$1" '%s' "$_ll_b"; return 0
    fi
    while IFS= read -r -n1 -d '' _ll_c < "$TTY"; do
        case "$_ll_c" in
            $'\n'|$'\r') break ;;
            $'\x7f'|$'\b')
                [ -n "$_ll_b" ] || continue
                while :; do   # tira um caractere UTF-8 inteiro
                    _ll_u="${_ll_b: -1}"; _ll_b="${_ll_b%?}"
                    [[ "$_ll_u" == [$'\x80'-$'\xbf'] ]] && [ -n "$_ll_b" ] || break
                done
                [ "$2" = 1 ] || printf '\b \b' > "$TTY" ;;
            $'\x15')
                [ "$2" = 1 ] || printf '\r\033[K%b' "$PROMPT_ATUAL" > "$TTY"
                _ll_b="" ;;
            $'\e')
                _ll_r=""; IFS= read -r -n2 -t 0.05 -d '' _ll_r < "$TTY"
                if [[ "$_ll_r" == "["[0-9] ]]; then   # sequências longas (Delete, Home...): descarta até o "~"
                    while IFS= read -r -n1 -t 0.05 -d '' _ll_x < "$TTY" && [ "$_ll_x" != "~" ]; do :; done
                fi
                if { [ "$_ll_r" = "[D" ] || [ "$_ll_r" = "OD" ]; } && [ -z "$_ll_b" ]; then
                    _restaura_tty; printf '\n' > "$TTY"; return 2
                fi ;;
            [[:cntrl:]]) ;;
            *) _ll_b+="$_ll_c"; [ "$2" = 1 ] || printf '%s' "$_ll_c" > "$TTY" ;;
        esac
    done
    _restaura_tty
    printf '\n' > "$TTY"
    [ "$_ll_b" = "<" ] && return 2
    printf -v "$1" '%s' "$_ll_b"
}

PROMPT_ATUAL=""
_prompt() { PROMPT_ATUAL="$1"; printf '%b' "$1" > "$TTY"; }

ask() {      # <variável> <pergunta> [padrão] ; retorna 2 para voltar (← ou "<")
    local __v=""
    if [ -n "${3:-}" ]; then
        _prompt "  ${CYAN}›${NC} $2 ${DIM}[${3}]${NC}: "
    else
        _prompt "  ${CYAN}›${NC} $2: "
    fi
    _le_linha __v 0 || return 2
    printf -v "$1" '%s' "${__v:-${3:-}}"
}

askyn() {    # <pergunta> <padrão S|N> ; retorna 0 para sim
    local __r="" __d="$2"
    while true; do
        _prompt "  ${CYAN}›${NC} $1 ${DIM}[$( [ "$__d" = S ] && echo 'S/n' || echo 's/N')]${NC}: "
        _le_linha __r 0 || { warn "Aqui não dá para voltar: responda S ou N."; continue; }
        __r="${__r:-$__d}"
        [[ "$__r" =~ ^[sSnN]$ ]] && break
        warn "Responda S ou N."
    done
    [[ "$__r" =~ ^[sS]$ ]]
}

askpass() {  # <variável> <pergunta> ; retorna 2 para voltar (← ou "<")
    local __v=""
    _prompt "  ${CYAN}›${NC} $2: "
    _le_linha __v 1 || return 2
    printf -v "$1" '%s' "$__v"
}

# Pergunta uma variável com validação pelo tipo (do schema ou informado). Usa o valor atual
# como padrão. Retorna 2 quando o usuário digita "<".
askkey() {   # <CHAVE> <pergunta> [tipo]
    local k="$1" q="$2" t="${3:-}" v
    [ -n "$t" ] || t=$(_mc_schema_field "$k" 2)
    while true; do
        ask v "$q" "${!k}" || return 2
        case "$t" in
            yn)    v="${v^^}"; [[ "$v" =~ ^[SN]$ ]] || { warn "Responda S ou N."; continue; } ;;
            int)   [[ "$v" =~ ^[0-9]+$ ]] || { warn "Informe um número inteiro."; continue; } ;;
            lvl)   [[ "$v" =~ ^[0-9]$ ]] || { warn "Informe um nível de 0 a 9."; continue; } ;;
            req)   [ -n "$v" ] || { warn "Valor obrigatório."; continue; } ;;
            apath) [[ "$v" == /* ]] || { warn "Informe um caminho absoluto."; continue; } ;;
            path)  [ -z "$v" ] || [[ "$v" == /* ]] || { warn "Informe um caminho absoluto."; continue; } ;;
            hora)  [[ "$v" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "Use HH:MM, de 00:00 a 23:59."; continue; }
                   v=$(printf '%02d:%02d' "$((10#${v%%:*}))" "$((10#${v##*:}))") ;;
        esac
        [[ "$v" != *$'\n'* ]] || continue
        printf -v "$k" '%s' "$v"
        return 0
    done
}

# ------------------------------------------------------------------------------
# Assistente de perguntas com "voltar"
#   Cada etapa: "condição|CHAVE|pergunta|tipo"
#     condição: vazia ou VAR=VALOR (várias com &) — etapa pulada se não valer
#     tipo:     vazio (schema) | yn | secret | exclude | cron | hora
#   "<" volta para a última etapa respondida (as puladas não contam).
# ------------------------------------------------------------------------------
_cond() {
    local c="$1" p var val
    [ -z "$c" ] && return 0
    IFS='&' read -ra _cs <<< "$c"
    for p in "${_cs[@]}"; do
        var="${p%%=*}"; val="${p#*=}"
        [ "${!var}" = "$val" ] || return 1
    done
}

_etapa() { # <definição> ; 0 respondida | 2 voltar | 3 não se aplica
    local cond k q t
    IFS='|' read -r cond k q t <<< "$1"
    _cond "$cond" || return 3
    case "$t" in
        secret)
            local __s
            # Senha lida do script da 1.x: só vale para o usuário da 1.x
            if [ "$k" = PGPASSWORD ] && [ -n "${SENHA_1X_VAL:-}" ]; then
                if [ "$PGUSER" = "${SENHA_1X_USER:-}" ]; then [ -n "$PGPASSWORD" ] || PGPASSWORD="$SENHA_1X_VAL"
                elif [ "$PGPASSWORD" = "$SENHA_1X_VAL" ]; then PGPASSWORD=""
                fi
            fi
            if [ -n "${!k}" ]; then askpass __s "$q (Enter mantém a atual)" || return 2
            else askpass __s "$q" || return 2; fi
            [ -n "$__s" ] && printf -v "$k" '%s' "$__s"
            return 0 ;;
        exclude) _pergunta_exclusoes; return $? ;;
        jobs)    _explica_jobs; askkey "$k" "$q"; return $? ;;
        lock)    _explica_lock; askkey "$k" "$q"; return $? ;;
        cron1)   _explica_cron; _pergunta_cron "$k" "$q"; return $? ;;
        cron)    _pergunta_cron "$k" "$q"; return $? ;;
        yn)      askkey "$k" "$q" yn; return $? ;;
        hora)    askkey "$k" "$q" hora; return $? ;;
        *)       askkey "$k" "$q"; return $? ;;
    esac
}

_assistente() { # <etapas...> ; retorna 2 quando o usuário volta da primeira pergunta
    local -a et=("$@") hist=()
    local i=0 rc n j c
    if [ "${ASSIST_DO_FIM:-0}" = 1 ]; then   # voltando da etapa seguinte: começa pela última pergunta
        for j in "${!et[@]}"; do
            IFS='|' read -r c _ <<< "${et[$j]}"
            _cond "$c" && hist+=("$j")
        done
        n=${#hist[@]}
        if [ "$n" -gt 0 ]; then i="${hist[$((n - 1))]}"; unset "hist[$((n - 1))]"; hist=("${hist[@]}"); fi
    fi
    while [ "$i" -lt "${#et[@]}" ]; do
        _etapa "${et[$i]}"; rc=$?
        case $rc in
            0) hist+=("$i"); i=$((i + 1)) ;;
            3) i=$((i + 1)) ;;
            2) n=${#hist[@]}
               if [ "$n" -gt 0 ]; then
                   i="${hist[$((n - 1))]}"; unset "hist[$((n - 1))]"; hist=("${hist[@]}")
                   echo -e "  ${DIM}↑ voltando${NC}"
               else
                   return 2
               fi ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Temporários (sempre em RAM quando possível) e limpeza
# ------------------------------------------------------------------------------
WORK=""
TMPS=()
cleanup() {
    local t
    _restaura_tty
    for t in "${TMPS[@]}"; do rm -f -- "$t"; done
    [ -n "$WORK" ] && rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'echo; err "Instalação interrompida."; exit 130' INT TERM

_tmp() { # <variável> : cria temporário em RAM, registra para limpeza (sem subshell)
    local __t; __t=$(_mc_tmp) || abort "Falha ao criar temporário"; TMPS+=("$__t"); printf -v "$1" "%s" "$__t"
}

# ------------------------------------------------------------------------------
# Argumentos e verificações iniciais
# ------------------------------------------------------------------------------
PACOTE=""; UNINSTALL=0
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --package)   PACOTE="${2:-}"; [ -n "$PACOTE" ] || abort "--package exige um arquivo"; shift 2 ;;
            --branch)    GITHUB_BRANCH="${2:-}"; [ -n "$GITHUB_BRANCH" ] || abort "--branch exige um nome"; shift 2 ;;
            --uninstall) UNINSTALL=1; shift ;;
            -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) abort "Argumento desconhecido: $1 (use --help)" ;;
        esac
    done
    if [ -n "$PACOTE" ]; then
        [ -f "$PACOTE" ] || abort "Pacote não encontrado: $PACOTE"
        PACOTE=$(readlink -f -- "$PACOTE")
    fi
}

OS_ID=""; OS_NOME=""; PM=""
check_basico() {
    [ "$(id -u)" -eq 0 ] || abort "Execute como root: sudo bash install.sh"
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || abort "É necessário bash 4 ou superior."
    { : < "$TTY"; } 2>/dev/null || abort "O instalador é interativo e precisa de um terminal."

    if [ -r /etc/os-release ]; then
        OS_ID=$(. /etc/os-release; echo "${ID:-}")
        OS_NOME=$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")
    fi
    if command -v apt-get >/dev/null 2>&1; then PM=apt-get
    elif command -v dnf >/dev/null 2>&1; then PM=dnf
    elif command -v yum >/dev/null 2>&1; then PM=yum
    elif command -v zypper >/dev/null 2>&1; then PM=zypper
    fi
    info "Sistema: ${OS_NOME:-desconhecido} · gerenciador de pacotes: ${PM:-nenhum}"

    local c falta=()
    for c in openssl tar gzip awk sed grep find flock sha256sum mktemp readlink stat; do
        command -v "$c" >/dev/null 2>&1 || falta+=("$c")
    done
    if [ -z "$PACOTE" ] && [ "$UNINSTALL" = 0 ]; then
        command -v curl >/dev/null 2>&1 || falta+=(curl)
    fi
    [ "${#falta[@]}" -eq 0 ] || abort "Comandos básicos ausentes: ${falta[*]}. Instale-os e execute novamente."

    MACHINE_KEY=$(_mc_machine_key) \
        || abort "/etc/machine-id ausente ou vazio. Gere um com 'systemd-machine-id-setup' e execute novamente."
    if _mc_has_pbkdf2; then
        info "OpenSSL $(openssl version | awk '{print $2}'): wallet com PBKDF2 ($MC_ITER iterações)"
    else
        warn "OpenSSL $(openssl version | awk '{print $2}') sem PBKDF2: wallet no formato compatível (legacy)"
    fi
}

_dir_seguro() { # rejeita diretórios do sistema e caracteres problemáticos
    local d="${1%/}"
    [[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    case "$d" in
        /|/etc|/usr|/usr/*bin|/var|/var/log|/bin|/sbin|/lib|/lib64|/root|/home|/opt|/tmp|/boot|/dev|/proc|/sys|/run) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# Detecção do modo
# ------------------------------------------------------------------------------
MODO=""; DIR=""; CONF_1X=""
declare -A V1=()

_le_conf_1x() { # lê o conf da 1.x sem executá-lo
    local line k v ref i
    V1=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        k="${BASH_REMATCH[2]}"; v="${BASH_REMATCH[3]}"
        if [[ "$v" =~ ^\"([^\"]*)\" ]]; then v="${BASH_REMATCH[1]}"
        elif [[ "$v" =~ ^\'([^\']*)\' ]]; then v="${BASH_REMATCH[1]}"
        else v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
        fi
        for i in 1 2 3 4 5; do
            [[ "$v" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]] || break
            ref="${BASH_REMATCH[1]}"
            v="${v/"${BASH_REMATCH[0]}"/${V1[$ref]:-}}"
        done
        V1["$k"]="$v"
    done < "$1"
}

_dir_da_1x() { # <conf resolvido> -> diretório base da 1.x
    local d="${V1[DIR]:-}"
    if [ -z "$d" ]; then
        d=$(dirname -- "$1")
        [ "$(basename -- "$d")" = bin ] && d=$(dirname -- "$d")
    fi
    printf '%s' "${d%/}"
}

_dir_backup_2x() { # diretório da rotina de backup 2.x, se instalada (só leitura)
    local l
    for l in "${LINKS_BKP[@]}"; do
        [ -L "$l" ] || continue
        dirname -- "$(dirname -- "$(readlink -f -- "$l")")"
        return 0
    done
    return 1
}

_dir_do_link() { # diretório da rotina pelo link do comando (/usr/bin ou o antigo /usr/local/bin)
    local l
    for l in "$LINK_TOOL" "$LINK_TOOL_ANTIGO"; do
        [ -L "$l" ] || continue
        dirname -- "$(dirname -- "$(readlink -f -- "$l")")"
        return 0
    done
    return 1
}

detecta_modo() { # [passo] : 4 = volta direto à pergunta do diretório (instalação nova)
    local dir2="" resp passo="${1:-1}"
    if [ "$passo" = 4 ]; then _pergunta_dir_nova; return $?; fi
    header "Instalação existente"
    if dir2=$(_dir_do_link); then
        :
    elif [ -f "$DIR_PADRAO/wallet/$WALLET_NOME" ]; then
        dir2="$DIR_PADRAO"
    fi
    if [ -n "$dir2" ] && [ -f "$dir2/wallet/$WALLET_NOME" ]; then
        info "Rotina de vacuum/analyze 2.x encontrada em ${BOLD}$dir2${NC}"
        if askyn "Atualizar esta instalação (a configuração é mantida)?" S; then
            MODO=atualizacao; DIR="$dir2"; return
        fi
        abort "Instalação cancelada. Para reinstalar do zero, use --uninstall antes."
    fi

    if [ -e "$CONF_1X_LINK" ]; then
        CONF_1X=$(readlink -f -- "$CONF_1X_LINK")
        info "Rotina 1.x encontrada: $CONF_1X_LINK -> $CONF_1X"
    else
        while true; do
            askyn "Existe uma instalação 1.x da rotina de vacuum/analyze neste servidor?" N || break
            while true; do
                ask resp "Caminho do arquivo de configuração da 1.x (ex.: /etc/zabbix/migrabkp/bin/migra_vacuum.conf)" || continue 2
                [ -f "$resp" ] && break
                warn "Arquivo não encontrado: $resp"
            done
            CONF_1X=$(readlink -f -- "$resp")
            break
        done
    fi

    if [ -n "$CONF_1X" ]; then
        [ -f "$CONF_1X" ] || abort "Configuração da 1.x não encontrada: $CONF_1X"
        _le_conf_1x "$CONF_1X"
        DIR=$(_dir_da_1x "$CONF_1X")
        _dir_seguro "$DIR" || abort "Diretório da 1.x inválido ou de sistema: '$DIR'"
        [ -d "$DIR" ] || abort "Diretório da 1.x não existe: $DIR"
        info "Diretório da rotina 1.x: ${BOLD}$DIR${NC} (versão ${V1[VERSION]:-?})"
        info "A $VERSAO_INSTALADOR será instalada neste mesmo diretório. Os logs atuais são mantidos."
        if [ "$(_dir_backup_2x)" = "$DIR" ]; then
            info "A rotina de backup 2.x também está neste diretório; os arquivos dela não são alterados."
        fi
        askyn "Migrar esta instalação para a $VERSAO_INSTALADOR?" S || abort "Instalação cancelada."
        MODO=migracao
        return
    fi

    MODO=nova
    _pergunta_dir_nova || detecta_modo
}

_pergunta_dir_nova() { # 2 = voltar
    local d sug bk
    bk=$(_dir_backup_2x 2>/dev/null) || bk=""
    sug="${DIR:-${bk:-$DIR_PADRAO}}"
    [ -n "$bk" ] && [ -z "$DIR" ] && info "Rotina de backup 2.x encontrada em $bk: a de vacuum/analyze pode ficar no mesmo diretório."
    while true; do
        ask d "Diretório da rotina" "$sug" || return 2
        d="${d%/}"
        if ! _dir_seguro "$d"; then
            warn "Diretório inválido ou de sistema. Use algo como $DIR_PADRAO."
        elif [ -e "$d/bin/vacuum_analyze" ] || [ -e "$d/wallet/$WALLET_NOME" ]; then
            warn "$d já contém a rotina de vacuum/analyze 2.x. Use --uninstall antes ou escolha outro diretório."
        else
            DIR="$d"; return 0
        fi
    done
}

# ------------------------------------------------------------------------------
# Pacote: download/validação/decifragem (nada é alterado no servidor aqui)
# ------------------------------------------------------------------------------
declare -A PLAIN=() SUMS=()
PKG_VERSAO="?"

# Primeiro passo do instalador: sem a chave do dia válida, encerra antes de qualquer pergunta.
obter_pacote() {
    local dist pkg code url name enc plain entrada
    until askpass dist "Chave do dia"; do :; done   # primeira pergunta: não há para onde voltar
    [ -n "$dist" ] || abort "Chave não informada. Instalação encerrada."

    WORK=$(mktemp -d) || abort "Falha ao criar diretório temporário"
    pkg="$WORK/$PACOTE_NOME.tar.gz"
    if [ -n "$PACOTE" ]; then
        cp -- "$PACOTE" "$pkg" || abort "Falha ao ler $PACOTE"
    else
        # API do GitHub (e não raw.githubusercontent): sem cache, sempre o pacote do dia
        url="https://api.github.com/repos/$GITHUB_ORG/$GITHUB_REPO/contents/$PACOTE_NOME.tar.gz?ref=$GITHUB_BRANCH"
        code=$(curl -sSL -H 'Accept: application/vnd.github.v3.raw' -o "$pkg" -w '%{http_code}' "$url" 2>/dev/null) || true
        case "$code" in
            200) ;;
            403|429) abort "O GitHub limitou os downloads deste IP (HTTP $code). Tente de novo em alguns minutos." ;;
            *) abort "Falha ao baixar o pacote (HTTP ${code:-sem resposta}). Verifique o acesso a api.github.com." ;;
        esac
    fi

    tar -tzf "$pkg" > "$WORK/lista" 2>/dev/null || abort "O pacote não é um tar.gz válido."
    while IFS= read -r entrada; do
        [[ "$entrada" =~ ^$PACOTE_NOME/([A-Za-z0-9._-]+/?)*$ ]] && [[ "$entrada" != *..* ]] \
            || abort "Pacote com entrada inesperada: $entrada"
    done < "$WORK/lista"
    mkdir -p "$WORK/pkg"
    tar -xzf "$pkg" -C "$WORK/pkg" --no-same-owner --no-same-permissions || abort "Falha ao extrair o pacote."
    [ -f "$WORK/pkg/$PACOTE_NOME/VERSION" ] && PKG_VERSAO=$(head -n1 "$WORK/pkg/$PACOTE_NOME/VERSION")

    for name in "${SCRIPTS[@]}"; do
        enc="$WORK/pkg/$PACOTE_NOME/bin/$name.enc"
        [ -f "$enc" ] || abort "Pacote incompleto: falta bin/$name.enc"
        _tmp plain
        if ! _mc_cipher d legacy 0 "$dist" "$enc" "$plain" \
           || [ "$(head -n1 "$plain")" != "#!/bin/bash" ] \
           || ! grep -qxF '# >>> MIGRA-CRYPT v2 >>>' "$plain"; then
            unset dist
            abort "Chave do dia inválida. Instalação encerrada."
        fi
        PLAIN["$name"]="$plain"
        SUMS["$name"]=$(openssl dgst -sha256 < "$plain" | awk '{print $NF}')
    done
    unset dist
    rm -f -- "$pkg"
    log "Chave válida. Rotina versão $PKG_VERSAO."
}

# ------------------------------------------------------------------------------
# PostgreSQL: cliente psql, conexão e versão
# ------------------------------------------------------------------------------
_versao_bin() { # <dir> -> número major (90600, 160000) ou vazio
    local out
    out=$("$1/psql" --version 2>/dev/null) || return 1
    [[ "$out" =~ \)\ ([0-9]+)(\.([0-9]+))? ]] || return 1
    local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[3]:-0}"
    if [ "$maj" -ge 10 ]; then echo $((maj * 10000)); else echo $((maj * 10000 + min * 100)); fi
}

_versao_txt() { local n="$1"; if [ "$n" -ge 100000 ]; then echo $((n / 10000)); else echo "$((n / 10000)).$(( (n / 100) % 100 ))"; fi; }

declare -A CAND=()
_candidatos_pg() {
    local d v
    local -a dirs=()
    command -v psql >/dev/null 2>&1 && dirs+=("$(dirname -- "$(readlink -f -- "$(command -v psql)")")")
    for d in /usr/pgsql-*/bin /usr/lib/postgresql/*/bin /usr/local/pgsql*/bin /opt/PostgreSQL/*/bin /usr/bin; do
        [ -d "$d" ] && dirs+=("$d")
    done
    CAND=()
    for d in "${dirs[@]}"; do
        [ -x "$d/psql" ] || continue
        v=$(_versao_bin "$d") || continue
        CAND["$d"]="$v"
    done
}

_pgpass_tmp() { # <variável> <usuario> <senha> : .pgpass temporário em RAM (limpo na saída)
    local __f __u __p
    _tmp __f
    __u=${2//\\/\\\\}; __u=${__u//:/\\:}
    __p=${3//\\/\\\\}; __p=${__p//:/\\:}
    printf '*:*:*:%s:%s\n' "$__u" "$__p" > "$__f"
    printf -v "$1" '%s' "$__f"
}

# psql com a credencial informada, sem expor a senha no ambiente/argumentos
_psql() {
    env -u PGPASSWORD PGPASSFILE="$PGPASSFILE_INST" "$PSQL_INST" -X -qAt -w \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

SERVER_NUM=""; PSQL_INST=""; PGPASSFILE_INST=""
_smaj() { if [ "$SERVER_NUM" -ge 100000 ]; then echo $(( SERVER_NUM / 10000 * 10000 )); else echo $(( SERVER_NUM / 100 * 100 )); fi; }

# Permissão do usuário: superuser, ou membro de pg_maintain (PostgreSQL 17+)
_confere_permissao() {
    local sup mnt=f
    sup=$(_psql -c "SELECT rolsuper FROM pg_roles WHERE rolname = current_user" 2>/dev/null)
    [ "$sup" = t ] && return 0
    if [ "${SERVER_NUM:-0}" -ge 170000 ]; then
        mnt=$(_psql -c "SELECT pg_has_role(current_user, 'pg_maintain', 'MEMBER')" 2>/dev/null)
        [ "$mnt" = t ] && { info "$PGUSER é membro de pg_maintain: pode fazer VACUUM/ANALYZE em todas as tabelas."; return 0; }
    fi
    warn "$PGUSER não é superuser. Sem isso o VACUUM/ANALYZE pula as tabelas de outros donos."
    if [ "${SERVER_NUM:-0}" -ge 170000 ]; then
        info "  Execute no banco: GRANT pg_maintain TO $PGUSER;   (ou ALTER USER $PGUSER WITH SUPERUSER;)"
    else
        info "  Execute no banco: ALTER USER $PGUSER WITH SUPERUSER;"
    fi
    return 1
}

configura_conexao() {
    header "Conexão com o PostgreSQL"
    _candidatos_pg
    if [ "${#CAND[@]}" -eq 0 ]; then
        err "Nenhum cliente PostgreSQL (psql) encontrado."
        case "$PM" in
            apt-get) info "Instale o cliente, ex.: apt-get install postgresql-client" ;;
            dnf|yum) info "Instale o cliente, ex.: $PM install postgresql" ;;
        esac
        abort "O instalador não instala pacotes do PostgreSQL. Instale o cliente e execute novamente."
    fi
    local d melhor="" mv=0
    for d in "${!CAND[@]}"; do
        if [ "${CAND[$d]}" -gt "$mv" ]; then mv="${CAND[$d]}"; melhor="$d"; fi
    done
    PSQL_INST="$melhor/psql"

    local out errf fase=1 do_fim=0
    _tmp errf
    dica_voltar
    [ -n "${SENHA_1X_INFO:-}" ] && info "$SENHA_1X_INFO"
    # Voltando da etapa seguinte: reabre direto na última pergunta (diretório do psql)
    [ "${CONEXAO_DO_FIM:-0}" = 1 ] && [ -n "$SERVER_NUM" ] && fase=2
    while true; do
        if [ "$fase" = 1 ]; then
            ASSIST_DO_FIM=$do_fim _assistente \
                "|PGHOST|Host do PostgreSQL|" \
                "|PGPORT|Porta|" \
                "|PGUSER|Usuário do vacuum/analyze (superuser)|" \
                "|PGDATABASE|Banco para conexão|" \
                "|PGPASSWORD|Senha do usuário do banco|secret" || return 2
            do_fim=0
            [ -n "$PGPASSFILE_INST" ] && rm -f -- "$PGPASSFILE_INST"
            _pgpass_tmp PGPASSFILE_INST "$PGUSER" "$PGPASSWORD"
            # stderr separado: avisos do psql não podem se misturar ao número da versão
            if out=$(_psql -c 'SHOW server_version_num' 2> "$errf") && [[ "$out" =~ ^[0-9]+$ ]]; then
                SERVER_NUM="$out"
                log "Conexão OK — servidor PostgreSQL $(_versao_txt "$(_smaj)") ($SERVER_NUM)"
            else
                err "Falha na conexão: $(head -n 1 "$errf")${out:+ $out}"
                if ! askyn "Corrigir os dados e tentar de novo?" S; then
                    [ "${CONEXAO_OPCIONAL:-0}" = 1 ] && return 1
                    abort "Instalação cancelada."
                fi
                PGPASSWORD=""
                continue
            fi
            fase=2
        fi

        local smaj escolhido="" ev=999999999
        smaj=$(_smaj)
        echo
        info "Clientes PostgreSQL encontrados:"
        for d in "${!CAND[@]}"; do
            printf "       ${DIM}%-34s${NC} psql %s\n" "$d" "$(_versao_txt "${CAND[$d]}")"
            if [ "${CAND[$d]}" -ge "$smaj" ] && [ "${CAND[$d]}" -lt "$ev" ]; then ev="${CAND[$d]}"; escolhido="$d"
            elif [ "${CAND[$d]}" -eq "$ev" ] && [ "$escolhido" = /usr/bin ]; then escolhido="$d"   # prefere o diretório da versão
            fi
        done
        [ -n "$escolhido" ] || escolhido="$melhor"   # VACUUM/ANALYZE funcionam com psql mais antigo
        if [ "${PG_BIN_ESCOLHIDO:-0}" != 1 ] || [ -z "${CAND[${PG_BIN%/}]:-}" ]; then
            PG_BIN="$escolhido"
        fi
        while true; do
            if ! askkey PG_BIN "Diretório do psql a usar"; then
                fase=1; do_fim=1; echo -e "  ${DIM}↑ voltando${NC}"; continue 2
            fi
            PG_BIN="${PG_BIN%/}"
            if [ -n "${CAND[$PG_BIN]:-}" ]; then
                [ "${CAND[$PG_BIN]}" -ge "$smaj" ] \
                    || warn "psql $(_versao_txt "${CAND[$PG_BIN]}") é mais antigo que o servidor; funciona, mas prefira o da mesma versão."
                PG_BIN_ESCOLHIDO=1; break 2
            fi
            warn "Escolha um diretório da lista acima."
        done
    done
    PSQL_INST="$PG_BIN/psql"
    _confere_permissao || askyn "Continuar mesmo assim (dá para ajustar depois e conferir com migra-wallet-vacuum -test)?" S \
        || abort "Instalação cancelada."
}

# ------------------------------------------------------------------------------
# Configuração da rotina
# ------------------------------------------------------------------------------
importa_1x() { # mapeia o conf 1.x para as chaves da 2.0
    local v
    [ -n "${V1[PG_HOST]:-}" ] && PGHOST="${V1[PG_HOST]}"
    [ -n "${V1[PG_PORT]:-}" ] && PGPORT="${V1[PG_PORT]}"
    # Usuário padrão é o migrabkp (o mesmo da rotina de backup). O da 1.x (ex.: titan) e a senha
    # lida do script ficam guardados: a senha só é oferecida se o técnico mantiver aquele usuário.
    SENHA_1X_USER="${SCRIPT1X_USER:-}"; SENHA_1X_VAL=""
    if [ -n "${SCRIPT1X_USER:-}" ] && [ "$SCRIPT1X_USER" != "$PGUSER" ]; then
        SENHA_1X_INFO="Na 1.x o usuário era $SCRIPT1X_USER. O padrão agora é $PGUSER, o mesmo da rotina de backup; para manter o $SCRIPT1X_USER, digite o nome dele."
    fi
    if [ -n "${SCRIPT1X_SENHA:-}" ]; then
        SENHA_1X_VAL="$SCRIPT1X_SENHA"
        [ "$SCRIPT1X_USER" = "$PGUSER" ] && PGPASSWORD="$SCRIPT1X_SENHA"
        SENHA_1X_INFO="${SENHA_1X_INFO:+$SENHA_1X_INFO }Com o usuário $SCRIPT1X_USER, Enter na pergunta da senha mantém a senha lida do script da 1.x."
    fi
    unset SCRIPT1X_SENHA
    [ -n "${V1[ARQ_LOG_GERAL]:-}" ] && LOG_GERAL="${V1[ARQ_LOG_GERAL]}"
    for v in RETENCAO_LOG_DB PARALLEL_JOBS TITAN PATH_TITAN SENDER T_CONF T_IP; do
        [ -n "${V1[$v]+x}" ] && printf -v "$v" '%s' "${V1[$v]}"
    done
    [ -n "${V1[T_Host]:-}" ] && T_HOST="${V1[T_Host]}"
    PATH_TITAN="${PATH_TITAN%/}"; PATH_TITAN="${PATH_TITAN:-/usr/bin}"
    _preenche_padroes
}

_preenche_padroes() {
    local l k t d v
    for l in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d _ <<< "$l"
        v="${!k}"
        case "$t" in
            int)       [[ "$v" =~ ^[0-9]+$ ]] && continue ;;
            lvl)       [[ "$v" =~ ^[0-9]$ ]] && continue ;;
            yn)        v="${v^^}"; if [[ "$v" =~ ^[SN]$ ]]; then printf -v "$k" '%s' "$v"; continue; fi ;;
            req)       [ -n "$v" ] && continue ;;
            apath)     [[ "$v" == /* ]] && continue ;;
            *)         continue ;;
        esac
        [ -n "$v" ] && warn "Valor da 1.x fora do formato em $k ('$v'); usando o padrão: $d"
        printf -v "$k" '%s' "$d"
    done
}

# Confere a configuração ANTES do resumo/aplicação (a mesma validação de quando a wallet é gravada).
_config_valida() {
    local out
    if out=$( { _mc_parse "$(_mc_render)" && _mc_validate; } 2>&1 ); then return 0; fi
    err "A configuração tem valores inválidos:"
    sed 's/^/       /' <<< "$out"
    return 1
}

SERVER_BASES=""; SERVER_MODELOS=""
_bases_servidor() { # SERVER_BASES: as que podem ser processadas; SERVER_MODELOS: template0/1 e afins
    [ -n "$SERVER_BASES$SERVER_MODELOS" ] && return 0
    SERVER_BASES=$(_psql -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1" 2>/dev/null)
    SERVER_MODELOS=$(_psql -c "SELECT datname FROM pg_database WHERE NOT datallowconn OR datistemplate ORDER BY 1" 2>/dev/null)
}

_em_lista() { # <nome> <lista separada por vírgula>
    local x
    IFS=',' read -ra _l <<< "$2"
    for x in "${_l[@]}"; do x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; [ "$x" = "$1" ] && return 0; done
    return 1
}

# Agendamento: 5 campos do cron ou N (não agendar)
_pergunta_cron() { # <CHAVE> <pergunta> ; 2 = voltar
    local k="$1" v
    local -a c
    while true; do
        ask v "$2" "${!k}" || return 2
        read -ra c <<< "$v"; v="${c[*]}"     # normaliza os espaços sem expandir o *
        if [ "${v^^}" = N ]; then
            printf -v "$k" '%s' N; echo -e "      ${DIM}↳ sem agendamento${NC}"; return 0
        fi
        if _cron_campos_ok "$v"; then
            printf -v "$k" '%s' "$v"; echo -e "      ${DIM}↳${NC} $(_cron_humano "$v")"; return 0
        fi
        warn "Responda N (sem agendamento) ou os 5 campos do cron (ex.: 00 03 * * 0-5). Enter mantém o padrão."
    done
}

# ------------------------------------------------------------------------------
# Agendamento em português: "00 01 * * 6" -> "Todos os sábados, às 01h"
# O que não der para traduzir aparece como o próprio cron.
# ------------------------------------------------------------------------------
_DIAS=(domingo segunda terça quarta quinta sexta sábado domingo)
_DIAS_PL=(domingos segundas terças quartas quintas sextas sábados domingos)
_MESES=("" janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)
_lista_e() { # a b c -> "a, b e c"
    local n=$# s="" i=0 x
    for x in "$@"; do
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then s="$x"; elif [ "$i" -eq "$n" ]; then s="$s e $x"; else s="$s, $x"; fi
    done
    echo "$s"
}
_cron_hora() { # <minuto> <hora> -> "às 03h" | "às 03h30 e 15h30"
    local m="$1" h="$2" x
    local -a hs=() p=()
    [[ "$m" =~ ^[0-9]{1,2}$ ]] && [[ "$h" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || return 1
    m=$((10#$m)); [ "$m" -le 59 ] || return 1
    IFS=',' read -ra hs <<< "$h"
    for x in "${hs[@]}"; do
        x=$((10#$x)); [ "$x" -le 23 ] || return 1
        if [ "$m" -eq 0 ]; then p+=("$(printf '%02dh' "$x")"); else p+=("$(printf '%02dh%02d' "$x" "$m")"); fi
    done
    echo "às $(_lista_e "${p[@]}")"
}
_cron_semana() { # <dia-da-semana> -> "todos os dias" | "de domingo a sexta" | "todos os sábados" ...
    local d="$1" a b x i
    local -a xs=() ns=()
    [ "$d" = '*' ] && { echo "todos os dias"; return 0; }
    if [[ "$d" =~ ^[0-7](,[0-7])+$ ]]; then          # lista contínua (0,1,2,3,4,5) vira faixa
        IFS=',' read -ra xs <<< "$d"
        for ((i = 1; i < ${#xs[@]}; i++)); do [ "${xs[$i]}" -eq $((xs[i - 1] + 1)) ] || break; done
        [ "$i" -eq "${#xs[@]}" ] && [ "${#xs[@]}" -ge 3 ] && d="${xs[0]}-${xs[$((i - 1))]}"
    fi
    if [[ "$d" =~ ^([0-7])-([0-7])$ ]]; then
        a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        [ "$a" -lt "$b" ] || return 1
        if [ "$a" -eq 0 ] && [ "$b" -ge 6 ]; then echo "todos os dias"
        elif [ "$a" -eq 1 ] && [ "$b" -eq 7 ]; then echo "todos os dias"
        else echo "de ${_DIAS[$a]} a ${_DIAS[$b]}"; fi
        return 0
    fi
    [[ "$d" =~ ^[0-7](,[0-7])*$ ]] || return 1
    IFS=',' read -ra xs <<< "$d"
    if [ "${#xs[@]}" -eq 1 ]; then
        case "$d" in 0|6|7) echo "todos os ${_DIAS_PL[$d]}" ;; *) echo "todas as ${_DIAS_PL[$d]}" ;; esac
        return 0
    fi
    for x in "${xs[@]}"; do ns+=("${_DIAS_PL[$x]}"); done
    _lista_e "${ns[@]}"
}
_cron_humano() { # <5 campos do cron>
    local -a c=() ds=()
    local h dia x
    read -ra c <<< "$1"
    if [ "${#c[@]}" -ne 5 ] || ! h=$(_cron_hora "${c[0]}" "${c[1]}"); then echo "conforme o cron $1"; return; fi
    if [ "${c[2]}" = '*' ] && [ "${c[3]}" = '*' ]; then
        dia=$(_cron_semana "${c[4]}") || { echo "conforme o cron $1"; return; }
    elif [[ "${c[2]}" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] && [ "${c[4]}" = '*' ]; then
        IFS=',' read -ra ds <<< "${c[2]}"
        for x in "${!ds[@]}"; do ds[$x]=$((10#${ds[$x]})); [ "${ds[$x]}" -ge 1 ] && [ "${ds[$x]}" -le 31 ] || { echo "conforme o cron $1"; return; }; done
        if [ "${#ds[@]}" -eq 1 ]; then dia="todo dia ${ds[0]}"; else dia="nos dias $(_lista_e "${ds[@]}")"; fi
        if [ "${c[3]}" = '*' ]; then dia="$dia do mês"
        elif [[ "${c[3]}" =~ ^[0-9]{1,2}$ ]] && [ "$((10#${c[3]}))" -ge 1 ] && [ "$((10#${c[3]}))" -le 12 ]; then
            dia="$dia de ${_MESES[$((10#${c[3]}))]}"
        else echo "conforme o cron $1"; return; fi
    else
        echo "conforme o cron $1"; return
    fi
    echo "${dia^}, $h"
}

_OP_NOMES=(analyze:ANALYZE vacuum:VACUUM all:"VACUUM + ANALYZE (all)" freeze:"VACUUM FREEZE")
_op_nome() { local x; for x in "${_OP_NOMES[@]}"; do [ "${x%%:*}" = "$1" ] && { echo "${x#*:}"; return; }; done; echo "$1"; }

# Quadro do agendamento em português. Entradas: "campos|operação" (padrão: CRON_NOVAS)
_cron_quadro() { # [titulo] [entradas...]
    local titulo="${1:-Como fica o agendamento}"; shift || true
    local -a e=("$@")
    [ "${#e[@]}" -gt 0 ] || e=("${CRON_NOVAS[@]}")
    local op l achou tem_all=0 tem_av=0 nome
    echo
    echo -e "   ${BOLD}${titulo}${NC}"
    for op in analyze vacuum all freeze; do
        achou=0; nome=$(_op_nome "$op")
        for l in "${e[@]}"; do
            [ -n "$l" ] && [ "${l#*|}" = "$op" ] || continue
            printf "     ${GREEN}✔${NC}  ${BOLD}%-24s${NC}%s  ${DIM}(%s)${NC}\n" "$nome" "$(_cron_humano "${l%%|*}")" "${l%%|*}"
            achou=1
        done
        if [ "$achou" = 1 ]; then
            [ "$op" = all ] && tem_all=1
            { [ "$op" = analyze ] || [ "$op" = vacuum ]; } && tem_av=1
        else
            printf "     ${DIM}–  %-24ssem agendamento${NC}\n" "$nome"
        fi
    done
    if [ "$tem_all" = 1 ] && [ "$tem_av" = 1 ]; then
        warn "O all já faz VACUUM e ANALYZE: agendado junto com eles, repete o trabalho."
    fi
    echo
}

# Linhas da rotina no crontab -> "campos|operação"
_cron_entradas() { # <linhas>
    local a b c d e cmd op
    while read -r a b c d e cmd op _; do
        [ -n "$cmd" ] || continue
        [[ " $OPERACOES " == *" $op "* ]] || op=analyze
        printf '%s|%s\n' "$a $b $c $d $e" "$op"
    done <<< "$1"
}

# Textos mostrados antes das perguntas (repetidos ao voltar para elas)
_vcpus() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0; }
_jobs_recomendado() { # metade das vCPUs, de 1 a 32
    local n; n=$(_vcpus); [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n / 2)); [ "$n" -lt 1 ] && n=1; [ "$n" -gt 32 ] && n=32
    echo "$n"
}
_explica_jobs() {
    local n r
    n=$(_vcpus); r=$(_jobs_recomendado)
    echo
    info "Paralelismo: quantas tabelas são processadas ao mesmo tempo."
    echo -e "       ${DIM}Cada job é uma conexão e um processo do PostgreSQL trabalhando. Mais jobs terminam antes,${NC}"
    echo -e "       ${DIM}mas consomem mais vCPU e disco do servidor do banco enquanto a rotina roda.${NC}"
    if [ "$n" -gt 0 ] 2>/dev/null; then
        echo -e "       ${DIM}Esta máquina tem $n vCPU(s): o recomendado é a metade, ${NC}${BOLD}$r${NC}${DIM}, e menos se a rotina rodar em horário de uso.${NC}"
    else
        echo -e "       ${DIM}Use no máximo a metade das vCPUs, e menos se a rotina rodar em horário de uso.${NC}"
    fi
}
_explica_lock() {
    echo
    info "Tabela travada: se outra sessão segura a tabela (ALTER, carga, backup), a rotina espera até este"
    echo -e "       ${DIM}tempo, pula a tabela com aviso e segue para a próxima.${NC}"
}
_explica_cron() {
    echo
    info "Agendamento no crontab do root: uma pergunta por operação, uma linha no crontab para cada."
    echo -e "       ${BOLD}Respostas possíveis em cada pergunta${NC}"
    echo -e "       ${CYAN}Enter${NC}         ${DIM}mantém o valor entre colchetes${NC}"
    echo -e "       ${CYAN}N${NC}             ${DIM}deixa a operação sem agendamento${NC}"
    echo -e "       ${CYAN}5 campos${NC}      ${DIM}horário no formato do cron: minuto hora dia-do-mês mês dia-da-semana${NC}"
    echo -e "                     ${DIM}(dia-da-semana: 0 = domingo ... 6 = sábado; * = todos)${NC}"
    echo -e "       ${BOLD}Exemplos${NC}"
    echo -e "       ${CYAN}00 03 * * *${NC}       ${DIM}todos os dias, às 03h${NC}"
    echo -e "       ${CYAN}00 03 * * 0-5${NC}     ${DIM}de domingo a sexta, às 03h${NC}"
    echo -e "       ${CYAN}00 01 * * 6${NC}       ${DIM}todos os sábados, às 01h${NC}"
    echo -e "       ${CYAN}30 22 * * 1,3,5${NC}   ${DIM}segundas, quartas e sextas, às 22h30${NC}"
    echo -e "       ${CYAN}00 02 1 * *${NC}       ${DIM}todo dia 1 do mês, às 02h${NC}"
    echo -e "       ${BOLD}Operações${NC}"
    echo -e "       ${DIM}ANALYZE  atualiza as estatísticas do otimizador; rápido, diário.${NC}"
    echo -e "       ${DIM}VACUUM   libera o espaço das linhas mortas e congela as antigas (evita o wraparound); semanal.${NC}"
    echo -e "       ${DIM}all      VACUUM e ANALYZE numa passada só; use no lugar dos dois, não junto.${NC}"
    echo -e "       ${DIM}FREEZE   congela todas as linhas de uma vez, com muito I/O. Normalmente não precisa: o VACUUM${NC}"
    echo -e "       ${DIM}         e o autovacuum já evitam o wraparound.${NC}"
    echo -e "       ${DIM}Duas operações no mesmo horário não rodam juntas: a segunda é recusada (já em execução).${NC}"
    echo -e "       ${DIM}Os outros agendamentos do crontab não são alterados.${NC}"
}

# Mostra as bases do servidor, pergunta as ignoradas e lista o resultado na vertical.
_pergunta_exclusoes() {
    local b x n_ok=0
    _bases_servidor
    if [ -n "$SERVER_BASES" ]; then
        echo
        echo -e "   ${BOLD}Bases no servidor${NC}"
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            if _em_lista "$b" "$EXCLUDE_BASES"; then echo -e "     ${DIM}✖  $b   (ignorada)${NC}"
            else echo -e "     ${GREEN}✔${NC}  $b"; fi
        done <<< "$SERVER_BASES"
        while IFS= read -r b; do
            [ -n "$b" ] && echo -e "     ${DIM}✖  $b   (modelo do PostgreSQL: nunca é processada)${NC}"
        done <<< "$SERVER_MODELOS"
        echo
    fi
    askkey EXCLUDE_BASES "Bases a ignorar (separadas por vírgula)" || return 2

    echo
    echo -e "   ${BOLD}Ficam fora do vacuum/analyze${NC}"
    IFS=',' read -ra _l <<< "$EXCLUDE_BASES"
    for x in "${_l[@]}"; do
        x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
        [ -n "$x" ] || continue
        if grep -qxF -- "$x" <<< "$SERVER_MODELOS"; then
            echo -e "     ${DIM}✖  $x   (modelo do PostgreSQL)${NC}"
        elif [ -n "$SERVER_BASES" ] && ! grep -qxF -- "$x" <<< "$SERVER_BASES"; then
            echo -e "     ${DIM}✖  $x   (não existe neste servidor)${NC}"
        else
            echo -e "     ${YELLOW}✖${NC}  $x"
        fi
    done
    if [ -n "$SERVER_BASES" ]; then
        echo -e "   ${BOLD}Processadas${NC}"
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            _em_lista "$b" "$EXCLUDE_BASES" && continue
            echo -e "     ${GREEN}✔${NC}  $b"; n_ok=$((n_ok + 1))
        done <<< "$SERVER_BASES"
        [ "$n_ok" -gt 0 ] || warn "Nenhuma base é processada com esta lista."
    fi
    echo -e "   ${BOLD}Tabelas e schemas ignorados${NC} ${DIM}(ficam na wallet; altere com migra-wallet-vacuum -excludeTable add/del)${NC}"
    if [ -n "$EXCLUDE_TABLE" ]; then
        while IFS= read -r x; do echo -e "     ${YELLOW}✖${NC}  $x"; done < <(_exclusoes_tabelas)
    else
        echo -e "     ${DIM}nenhum${NC}"
    fi
    echo
    return 0
}

coleta_config() {
    header "Configuração do vacuum/analyze"
    if [ "$MODO" = migracao ] && [ -z "${REVISAO:-}" ] && ! askyn "Revisar as configurações importadas da 1.x?" S; then
        return 0
    fi
    dica_voltar
    [ -n "$T_HOST" ] || T_HOST=$(hostname -s 2>/dev/null)
    local -a cron=("${CRON_ETAPAS[@]}")   # o agendamento que já existe (1.x) vem entre colchetes
    _assistente \
        "|PARALLEL_JOBS|Jobs paralelos: tabelas processadas ao mesmo tempo (1 a 32)|jobs" \
        "|LOCK_TIMEOUT|Segundos esperando o lock de cada tabela antes de pular (0 = sem limite)|lock" \
        "|EXCLUDE_BASES||exclude" \
        "|RETENCAO_LOG_DB|Retenção dos logs por base (dias)|" \
        "|TITAN|Enviar status ao Zabbix/Titan? (S/N)|" \
        "TITAN=S|PATH_TITAN|Diretório do zabbix_sender|" \
        "TITAN=S|SENDER|Executável do sender|" \
        "TITAN=S|T_CONF|Configuração do agente Zabbix|" \
        "TITAN=S|T_IP|Servidor Zabbix/Titan (IP ou nome)|" \
        "TITAN=S|T_HOST|Hostname no Zabbix|" \
        "${cron[@]}" || return 2
    _cron_define
    _cron_quadro
    return 0
}

dependencias() {
    header "Dependências"
    if [ "$TITAN" = S ] && [ ! -x "${PATH_TITAN%/}/$SENDER" ] && ! command -v "$SENDER" >/dev/null 2>&1; then
        warn "$SENDER não encontrado em $PATH_TITAN; o status não chegará ao monitoramento."
    fi
    log "Dependências verificadas."
}

# ------------------------------------------------------------------------------
# Migração 1.x: localizar, guardar (sem senha) e limpar
# ------------------------------------------------------------------------------
SCRIPT1X=(); SCRIPT1X_USER=""; SCRIPT1X_SENHA=""; SCRIPT1X_PLAIN=""; CRON1X=()

# Scripts da 1.x no cron: vacuum_analyze.sh, vacuum_analyze.sh.x (shc) e variações do cliente.
# O loader da 2.x (bin/vacuum_analyze, sem .sh) não entra.
_RE_1X='vacuum_analyze[A-Za-z0-9_-]*\.sh(\.x)?'
_e_1x() { grep -E -- "$_RE_1X"; }

# Senha literal do script 1.x (PG_PASSWORD= ou PGPASSWORD=), sem expandir variáveis
_senha_do_script() { # <script em texto>
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?PG_?PASSWORD=("([^"$]*)"|'"'"'([^'"'"']*)'"'"'|([^"'"'"'$[:space:]][^[:space:]]*))[[:space:]]*(#.*)?$/\3\4\5/p' "$1" | head -n1
}

localiza_1x() {
    local c f linha u
    CRON1X=()
    for u in root postgres; do
        while IFS= read -r linha; do
            [[ "$linha" =~ ^[[:space:]]*# ]] && continue
            CRON1X+=("crontab:$u|$linha")
        done < <(crontab -l -u "$u" 2>/dev/null | _e_1x)
    done
    for f in /etc/crontab /etc/cron.d/*; do
        [ -f "$f" ] || continue
        while IFS= read -r linha; do
            [[ "$linha" =~ ^[[:space:]]*# ]] && continue
            CRON1X+=("arquivo:$f|$linha")
        done < <(_e_1x < "$f" 2>/dev/null)
    done
    for linha in "${CRON1X[@]}"; do   # primeiro os scripts que o cron realmente chama
        c=$(grep -oE "/[^[:space:]]*$_RE_1X" <<< "${linha#*|}" | head -n1)
        if [ -n "$c" ] && [ -f "$c" ] && [[ ! " ${SCRIPT1X[*]} " == *" $c "* ]]; then SCRIPT1X+=("$c"); fi
    done
    for c in "$DIR/bin/vacuum_analyze.sh" "$DIR/bin/vacuum_analyze.sh.x" "$DIR/vacuum_analyze.sh"; do
        if [ -f "$c" ] && [[ ! " ${SCRIPT1X[*]} " == *" $c "* ]]; then SCRIPT1X+=("$c"); fi
    done

    # Usuário e senha do banco ficam fixos no script da 1.x (texto; o .sh.x do shc é binário)
    for c in "${SCRIPT1X[@]}"; do
        grep -qI . -- "$c" 2>/dev/null || continue
        _tmp SCRIPT1X_PLAIN
        cp -- "$c" "$SCRIPT1X_PLAIN" || { SCRIPT1X_PLAIN=""; continue; }
        SCRIPT1X_USER=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?PG_?USER="?([^"$[:space:]]*)"?[[:space:]]*$/\2/p' "$SCRIPT1X_PLAIN" | head -n1)
        SCRIPT1X_SENHA=$(_senha_do_script "$SCRIPT1X_PLAIN")
        break
    done
    if [ "${#SCRIPT1X[@]}" -gt 0 ] && [ -z "$SCRIPT1X_PLAIN" ]; then
        warn "O script da 1.x está compilado (shc): usuário e senha do banco serão perguntados."
    fi
    info "Scripts 1.x: ${SCRIPT1X[*]:-nenhum encontrado}"
    info "Agendamentos 1.x: ${#CRON1X[@]}"
}

_salva_sem_senha() { # <script em texto> <destino> : troca a senha por um marcador
    local conteudo senha
    senha=$(_senha_do_script "$1")
    conteudo=$(sed -E 's/(PG_?PASSWORD=)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)/\1"__REMOVIDO_NA_MIGRACAO__"/g' "$1")
    # Outras ocorrências da senha no texto (cópia só para consulta: substituir a mais não faz mal)
    if [ "${#senha}" -ge 4 ]; then conteudo="${conteudo//"$senha"/__REMOVIDO_NA_MIGRACAO__}"; fi
    unset senha
    printf '%s\n' "$conteudo" > "$2"
}

# psql no banco postgres: a 1.x guardava as exclusões lá (maintenance.vacuum_exclude)
_psql_1x() { PGDATABASE=postgres _psql "$@"; }
_tem_exclude_1x() { [ "$(_psql_1x -c "SELECT to_regclass('maintenance.vacuum_exclude') IS NOT NULL" 2>/dev/null)" = t ]; }

backup_1x() {
    header "Backup da instalação 1.x"
    BK1X=$(_bk_dir)

    sed -E 's/(PG_?PASSWORD=)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)/\1"__REMOVIDO_NA_MIGRACAO__"/g' \
        "$CONF_1X" > "$BK1X/migra_vacuum.conf"
    if [ -n "$SCRIPT1X_PLAIN" ]; then
        _salva_sem_senha "$SCRIPT1X_PLAIN" "$BK1X/vacuum_analyze.sh.sem_senha" && log "Script 1.x salvo sem a senha."
    fi
    {
        echo "# Agendamentos da 1.x encontrados em $(date '+%d/%m/%Y %T')"
        local l
        for l in "${CRON1X[@]}"; do echo "${l%%|*}: ${l#*|}"; done
    } > "$BK1X/cron.txt"
    {
        echo "# Links e arquivos da 1.x"
        ls -l "$CONF_1X_LINK" 2>/dev/null
        echo "conf resolvido: $CONF_1X"
        echo "scripts: ${SCRIPT1X[*]}"
    } > "$BK1X/arquivos.txt"
    if _tem_exclude_1x; then
        _psql_1x -c "COPY (SELECT * FROM maintenance.vacuum_exclude ORDER BY 1) TO STDOUT WITH CSV HEADER" \
            > "$BK1X/vacuum_exclude.csv" 2>/dev/null && log "Tabela maintenance.vacuum_exclude salva (CSV)."
    fi
    {
        echo "# Inventário em $(date '+%d/%m/%Y %T')"
        for l in "$DIR" "$DIR/bin" "$DIR/tmp"; do
            [ -d "$l" ] || continue
            echo; echo "## $l"; ls -la -- "$l" 2>/dev/null | head -n 200
        done
    } > "$BK1X/inventario.txt"

    _bk_nota "migra_vacuum.conf" "configuração da 1.x ($CONF_1X)"
    _bk_nota "vacuum_analyze.sh.sem_senha" "script da 1.x com a senha do banco removida (se era texto)"
    _bk_nota "cron.txt" "linhas de agendamento da 1.x encontradas"
    _bk_nota "arquivos.txt" "link $CONF_1X_LINK e scripts"
    _bk_nota "vacuum_exclude.csv" "exclusões (tabela maintenance.vacuum_exclude do banco postgres)"
    _bk_nota "inventario.txt" "listagem dos diretórios da rotina"
    cat >> "$BK1X/README.txt" <<EOF

Os logs em $DIR/log e ${V1[ARQ_LOG_GERAL]:-o log geral} NÃO foram movidos nem apagados.
A senha do banco NÃO está neste backup: ela agora fica só na wallet da 2.x.
As exclusões ativas foram importadas para a wallet (EXCLUDE_BASES e EXCLUDE_TABLE).
EOF
    chmod -R go-rwx -- "$BK1X"
    log "Backup da 1.x em ${BOLD}$BK1X${NC}"
}

# Lista das tabelas/schemas ignorados (EXCLUDE_TABLE), uma por linha, para as telas do instalador
_exclusoes_tabelas() {
    local b s t m u dt alvo
    while IFS='|' read -r b s t m u dt; do
        [ -n "$b" ] || continue
        if [ "$t" = '*' ]; then alvo="schema $s inteiro"; else alvo="$s.$t"; fi
        [ "$b" = '*' ] && b="todas as bases"
        printf '%s  %s%s\n' "$b" "$alvo" "${m:+   ($m)}"
    done <<< "$EXCLUDE_TABLE"
}
mostra_exclusoes() { # bases e tabelas ignoradas que ficam na wallet
    local x
    echo
    echo -e "   ${BOLD}Exclusões na wallet${NC} ${DIM}(mantidas; altere com migra-wallet-vacuum -excludeTable)${NC}"
    echo -e "     ${DIM}Bases ignoradas:${NC} ${EXCLUDE_BASES:-nenhuma}"
    if [ -n "$EXCLUDE_TABLE" ]; then
        echo -e "     ${DIM}Tabelas e schemas ignorados:${NC}"
        while IFS= read -r x; do echo -e "       ${YELLOW}✖${NC}  $x"; done < <(_exclusoes_tabelas)
    else
        echo -e "     ${DIM}Tabelas e schemas ignorados: nenhum${NC}"
    fi
}

# CSV da maintenance.vacuum_exclude (COPY ... CSV HEADER: id,database_name,schema_name,table_name,
# exclude_type,active,created_at) -> "B|base" e "T|base|schema|tabela|motivo|usuário|data", só ativas.
# Linhas com aspas (vírgula ou | no nome) são ignoradas.
_exclusoes_do_csv() { # <csv>
    awk -F',' 'NR == 1 || /"/ { next }
        $6 != "t" { next }
        $5 == "database" && $2 != "" && $2 != "postgres" { print "B|" $2; next }
        ($5 == "schema" || $5 == "table") && $3 != "" && ($5 == "schema" || $4 != "") && index($0, "|") == 0 {
            print "T|" ($2 == "" ? "*" : $2) "|" $3 "|" ($5 == "schema" ? "*" : $4) "|importado da 1.x (id " $1 ")|migracao|" substr($7, 9, 2) "/" substr($7, 6, 2) "/" substr($7, 1, 4)
        }' "$1"
}

# Atualização: a 2.0 a 2.3 podiam deixar a wallet sem as exclusões da 1.x (tabela vazia na hora
# da migração, ou importação que falhou). Se o backup da 1.x tem exclusões ativas que faltam na
# wallet, oferece incluir.
importa_exclusoes_backup_1x() {
    local csv l b s t novas_b="" novas_t="" n=0
    for csv in "$DIR"/bkp_vacuum_*/vacuum_exclude.csv; do
        [ -f "$csv" ] || continue
        while IFS= read -r l; do
            case "$l" in
                B\|*) b="${l#B|}"
                      _em_lista "$b" "$EXCLUDE_BASES" || _em_lista "$b" "$novas_b" || { novas_b="${novas_b:+$novas_b,}$b"; n=$((n + 1)); } ;;
                T\|*) l="${l#T|}"
                      IFS='|' read -r b s t _ <<< "$l"
                      _mc_et_has "$(sed 's/^/EXCLUDE_TABLE=/' <<< "$EXCLUDE_TABLE")" "$b" "$s" "$t" && continue
                      _mc_et_has "$(sed 's/^/EXCLUDE_TABLE=/' <<< "$novas_t")" "$b" "$s" "$t" && continue
                      novas_t="${novas_t:+$novas_t$'\n'}$l"; n=$((n + 1)) ;;
            esac
        done < <(_exclusoes_do_csv "$csv")
    done
    [ "$n" -gt 0 ] || return 0
    echo
    warn "O backup da 1.x tem exclusões ativas que não estão na wallet:"
    [ -n "$novas_b" ] && echo "       bases: $novas_b"
    [ -n "$novas_t" ] && while IFS='|' read -r b s t _; do echo "       $b  $s.$t"; done <<< "$novas_t"
    askyn "Incluir na wallet?" S || return 0
    if [ -n "$novas_b" ]; then
        EXCLUDE_BASES="${EXCLUDE_BASES:+$EXCLUDE_BASES,}$novas_b"
        UPDATED_TXT=$(_mc_txt_set "$UPDATED_TXT" EXCLUDE_BASES "$EXCLUDE_BASES")
    fi
    if [ -n "$novas_t" ]; then
        EXCLUDE_TABLE="${EXCLUDE_TABLE:+$EXCLUDE_TABLE$'\n'}$novas_t"
        UPDATED_TXT="${UPDATED_TXT}"$'\n'"$(sed 's/^/EXCLUDE_TABLE=/' <<< "$novas_t")"
    fi
    log "$n exclusão(ões) da 1.x incluída(s) na wallet."
}

importa_exclusoes_1x() {
    local lista n sem total
    if ! _tem_exclude_1x; then
        info "Exclusões da 1.x: tabela maintenance.vacuum_exclude não encontrada (nada a importar)."
        return 0
    fi
    total=$(_psql_1x -c "SELECT count(*) || ' linha(s), ' || count(*) FILTER (WHERE active) || ' ativa(s)' FROM maintenance.vacuum_exclude" 2>/dev/null)
    info "Exclusões da 1.x (maintenance.vacuum_exclude): ${total:-não foi possível ler}"
    # Bases: a 1.x ignorava a postgres fixo no script; aqui ela entra na lista.
    lista=$(_psql_1x -c "SELECT string_agg(DISTINCT database_name, ',' ORDER BY database_name)
                FROM maintenance.vacuum_exclude
                WHERE active AND exclude_type = 'database' AND database_name IS NOT NULL
                  AND database_name <> 'postgres' AND strpos(database_name, ',') = 0" 2>/dev/null)
    EXCLUDE_BASES="postgres${lista:+,$lista}"
    [ -n "$lista" ] && info "Bases ignoradas importadas da 1.x: $lista"
    # Schemas e tabelas -> EXCLUDE_TABLE (base|schema|tabela ou *|motivo|usuário|data); base vazia = todas (*)
    lista=$(_psql_1x -F '|' -c "SELECT coalesce(database_name, '*'), schema_name,
                    CASE WHEN exclude_type = 'schema' THEN '*' ELSE table_name END,
                    'importado da 1.x (id ' || id || ')', 'migracao', coalesce(to_char(created_at, 'DD/MM/YYYY'), '')
                FROM maintenance.vacuum_exclude
                WHERE active AND exclude_type IN ('schema', 'table')
                  AND schema_name IS NOT NULL AND (exclude_type = 'schema' OR table_name IS NOT NULL)
                  AND strpos(coalesce(database_name, '') || schema_name || coalesce(table_name, ''), '|') = 0
                ORDER BY 1, 2, 3" 2>/dev/null)
    if [ -n "$lista" ]; then
        EXCLUDE_TABLE="$lista"
        info "Tabelas/schemas ignorados importados da 1.x: $(grep -c . <<< "$lista")"
    fi
    sem=$(_psql_1x -c "SELECT count(*) FROM maintenance.vacuum_exclude
                WHERE active AND exclude_type = 'table' AND (schema_name IS NULL OR table_name IS NULL)" 2>/dev/null)
    [ "${sem:-0}" -gt 0 ] 2>/dev/null && warn "$sem exclusão(ões) de tabela sem schema não foram importadas (na 1.x elas não tinham efeito)."
    n=$(_psql_1x -c "SELECT count(*) FROM maintenance.vacuum_exclude WHERE NOT active" 2>/dev/null)
    [ "${n:-0}" -gt 0 ] 2>/dev/null && info "$n exclusão(ões) inativa(s) na 1.x não foram importadas (ficam no CSV do backup)."
    return 0
}

limpa_1x() {
    header "Limpeza da 1.x"
    local f l origem linha u arq rem=()
    for f in "${SCRIPT1X[@]}" "$CONF_1X"; do [ -f "$f" ] && rem+=("$f"); done
    [ -L "$CONF_1X_LINK" ] && rem+=("$CONF_1X_LINK")
    if [ "${#rem[@]}" -gt 0 ]; then
        info "Arquivos da 1.x (o script contém a senha do banco):"
        for f in "${rem[@]}"; do echo "          $f"; done
        local padrao=S
        [ "$CHECK_OK" = 1 ] || { warn "A verificação da $VERSAO_INSTALADOR falhou; mantenha a 1.x até corrigir."; padrao=N; }
        if askyn "Remover estes arquivos? (cópia sem senha em $BK1X)" "$padrao"; then
            for f in "${rem[@]}"; do rm -f -- "$f" && log "Removido $f"; done
        else
            warn "Arquivos da 1.x mantidos. Remova-os depois: a senha continua no script."
        fi
    fi

    # O agendamento antigo não é alterado pelo instalador: fica como pendência para o técnico.
    for l in "${CRON1X[@]}"; do
        origem="${l%%|*}"; linha="${l#*|}"
        if [[ "$origem" == crontab:* ]]; then
            u="${origem#crontab:}"
            PENDENCIAS+=("Remova o agendamento da 1.x do crontab de $u (crontab -e -u $u):|$linha")
        else
            arq="${origem#arquivo:}"
            PENDENCIAS+=("Remova o agendamento da 1.x do arquivo $arq:|$linha")
        fi
    done

    if _tem_exclude_1x; then
        info "As exclusões agora ficam na wallet; a tabela maintenance.vacuum_exclude não é mais usada."
        if askyn "Apagar a tabela maintenance.vacuum_exclude do banco postgres? (cópia em $BK1X)" N; then
            if _psql_1x -c "DROP TABLE maintenance.vacuum_exclude" >/dev/null 2>&1; then
                log "Tabela maintenance.vacuum_exclude removida."
                # O schema só sai se estiver vazio (RESTRICT): pode ter outros objetos do cliente.
                if _psql_1x -c "DROP SCHEMA maintenance" >/dev/null 2>&1; then log "Schema maintenance (vazio) removido."
                else info "Schema maintenance mantido (tem outros objetos)."; fi
            else
                warn "Não foi possível remover a tabela. Nada foi apagado."
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# Instalação dos arquivos
# ------------------------------------------------------------------------------
_mkdir_rotina() { # <dir> <modo> : cria se não existir; não altera diretórios existentes
    if [ ! -d "$1" ]; then
        mkdir -p -- "$1" && chmod "$2" -- "$1" && log "Criado $1"
    fi
}

# Diretório que já existia e está aberto para outros usuários: só avisa, não altera.
# (Os arquivos da rotina são sempre gravados como 600/700, então continuam protegidos.)
_avisa_permissao() { # <dir> <motivo>
    local perm
    perm=$(stat -c %a -- "$1" 2>/dev/null) || return 0
    [ "${perm: -1}" = 0 ] && return 0
    warn "$1 já existia com permissão $perm (outros usuários têm acesso). Mantida como está."
    info "   $2"
}

cria_diretorios() {
    header "Diretórios"
    _mkdir_rotina "$DIR" 755
    if [ -d "$DIR/bin" ]; then
        _avisa_permissao "$DIR/bin" "Os scripts da rotina dentro dela são gravados cifrados e só para o root."
    else
        _mkdir_rotina "$DIR/bin" 700
    fi
    if [ -d "$DIR/wallet" ]; then
        _avisa_permissao "$DIR/wallet" "A wallet é gravada só para o root (600)."
    else
        _mkdir_rotina "$DIR/wallet" 700
    fi
    _mkdir_rotina "$DIR/log" 750
    _mkdir_rotina "$DIR/tmp" 700
    _mkdir_rotina "$(dirname -- "$LOG_GERAL")" 750
}

_write_loader() { # <enc> <loader> <sha256 do script> <nome>
    local tmp="$2.tmp.$$"
    cat > "$tmp" <<LOADER
#!/bin/bash
# Loader da rotina de vacuum/analyze PostgreSQL MigraTI $VERSAO_INSTALADOR — gerado pelo install.sh. Não edite.
# Decifra $4 com a chave desta máquina, confere a integridade e executa direto da memória.
umask 077
export MIGRA_DIR='$DIR'
_ENC='$1'
_SUM='$3'
_m=""
for _f in /etc/machine-id /var/lib/dbus/machine-id; do
    [ -r "\$_f" ] && _m=\$(tr -d '[:space:]' < "\$_f")
    [ -n "\$_m" ] && break
done
if [ -z "\$_m" ]; then echo "[ERRO] machine-id ausente ou vazio; não é possível carregar $4." >&2; exit 1; fi
_K=\$(printf '%s' "\$_m" | openssl dgst -sha256 | awk '{print \$NF}')
unset _m _f
_dec() { _MC_PASS="\$_K" openssl enc -aes-256-cbc -md sha256 -d -pass env:_MC_PASS -in "\$_ENC" 2>/dev/null; }
if [ "\$(_dec | openssl dgst -sha256 | awk '{print \$NF}')" != "\$_SUM" ]; then
    echo "[ERRO] Falha ao carregar \$_ENC (arquivo alterado/corrompido ou machine-id diferente). Reinstale a rotina." >&2
    exit 1
fi
exec bash <(_dec) "\$@"
LOADER
    chmod 700 -- "$tmp" && mv -f -- "$tmp" "$2"
}

instala_scripts() {
    header "Scripts protegidos"
    local name base enc
    if [ "$MODO" = atualizacao ]; then
        # Só os arquivos desta rotina: o bin/ pode ter também a rotina de backup.
        local bk; bk="$(_bk_dir)/bin"
        mkdir -p -m 700 -- "$bk" && for name in "${SCRIPTS[@]}"; do
            base="${name%.sh}"
            cp -p -- "$DIR/bin/$base" "$DIR/bin/$base.enc" "$bk/" 2>/dev/null
        done
        _bk_nota "bin/" "scripts da versão anterior (cifrados, como estavam)"
        info "Versão anterior dos scripts guardada em $bk"
    fi
    for name in "${SCRIPTS[@]}"; do
        base="${name%.sh}"
        enc="$DIR/bin/$base.enc"
        _mc_cipher e legacy 0 "$MACHINE_KEY" "${PLAIN[$name]}" "$enc.tmp.$$" \
            || abort "Falha ao cifrar $name"
        chmod 600 -- "$enc.tmp.$$" && mv -f -- "$enc.tmp.$$" "$enc"
        _write_loader "$enc" "$DIR/bin/$base" "${SUMS[$name]}" "$base"
        rm -f -- "${PLAIN[$name]}"
        log "$base instalado (cifrado com a chave desta máquina)"
    done
    _instala_comando migra-wallet-vacuum "$DIR/bin/migra-wallet-vacuum"
}

# Link do comando em /usr/bin, conferido no PATH. Só mexe em link com o nome do comando:
# um arquivo comum com o mesmo nome não é alterado. O link antigo em /usr/local/bin (2.0 a 2.3)
# sai só se apontar para esta mesma rotina.
_instala_comando() { # <nome> <alvo>
    local nome="$1" alvo l="$BIN_CMD/$1" a="$BIN_CMD_ANTIGO/$1" achado
    alvo=$(readlink -f -- "$2")
    if [ -L "$l" ] || [ ! -e "$l" ]; then
        if [ "$(readlink -f -- "$l" 2>/dev/null)" != "$alvo" ]; then
            if ln -sfn -- "$alvo" "$l"; then log "Link criado: $l -> $alvo"
            else warn "Não foi possível criar $l; use $alvo"; return 0; fi
        fi
    else
        warn "$l já existe e não é um link (não foi alterado); use $alvo"
        return 0
    fi
    if [ "$a" != "$l" ] && [ -L "$a" ] && [ "$(readlink -f -- "$a")" = "$alvo" ]; then
        rm -f -- "$a" && info "Link antigo removido: $a"
    fi
    achado=$(PATH="$BIN_CMD:/usr/sbin:/usr/bin:/sbin:/bin" command -v "$nome" 2>/dev/null)
    if [ -n "$achado" ] && [ "$(readlink -f -- "$achado")" = "$alvo" ]; then
        log "Comando disponível: $nome ($l)"
    else
        warn "O comando $nome não ficou disponível no PATH; use $alvo"
    fi
}

# ------------------------------------------------------------------------------
# Backups do instalador: tudo de uma execução numa pasta só, dentro do diretório da rotina
#   <DIR>/bkp_vacuum_<origem>_<AAAAMMDD_HHMMSS>/
#   origem: v<versão que estava instalada> (v1.4, v2.3...), nova (instalação nova)
#   conteúdo conforme o caso: crontab_root.bkp, bin/, arquivos da 1.x e README.txt
# ------------------------------------------------------------------------------
BK_DIR=""; BK_ORIGEM="v2x"
_bk_dir() { # cria a pasta desta execução (uma vez) e mostra o caminho
    if [ -z "$BK_DIR" ]; then
        BK_DIR="$DIR/bkp_vacuum_${BK_ORIGEM}_$TS"
        mkdir -p -m 700 -- "$BK_DIR" || abort "Falha ao criar $BK_DIR"
    fi
    printf '%s' "$BK_DIR"
}
_bk_nota() { # <item> <descrição> : uma linha no README.txt da pasta
    local r; r="$(_bk_dir)/README.txt"
    if [ ! -f "$r" ]; then
        printf 'Backup feito pelo install.sh %s da rotina de vacuum/analyze em %s.\nOrigem: %s\n\nConteúdo\n' \
            "$VERSAO_INSTALADOR" "$(date '+%d/%m/%Y %T')" "$BK_ORIGEM" > "$r"
    fi
    printf '  %-28s %s\n' "$1" "$2" >> "$r"
    chmod 600 -- "$r"
}

# Backups soltos da 2.0 a 2.3 (bin.bkp_vacuum.<TS>/ e crontab_root_vacuum_<TS>.bkp) vão para a
# pasta padrão com o mesmo <TS>. Só itens desta rotina, com estes nomes exatos; nada é apagado.
_bk_existente() { # <dir> <ts>
    local x
    for x in "$1"/bkp_vacuum_*_"$2"; do [ -d "$x" ] && { printf '%s' "$x"; return 0; }; done
    return 1
}
_antigos_lista() { # <dir> -> itens soltos de versões anteriores
    local f
    for f in "$1"/bin.bkp_vacuum.* "$1"/crontab_root_vacuum_*.bkp; do
        [ -e "$f" ] && [ ! -L "$f" ] && printf '%s\n' "$f"
    done
}
organiza_antigos() { # <dir>
    local d="$1" f ts dst n=0 nome
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            */bin.bkp_vacuum.*)         ts="${f##*.}"; nome=bin ;;
            */crontab_root_vacuum_*.bkp) ts="${f##*crontab_root_vacuum_}"; ts="${ts%.bkp}"; nome=crontab_root.bkp ;;
        esac
        [[ "$ts" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
        dst=$(_bk_existente "$d" "$ts") || dst="$d/bkp_vacuum_v2x_$ts"
        mkdir -p -m 700 -- "$dst" || continue
        [ -e "$dst/$nome" ] && continue
        mv -- "$f" "$dst/$nome" && n=$((n + 1)) && info "Organizado: $(basename -- "$f") -> $(basename -- "$dst")/$nome"
    done < <(_antigos_lista "$d")
    [ "$n" -gt 0 ] && log "$n backup(s) antigo(s) movido(s) para pastas bkp_vacuum_*"
    return 0
}

WALLET_PASS=""
cria_wallet() {
    header "Wallet"
    local wallet="$DIR/wallet/$WALLET_NOME" auto="$DIR/wallet/$AUTO_NOME" plain p2
    info "A senha da wallet protege a configuração (inclusive a senha do banco)."
    info "Ela é pedida para ver ou alterar qualquer configuração com migra-wallet-vacuum."
    info "O vacuum/analyze agendado não precisa dela. Guarde-a no Passbolt agora."
    while true; do
        askpass WALLET_PASS "Senha da wallet (mín. 8 caracteres)"
        [ "${#WALLET_PASS}" -ge 8 ] || { warn "Senha muito curta."; continue; }
        askpass p2 "Confirme a senha"
        [ "$WALLET_PASS" = "$p2" ] || { warn "As senhas não conferem."; continue; }
        break
    done
    unset p2
    VERSION="$VERSAO_INSTALADOR"
    _tmp plain
    _mc_render > "$plain"
    ( _mc_parse "$(cat "$plain")" && _mc_validate ) || abort "Configuração gerada é inválida (veja acima)."
    _mc_write "$wallet" WALLET "$(_mc_wallet_kdf)" "$WALLET_PASS" "$plain" || abort "Falha ao criar a wallet."
    _mc_write "$auto" AUTO legacy "$MACHINE_KEY" "$plain" || abort "Falha ao criar o auto-login."
    rm -f -- "$plain"
    log "Wallet: $wallet"
    log "Auto-login (só abre nesta máquina): $auto"
}

atualiza_wallet() { # modo atualização: abre a wallet, acrescenta chaves novas e regrava
    header "Wallet"
    local wallet="$DIR/wallet/$WALLET_NOME" auto="$DIR/wallet/$AUTO_NOME" txt rc plain
    while true; do
        askpass WALLET_PASS "Senha da wallet atual"
        txt=$(_mc_read "$wallet" "$WALLET_PASS"); rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$rc" -eq 1 ] && { warn "Senha incorreta."; continue; }
        abort "Wallet com formato inválido: $wallet"
    done
    VERSAO_ANTERIOR=$(_mc_txt_get "$txt" VERSION)
    txt=$(_mc_txt_merge "$txt")
    txt=$(_mc_txt_set "$txt" VERSION "$VERSAO_INSTALADOR")
    _mc_defaults
    _mc_parse "$txt" || abort "A wallet atual tem linhas inválidas. Corrija com migra-wallet-vacuum -edit e rode de novo."
    UPDATED_TXT="$txt"
}

# Atualização: confere se a credencial guardada na wallet ainda conecta, ANTES de aplicar.
# Se não conectar, mostra o erro e oferece corrigir (o resultado vai para a wallet).
CONEXAO_STATUS="não verificada"
testa_conexao_wallet() {
    header "Conexão com o PostgreSQL"
    local out errf d mv=0 k falhou=0
    _candidatos_pg
    PSQL_INST="${PG_BIN%/}/psql"
    if [ ! -x "$PSQL_INST" ]; then
        for d in "${!CAND[@]}"; do [ "${CAND[$d]}" -gt "$mv" ] && { mv="${CAND[$d]}"; PSQL_INST="$d/psql"; }; done
    fi
    if [ ! -x "$PSQL_INST" ]; then
        warn "psql não encontrado; a conexão será conferida na verificação final."
        return 0
    fi
    _tmp errf
    _pgpass_tmp PGPASSFILE_INST "$PGUSER" "$PGPASSWORD"
    if out=$(_psql -c 'SHOW server_version_num' 2> "$errf") && [[ "$out" =~ ^[0-9]+$ ]]; then
        SERVER_NUM="$out"; CONEXAO_STATUS="OK"
        log "A configuração atual conecta: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
        _confere_permissao || true
        return 0
    fi
    err "A configuração atual NÃO conecta ($PGUSER@$PGHOST:$PGPORT/$PGDATABASE):"
    err "  $(head -n 1 "$errf")"
    info "Sem conexão, o vacuum/analyze agendado vai falhar. Dá para corrigir agora: Enter mantém cada valor."
    if askyn "Corrigir a conexão agora?" S; then
        while true; do
            PG_BIN_ESCOLHIDO=1 CONEXAO_OPCIONAL=1 configura_conexao; case $? in 0) break ;; 2) continue ;; *) falhou=1; break ;; esac
        done
        if [ "$falhou" = 0 ]; then
            for k in PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PG_BIN; do
                UPDATED_TXT=$(_mc_txt_set "$UPDATED_TXT" "$k" "${!k}")
            done
            CONEXAO_STATUS="OK (corrigida; vai para a wallet)"
            return 0
        fi
    fi
    CONEXAO_STATUS="${RED}FALHA${NC} (não corrigida)"
    warn "Seguindo sem corrigir. Depois use: migra-wallet-vacuum -setCredential"
}

grava_wallet_atualizada() {
    local wallet="$DIR/wallet/$WALLET_NOME" auto="$DIR/wallet/$AUTO_NOME" plain
    _tmp plain
    printf '%s\n' "$UPDATED_TXT" > "$plain"
    cp -p -- "$wallet" "$wallet.1"
    _mc_write "$wallet" WALLET "$(_mc_wallet_kdf)" "$WALLET_PASS" "$plain" || abort "Falha ao regravar a wallet."
    _mc_write "$auto" AUTO legacy "$MACHINE_KEY" "$plain" || abort "Falha ao regravar o auto-login."
    rm -f -- "$plain"
    log "Wallet atualizada (versão anterior em $wallet.1)."
}

# ------------------------------------------------------------------------------
# Agendamento no crontab do root (padrão MigraTI: crontab -l / crontab -e).
# Uma linha é "da rotina" só se um dos campos for exatamente <dir>/bin/vacuum_analyze.
# ------------------------------------------------------------------------------
_CRON_AWK_NOSSA='function nossa(l,   n, i, f) {
    if (l ~ /^[[:space:]]*#/) return 0
    n = split(l, f, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (f[i] == ENVIRON["D"]) return 1
    return 0
}'
# Arte nova (A) e a da 2.2 (O) carregadas em arte[1..na] e velha[1..no]; bloco() compara a partir da linha i
_CRON_AWK_ARTE='function bloco(i, b, nb,   j) {
    if (i + nb - 1 > n) return 0
    for (j = 1; j <= nb; j++) if (l[i + j - 1] != b[j]) return 0
    return 1
}
BEGIN {
    na = split(ENVIRON["A"], arte, "\n"); if (arte[na] == "") na--
    no = split(ENVIRON["O"], velha, "\n"); if (velha[no] == "") no--
}'
_cron_arte_env() { printf '%s\n' "${CRON_ARTE[@]}"; }
_cron_arte22_env() { printf '%s\n' "${CRON_ARTE_22[@]}"; }

_cron_grava() { # <dir> <arquivo com o crontab novo> : guarda o crontab atual antes de trocar
    [ -n "$DIR" ] || DIR="$1"
    local bk; bk="$(_bk_dir)/crontab_root.bkp"
    if [ ! -e "$bk" ]; then          # na mesma execução, guarda só o crontab original
        crontab -l > "$bk" 2>/dev/null || : > "$bk"
        chmod 600 -- "$bk"
        _bk_nota "crontab_root.bkp" "crontab do root antes da alteração (crontab -l)"
    fi
    if crontab "$2"; then
        info "Crontab anterior guardado em $bk"
        return 0
    fi
    err "Falha ao gravar o crontab do root (o anterior está em $bk)."
    return 1
}

_cron_linhas() { # <dir> : linhas ativas do crontab do root que chamam o loader de <dir>
    crontab -l 2>/dev/null | D="$1/bin/vacuum_analyze" awk "$_CRON_AWK_NOSSA"' nossa($0)'
}

# Tira do crontab do root só o que é da rotina de <dir>: as linhas dela, o comentário da 2.0/2.1
# logo acima e a arte com a linha em branco abaixo dela (quando não sobra nenhuma linha de
# vacuum_analyze). O resto fica como está.
_cron_remove_linha() { # <dir>
    command -v crontab >/dev/null 2>&1 || return 0
    [ -n "$(_cron_linhas "$1")" ] || return 0
    local novo; _tmp novo
    _cron_sem_rotina "$1" > "$novo"
    _cron_grava "$1" "$novo" && log "Linhas da rotina removidas do crontab do root"
}

_cron_sem_rotina() { # <dir> -> crontab -l sem as linhas, o comentário antigo e a arte da rotina
    crontab -l 2>/dev/null | D="$1/bin/vacuum_analyze" T="$CRON_TAG" A="$(_cron_arte_env)" O="$(_cron_arte22_env)" \
        awk "$_CRON_AWK_NOSSA
$_CRON_AWK_ARTE"'
        { l[++n] = $0 }
        END {
            for (i = 1; i <= n; i++) if (nossa(l[i])) {
                fora[i] = 1
                if (i > 1 && l[i - 1] == ENVIRON["T"]) fora[i - 1] = 1
            }
            resta = 0
            for (i = 1; i <= n; i++) if (!fora[i] && l[i] !~ /^[[:space:]]*#/ && l[i] ~ /\/bin\/vacuum_analyze([[:space:]]|$)/) resta = 1
            if (!resta) for (i = 1; i <= n; i++) {
                if (bloco(i, arte, na)) {
                    for (j = 0; j < na; j++) fora[i + j] = 1
                    if (i + na <= n && l[i + na] == "") fora[i + na] = 1
                } else if (bloco(i, velha, no)) {
                    for (j = 0; j < no; j++) fora[i + j] = 1
                }
            }
            for (i = 1; i <= n; i++) if (!fora[i]) print l[i]
        }'
}

_cron_tem_arte() { # 0 se a arte já está no crontab (bloco inteiro, em sequência)
    crontab -l 2>/dev/null | A="$(_cron_arte_env)" O="" awk "$_CRON_AWK_ARTE"'
        { l[++n] = $0 }
        END { for (i = 1; i <= n; i++) if (bloco(i, arte, na)) exit 0; exit 1 }'
}

# Atualização: o comentário da 2.0/2.1 acima das linhas da rotina e a arte da 2.2 viram a arte
# atual, seguida de uma linha em branco. O resto do crontab não muda.
_cron_atualiza_arte() { # <dir>
    command -v crontab >/dev/null 2>&1 || return 0
    _cron_tem_arte && return 0
    local ct; ct=$(crontab -l 2>/dev/null)
    local novo; _tmp novo
    D="$1/bin/vacuum_analyze" T="$CRON_TAG" A="$(_cron_arte_env)" O="$(_cron_arte22_env)" \
        awk "$_CRON_AWK_NOSSA
$_CRON_AWK_ARTE"'
        { l[++n] = $0 }
        END {
            for (i = 1; i <= n; i++) {
                if (l[i] == ENVIRON["T"] && i < n && nossa(l[i + 1])) { print ENVIRON["A"]; print ""; continue }
                if (bloco(i, velha, no)) {
                    print ENVIRON["A"]; i += no - 1
                    if (i < n && l[i + 1] != "") print ""
                    continue
                }
                print l[i]
            }
        }' <<< "$ct" > "$novo"
    [ "$(cat "$novo")" = "$ct" ] && return 0
    _cron_grava "$1" "$novo" && log "Arte da rotina no crontab atualizada (moldura da MigraTI)"
}

# Os 5 campos de horário do cron: números, *, listas, faixas e passos (sem @reboot e afins)
_cron_campos_ok() {
    local -a c
    read -ra c <<< "$1"
    [ "${#c[@]}" -eq 5 ] || return 1
    local x; for x in "${c[@]}"; do [[ "$x" =~ ^[0-9*][0-9*,/-]*$ ]] || return 1; done
}

# Linha de cron da 1.x -> "campos|operação" (operação = argumento depois do script; padrão analyze)
_cron_1x_converte() { # <linha>
    local -a c
    local i op=analyze
    read -ra c <<< "$1"
    [ "${#c[@]}" -ge 6 ] || return 1
    _cron_campos_ok "${c[*]:0:5}" || return 1
    for ((i = 5; i < ${#c[@]}; i++)); do
        if [[ "${c[$i]}" =~ $_RE_1X ]]; then
            [[ " $OPERACOES " == *" ${c[$((i + 1))]:-} "* ]] && op="${c[$((i + 1))]}"
            printf '%s|%s' "${c[*]:0:5}" "$op"
            return 0
        fi
    done
    return 1
}

# Linhas novas no padrão MigraTI: "campos <dir>/bin/vacuum_analyze <op> >>/dev/null"
_cron_linha_nova() { # <"campos|op">
    printf '%s %s/bin/vacuum_analyze %s >>/dev/null' "${1%%|*}" "$DIR" "${1#*|}"
}

# Decide o agendamento antes do resumo (nada é gravado aqui).
#   CRON_ORIGEM: crontab (já existe, mantido) | 1x (mesmos horários da 1.x) | nova
#   CRON_NOVAS:  "campos|operação" das linhas a criar
# Padrão para instalação nova: ANALYZE diário e VACUUM semanal. FREEZE sem agendamento: o VACUUM
# (agressivo depois de vacuum_freeze_table_age) e o autovacuum já evitam o wraparound.
CRON_ANALYZE="00 03 * * 0-5"; CRON_VACUUM="00 01 * * 6"; CRON_ALL="N"; CRON_FREEZE="N"
CRON_ETAPAS=(
    "|CRON_ANALYZE|ANALYZE: horário do cron ou N|cron1"
    "|CRON_VACUUM|VACUUM: horário do cron ou N|cron"
    "|CRON_ALL|VACUUM + ANALYZE (all): horário do cron ou N|cron"
    "|CRON_FREEZE|VACUUM FREEZE (normalmente N): horário do cron ou N|cron"
)
#   CRON_ATUAIS:   "campos|operação" do que já existe (crontab do root ou 1.x)
#   CRON_ALTERADO: 1 quando as respostas diferem do que já existe (as linhas da rotina são trocadas)
CRON_PERGUNTAR=S; CRON_ORIGEM=nova; CRON_EXISTENTE=""; CRON_NOVAS=(); CRON_ATUAIS=()
CRON_ALTERADO=0; CRON_RESP_ORIG=""
_cron_das_respostas() {
    local op v
    CRON_NOVAS=()
    for op in analyze vacuum all freeze; do
        v="CRON_${op^^}"; v="${!v}"
        [ "${v^^}" = N ] || CRON_NOVAS+=("$v|$op")
    done
}
_cron_respostas_de() { # <entradas "campos|op"...> : vira a resposta padrão (entre colchetes) de cada operação
    local op l v
    for op in analyze vacuum all freeze; do
        v=N
        for l in "$@"; do [ "${l#*|}" = "$op" ] && { v="${l%%|*}"; break; }; done
        printf -v "CRON_${op^^}" '%s' "$v"
    done
}
_cron_respostas() { printf '%s|%s|%s|%s' "$CRON_ANALYZE" "$CRON_VACUUM" "$CRON_ALL" "$CRON_FREEZE"; }
_cron_prepara() {
    local l conv
    CRON_PERGUNTAR=S; CRON_ORIGEM=nova; CRON_EXISTENTE=""; CRON_NOVAS=(); CRON_ATUAIS=(); CRON_ALTERADO=0
    if command -v crontab >/dev/null 2>&1; then CRON_EXISTENTE=$(_cron_linhas "$DIR"); fi
    if [ -n "$CRON_EXISTENTE" ]; then
        mapfile -t CRON_ATUAIS < <(_cron_entradas "$CRON_EXISTENTE")
        CRON_PERGUNTAR=N; CRON_ORIGEM=crontab
    else
        for l in "${CRON1X[@]}"; do               # 1.x: mesmos horários e operações
            if conv=$(_cron_1x_converte "${l#*|}"); then
                [[ " ${CRON_ATUAIS[*]} " == *" $conv "* ]] || CRON_ATUAIS+=("$conv")
            else
                warn "Agendamento da 1.x não reconhecido (crie o equivalente depois): ${l#*|}"
            fi
        done
        [ "${#CRON_ATUAIS[@]}" -gt 0 ] && { CRON_PERGUNTAR=N; CRON_ORIGEM=1x; }
    fi
    if [ "$CRON_ORIGEM" = nova ]; then _cron_das_respostas; return 0; fi
    CRON_NOVAS=("${CRON_ATUAIS[@]}")
    _cron_respostas_de "${CRON_ATUAIS[@]}"    # o que existe vira o padrão das perguntas
    CRON_RESP_ORIG=$(_cron_respostas)
}
# Depois das perguntas: respostas iguais ao que existe = nada muda (todas as linhas ficam, mesmo
# repetidas); diferentes = as linhas da rotina passam a ser as das respostas.
_cron_define() {
    if [ "$CRON_ORIGEM" = nova ]; then _cron_das_respostas; return 0; fi
    if [ "$(_cron_respostas)" = "$CRON_RESP_ORIG" ]; then
        CRON_NOVAS=("${CRON_ATUAIS[@]}"); CRON_ALTERADO=0
    else
        _cron_das_respostas; CRON_ALTERADO=1
    fi
}
# Perguntas do agendamento com o que existe entre colchetes (Enter em tudo = mantém)
_cron_pergunta() {
    _assistente "${CRON_ETAPAS[@]}"
    _cron_define
    _cron_quadro
}

_cron_resumo() {
    local l
    case "$CRON_ORIGEM:$CRON_ALTERADO" in
        crontab:0) echo "já existe no crontab do root (mantido)" ;;
        crontab:1) echo "alterado: as linhas da rotina no crontab do root são trocadas" ;;
        1x:0)      echo "mesmos horários da 1.x · crontab do root" ;;
        1x:1)      echo "horários novos (diferentes da 1.x) · crontab do root" ;;
        *)         echo "crontab do root" ;;
    esac
    [ "${#CRON_NOVAS[@]}" -gt 0 ] || { echo "  (nenhuma linha: sem agendamento)"; return; }
    for l in "${CRON_NOVAS[@]}"; do
        printf '  %-24s%s\n' "$(_op_nome "${l#*|}")" "$(_cron_humano "${l%%|*}")  (${l%%|*})"
    done
}

configura_cron() {
    header "Agendamento"
    local l
    if ! command -v crontab >/dev/null 2>&1; then
        warn "Comando crontab não encontrado. Agende no crontab do root (crontab -e):"
        for l in "${CRON_NOVAS[@]}"; do echo "          $(_cron_linha_nova "$l")"; done
        return 0
    fi
    local atual; atual=$(_cron_linhas "$DIR")
    if [ -n "$atual" ] && [ "$CRON_ALTERADO" != 1 ]; then
        info "Agendamento existente mantido (crontab -l):"
        sed 's/^/          /' <<< "$atual"
        _cron_atualiza_arte "$DIR"
        local -a ex=(); mapfile -t ex < <(_cron_entradas "$atual")
        _cron_quadro "Como está o agendamento" "${ex[@]}"
        return 0
    fi
    # O crontab atual é copiado como está (crontab -l). Ao alterar, saem só as linhas e a arte da
    # rotina; o bloco novo é acrescentado no fim.
    local novo ct; _tmp novo
    if [ -n "$atual" ]; then ct=$(_cron_sem_rotina "$DIR"); else ct=$(crontab -l 2>/dev/null); fi
    if [ "${#CRON_NOVAS[@]}" -eq 0 ]; then
        if [ -n "$atual" ]; then
            printf '%s\n' "$ct" > "$novo"
            _cron_grava "$DIR" "$novo" && log "Linhas da rotina removidas do crontab do root (sem agendamento)"
        fi
        warn "Sem agendamento. Para criar depois: crontab -e, com linhas como:"
        echo "          00 03 * * * $DIR/bin/vacuum_analyze analyze >>/dev/null"
        return 0
    fi
    {
        [ -n "$ct" ] && printf '%s\n\n' "$ct"
        printf '%s\n' "${CRON_ARTE[@]}" ""
        for l in "${CRON_NOVAS[@]}"; do _cron_linha_nova "$l"; echo; done
    } > "$novo"
    if _cron_grava "$DIR" "$novo"; then
        log "Agendado no crontab do root:"
        for l in "${CRON_NOVAS[@]}"; do echo "          $(_cron_linha_nova "$l")"; done
        _cron_quadro "Agendamento gravado"
    else
        warn "Sem agendamento. Para criar depois: crontab -e e adicione as linhas acima."
    fi
}

CHECK_OK=0
verifica() {
    header "Verificação"
    while true; do
        if "$DIR/bin/vacuum_analyze" --check; then
            CHECK_OK=1
            log "Rotina verificada com sucesso."
            return 0
        fi
        warn "A verificação apontou problemas (acima). Os scripts já foram instalados; falta só ajustar a configuração."
        if ! askyn "Abrir o menu do migra-wallet-vacuum para corrigir agora?" S; then
            warn "Corrija depois com migra-wallet-vacuum e confira com: migra-wallet-vacuum -test"
            return 0
        fi
        "$DIR/bin/migra-wallet-vacuum" < "$TTY" || true
        header "Verificação"
    done
}

resumo() {
    header "Instalação concluída"
    linha_resumo "Rotina" "vacuum_analyze $VERSAO_INSTALADOR · modo $MODO"
    linha_resumo "Diretório" "$DIR"
    linha_resumo "Log geral" "$LOG_GERAL"
    linha_resumo "Logs por base" "$DIR/log/<base>_vacuum_AAAAMMDD.log"
    if command -v crontab >/dev/null 2>&1 && [ -n "$(_cron_linhas "$DIR")" ]; then
        linha_resumo "Agendamento" "crontab do root ($(_cron_linhas "$DIR" | grep -c .) linha(s); veja com crontab -l)"
    fi
    [ -d "$DIR/bkp_vacuum_${BK_ORIGEM}_$TS" ] && linha_resumo "Backup desta execução" "$DIR/bkp_vacuum_${BK_ORIGEM}_$TS"
    echo
    echo -e "   ${BOLD}Comandos${NC}"
    linha_resumo "migra-wallet-vacuum" "menu de configuração"
    linha_resumo "migra-wallet-vacuum -list" "ver a configuração"
    linha_resumo "migra-wallet-vacuum -test" "validar sem rodar vacuum/analyze"
    linha_resumo "$DIR/bin/vacuum_analyze analyze" "rodar agora (analyze, vacuum, all ou freeze)"
    echo
    if [ "${#PENDENCIAS[@]}" -gt 0 ]; then
        local p
        echo -e "   ${YELLOW}${BOLD}Falta você fazer${NC}"
        for p in "${PENDENCIAS[@]}"; do
            warn "${p%%|*}"
            echo -e "        ${BOLD}${p#*|}${NC}"
        done
        echo
    fi
    warn "Guarde a senha da wallet no Passbolt."
    warn "Apague o instalador: rm -f install.sh"
    echo
}

# ------------------------------------------------------------------------------
# Remoção (só os arquivos desta rotina; a rotina de backup no mesmo diretório fica intacta)
# ------------------------------------------------------------------------------
desinstala() {
    header "Remoção da rotina de vacuum/analyze"
    local d="" l v
    d=$(_dir_do_link) || d="$DIR_PADRAO"
    ask d "Diretório da rotina 2.x" "$d"
    d="${d%/}"
    _dir_seguro "$d" || abort "Diretório inválido: $d"
    [ -e "$d/bin/vacuum_analyze" ] || [ -e "$d/wallet/$WALLET_NOME" ] || abort "Rotina de vacuum/analyze 2.x não encontrada em $d"
    info "Serão removidos: as linhas da rotina no crontab do root, o link $LINK_TOOL e os scripts vacuum_analyze e migra-wallet-vacuum em $d/bin"
    info "NÃO serão tocados: logs, pastas bkp_vacuum_* e qualquer arquivo da rotina de backup"
    askyn "Continuar?" N || abort "Cancelado."
    DIR="$d"
    v=$(grep -m1 -oE 'vacuum/analyze PostgreSQL MigraTI [0-9]+\.[0-9]+' "$d/bin/vacuum_analyze" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+$')
    BK_ORIGEM="v${v:-2x}"
    organiza_antigos "$d"
    _cron_remove_linha "$d"
    for l in "$LINK_TOOL" "$LINK_TOOL_ANTIGO"; do      # só links que apontam para esta rotina
        if [ -L "$l" ] && [ "$(readlink -f -- "$l")" = "$(readlink -f -- "$d/bin/migra-wallet-vacuum")" ]; then
            rm -f -- "$l" && log "Removido $l"
        fi
    done
    rm -f -- "$d/bin/vacuum_analyze" "$d/bin/vacuum_analyze.enc" "$d/bin/migra-wallet-vacuum" "$d/bin/migra-wallet-vacuum.enc"
    rmdir -- "$d/bin" 2>/dev/null
    log "Scripts removidos."
    if [ -e "$d/wallet/$WALLET_NOME" ]; then
        warn "A wallet guarda toda a configuração. Sem ela, uma reinstalação começa do zero."
        if askyn "Apagar também a wallet da rotina de vacuum ($d/wallet/$WALLET_NOME)?" N; then
            rm -f -- "$d/wallet/$WALLET_NOME" "$d/wallet/$WALLET_NOME".[0-9] "$d/wallet/$AUTO_NOME" "$d/wallet/.migra-vacuum.lock"
            rmdir -- "$d/wallet" 2>/dev/null
            log "Wallet removida."
        fi
    fi
    rm -f -- "$d/tmp/vacuum_analyze.lock"
    log "Remoção concluída."
}

mostra_resumo() {
    local x primeiro=1
    header "Resumo antes de aplicar"
    linha_resumo "Modo" "$MODO"
    linha_resumo "Diretório da rotina" "$DIR"
    if [ "$MODO" = atualizacao ]; then
        linha_resumo "Nova versão" "$PKG_VERSAO (a configuração atual é mantida)"
        linha_resumo "Banco" "$PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
        linha_resumo "Conexão" "$CONEXAO_STATUS"
        linha_resumo "Bases ignoradas" "${EXCLUDE_BASES:-${DIM}nenhuma${NC}}"
        _resumo_tabelas
        linha_resumo "Agendamento" "$(_cron_resumo | head -n1)"
        _cron_resumo | tail -n +2 | sed 's/^/     /'
        _resumo_antigos
        echo; return 0
    fi
    linha_resumo "Banco" "$PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
    linha_resumo "psql" "$PG_BIN"
    linha_resumo "Execução" "$PARALLEL_JOBS tabela(s) ao mesmo tempo · lock_timeout $LOCK_TIMEOUT s"
    linha_resumo "Retenção dos logs" "$RETENCAO_LOG_DB dia(s)"
    if [ "$TITAN" = S ]; then linha_resumo "Zabbix" "$T_IP · host $T_HOST"
    else linha_resumo "Zabbix" "${DIM}não${NC}"; fi
    IFS=',' read -ra _l <<< "$EXCLUDE_BASES"
    for x in "${_l[@]}"; do
        x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
        [ -n "$x" ] || continue
        if [ "$primeiro" = 1 ]; then linha_resumo "Bases ignoradas" "$x"; primeiro=0
        else printf '%27s%s\n' "" "$x"; fi
    done
    [ "$primeiro" = 1 ] && linha_resumo "Bases ignoradas" "${DIM}nenhuma${NC}"
    _resumo_tabelas
    linha_resumo "Agendamento" "$(_cron_resumo | head -n1)"
    _cron_resumo | tail -n +2 | sed 's/^/     /'
    _resumo_antigos
    echo
}
_resumo_tabelas() {
    local x primeiro=1
    while IFS= read -r x; do
        [ -n "$x" ] || continue
        if [ "$primeiro" = 1 ]; then linha_resumo "Tabelas ignoradas" "$x"; primeiro=0
        else printf '%27s%s\n' "" "$x"; fi
    done < <(_exclusoes_tabelas)
    [ "$primeiro" = 1 ] && linha_resumo "Tabelas ignoradas" "${DIM}nenhuma${NC}"
    return 0
}
_resumo_antigos() {
    local n; n=$(_antigos_lista "$DIR" | grep -c .)
    [ "$n" -gt 0 ] && linha_resumo "Backups antigos" "$n item(ns) soltos vão para pastas bkp_vacuum_*"
    _bk_define_origem
    linha_resumo "Backup desta execução" "$DIR/bkp_vacuum_${BK_ORIGEM}_$TS"
    return 0
}
_bk_define_origem() { # nome da pasta de backup pelo modo: v<versão anterior> ou nova
    case "$MODO" in
        migracao)    BK_ORIGEM="v$(tr -cd '0-9A-Za-z.' <<< "${V1[VERSION]:-1x}")" ;;
        atualizacao) BK_ORIGEM="v$(tr -cd '0-9A-Za-z.' <<< "${VERSAO_ANTERIOR:-2x}")" ;;
        *)           BK_ORIGEM="nova" ;;
    esac
    [ "$BK_ORIGEM" = v ] && BK_ORIGEM="v2x"
    return 0
}

# Perguntas da instalação nova/migração, com "voltar" entre as etapas:
#   diretório (só nova) ← conexão ← configuração
_perguntas() {
    local e=1 rc exclusoes_importadas=0
    while [ "$e" -le 2 ]; do
        case $e in
            1)  configura_conexao; rc=$?
                CONEXAO_DO_FIM=0
                if [ "$rc" = 0 ]; then e=2
                elif [ "$MODO" = nova ]; then
                    if ! detecta_modo 4; then
                        detecta_modo
                        if [ "$MODO" = migracao ]; then localiza_1x; importa_1x; _cron_prepara; fi
                    fi
                else warn "Esta é a primeira pergunta da migração."
                fi ;;
            2)  if [ "$MODO" = migracao ] && [ "$exclusoes_importadas" = 0 ]; then
                    importa_exclusoes_1x; exclusoes_importadas=1
                fi
                if coleta_config; then e=3
                else e=1; CONEXAO_DO_FIM=1; echo -e "  ${DIM}↑ voltando${NC}"; fi ;;
        esac
    done
    dependencias
}

# ------------------------------------------------------------------------------
# Principal
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    banner
    check_basico
    if [ "$UNINSTALL" = 1 ]; then desinstala; exit 0; fi
    como_responder

    obter_pacote                         # 1º: chave do dia; inválida = encerra sem perguntas
    detecta_modo                         # até a confirmação do resumo, nada é alterado no servidor
    _mc_defaults

    case "$MODO" in
        atualizacao)
            atualiza_wallet
            testa_conexao_wallet
            importa_exclusoes_backup_1x
            mostra_exclusoes
            header "Agendamento"
            _cron_prepara
            if [ "$CRON_ORIGEM" = nova ]; then
                info "Esta instalação não tem agendamento."
            else
                _cron_quadro "Agendamento atual" "${CRON_ATUAIS[@]}"
                info "Enter em todas as perguntas mantém o agendamento atual."
            fi
            _cron_pergunta
            ;;
        migracao)
            localiza_1x
            importa_1x
            _cron_prepara
            _perguntas
            ;;
        nova)
            PARALLEL_JOBS=$(_jobs_recomendado)   # padrão: metade das vCPUs desta máquina
            _cron_prepara
            _perguntas
            ;;
    esac

    local resp valida padrao
    while true; do
        mostra_resumo
        if [ "$MODO" = atualizacao ]; then
            if ! ( _mc_parse "$UPDATED_TXT" && _mc_validate ) > /dev/null 2>&1; then
                ( _mc_parse "$UPDATED_TXT" && _mc_validate ) 2>&1 | sed 's/^/       /'
                warn "A wallet atual tem valores inválidos (acima). Depois da atualização, corrija com migra-wallet-vacuum."
            fi
            echo -e "   ${BOLD}S${NC} aplicar   ${BOLD}A${NC} alterar o agendamento   ${BOLD}N${NC} cancelar"
            ask resp "Escolha" S || continue
            case "${resp^^}" in
                S) break ;;
                A) header "Agendamento"; _cron_pergunta ;;
                N) abort "Cancelado. Nada foi alterado." ;;
                *) warn "Responda S, A ou N." ;;
            esac
            continue
        fi
        valida=1; padrao=S
        _config_valida || { valida=0; padrao=R; }
        echo -e "   ${BOLD}S${NC} aplicar   ${BOLD}R${NC} revisar a configuração   ${BOLD}C${NC} revisar a conexão   ${BOLD}N${NC} cancelar"
        ask resp "Escolha" "$padrao" || continue
        case "${resp^^}" in
            S) [ "$valida" = 1 ] && break
               warn "Corrija os valores acima (R ou C) antes de aplicar. Nada foi alterado." ;;
            R) REVISAO=1 coleta_config; dependencias ;;
            C) REVISAO=1 configura_conexao ;;
            N) abort "Cancelado. Nada foi alterado." ;;
            *) warn "Responda S, R, C ou N." ;;
        esac
    done

    _bk_define_origem
    organiza_antigos "$DIR"
    [ "$MODO" = migracao ] && backup_1x
    cria_diretorios
    instala_scripts
    if [ "$MODO" = atualizacao ]; then grava_wallet_atualizada; else cria_wallet; fi
    unset PGPASSWORD
    configura_cron
    verifica
    [ "$MODO" = migracao ] && limpa_1x
    resumo
}

# Carregado com "source" (testes): só define as funções.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
main "$@"
