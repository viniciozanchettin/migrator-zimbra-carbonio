#!/bin/bash

# =====================================================================
# MIGRAÇÃO DE PROVISIONAMENTO
# Zimbra 8.8.15 -> Carbonio 26
#
# Execute como root.
#
# EXPORTAR NO ZIMBRA:
#   ./migrate-zimbra-carbonio.sh export
#
# VALIDAR NO CARBONIO:
#   ./migrate-zimbra-carbonio.sh import --dry-run
#
# IMPORTAR NO CARBONIO:
#   ./migrate-zimbra-carbonio.sh import
#
# TROCAR SENHAS LOCAIS NO CARBONIO (OPCIONAL, APÓS IMPORTAR):
#   ./migrate-zimbra-carbonio.sh reset-passwords --dry-run
#   ./migrate-zimbra-carbonio.sh reset-passwords
#
# ---------------------------------------------------------------------
# EXPORTA:
#
#   - Lista de domínios (NÃO cria no Carbonio)
#   - Contas normais
#   - givenName
#   - sn
#   - displayName
#   - zimbraAuthLdapExternalDn
#   - aliases de contas
#   - listas de distribuição
#   - aliases das listas
#   - membros das listas
#   - forwarding configurado pelo usuário
#   - forwarding administrativo/oculto
#   - configuração de manter ou não cópia local
#
# NÃO EXPORTA:
#
#   - senha
#   - COS
#   - quota
#   - mensagens
#   - calendário
#   - contatos
#   - contas internas como:
#       galsync
#       spam
#       ham
#       quarantine
#       virus-quarantine
#
# ---------------------------------------------------------------------
#
# Arquivos gerados:
#
# migration-data/
# ├── accounts.tsv
# ├── aliases.tsv
# ├── forwarding.tsv
# ├── groups.tsv
# ├── group-aliases.tsv
# ├── group-members.tsv
# ├── domains.txt
# ├── excluded-accounts.txt
# └── logs/
#
# =====================================================================

set -u
set -o pipefail

umask 077


# =====================================================================
# CONFIGURAÇÃO
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="${SCRIPT_DIR}/migration-data"
LOG_DIR="${DATA_DIR}/logs"

ACCOUNTS_FILE="${DATA_DIR}/accounts.tsv"
ALIASES_FILE="${DATA_DIR}/aliases.tsv"
FORWARDING_FILE="${DATA_DIR}/forwarding.tsv"

GROUPS_FILE="${DATA_DIR}/groups.tsv"
GROUP_ALIASES_FILE="${DATA_DIR}/group-aliases.tsv"
GROUP_MEMBERS_FILE="${DATA_DIR}/group-members.tsv"

DOMAINS_FILE="${DATA_DIR}/domains.txt"
EXCLUDED_FILE="${DATA_DIR}/excluded-accounts.txt"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="${LOG_DIR}/migration-${TIMESTAMP}.log"

DRY_RUN=0


# =====================================================================
# CORES
# =====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


# =====================================================================
# LOG
# =====================================================================

log()
{
    mkdir -p "$LOG_DIR"

    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}


info()
{
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO $*"
}


ok()
{
    echo -e "${GREEN}[ OK ]${NC} $*"
    log "OK $*"
}


warn()
{
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN $*"
}


error()
{
    echo -e "${RED}[ERRO]${NC} $*" >&2
    log "ERROR $*"
}


die()
{
    error "$*"
    exit 1
}


# =====================================================================
# VALIDAÇÃO ROOT
# =====================================================================

require_root()
{
    if [ "$(id -u)" -ne 0 ]; then
        die "Execute este script como root."
    fi
}


# =====================================================================
# FUNÇÃO PARA EXECUTAR COMO ZIMBRA
# =====================================================================

zimbra_cmd()
{
    local cmd="zmprov"

    local arg

    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        cmd+=" $quoted"
    done

    su - zimbra -c "$cmd" </dev/null
}


# =====================================================================
# FUNÇÃO PARA EXECUTAR COMO ZEXTRAS
# =====================================================================

carbonio_cmd()
{
    local cmd="carbonio prov"

    local arg

    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        cmd+=" $quoted"
    done

    su - zextras -c "$cmd"
}


# =====================================================================
# CLEAN FIELD
#
# Remove TAB/CR/LF para não quebrar TSV.
# =====================================================================

clean_field()
{
    local value="${1:-}"

    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"

    printf '%s' "$value"
}


# =====================================================================
# LER ATRIBUTO ÚNICO DE CONTA
# =====================================================================

get_account_attr()
{
    local account="$1"
    local attr="$2"

    zimbra_cmd ga "$account" "$attr" 2>/dev/null |
        awk -F': ' -v attr="$attr" '
            $1 == attr {
                sub(/^[^:]*: /, "")
                print
                exit
            }
        '
}


# =====================================================================
# LER TODOS OS VALORES DE UM ATRIBUTO
# =====================================================================

get_account_multi_attr()
{
    local account="$1"
    local attr="$2"

    zimbra_cmd ga "$account" "$attr" 2>/dev/null |
        awk -F': ' -v attr="$attr" '
            $1 == attr {
                sub(/^[^:]*: /, "")
                print
            }
        '
}


# =====================================================================
# ATRIBUTO ÚNICO DE DISTRIBUTION LIST
# =====================================================================

get_group_attr()
{
    local group="$1"
    local attr="$2"

    zimbra_cmd gdl "$group" "$attr" 2>/dev/null |
        awk -F': ' -v attr="$attr" '
            $1 == attr {
                sub(/^[^:]*: /, "")
                print
                exit
            }
        '
}


# =====================================================================
# ATRIBUTO MULTI DE DISTRIBUTION LIST
# =====================================================================

get_group_multi_attr()
{
    local group="$1"
    local attr="$2"

    zimbra_cmd gdl "$group" "$attr" 2>/dev/null |
        awk -F': ' -v attr="$attr" '
            $1 == attr {
                sub(/^[^:]*: /, "")
                print
            }
        '
}


# =====================================================================
# CONTAS INTERNAS CONHECIDAS
# =====================================================================

is_internal_account()
{
    local account
    local localpart

    account="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    localpart="${account%@*}"

    case "$localpart" in

        galsync|\
        galsync-*|\
        galsync.*|\
        spam|\
        spam-*|\
        spam.*|\
        ham|\
        ham-*|\
        ham.*|\
        quarantine|\
        quarantine-*|\
        quarantine.*|\
        virus-quarantine|\
        virus-quarantine-*|\
        virus-quarantine.*|\
        amavis|\
        amavis-*|\
        amavis.*)

            return 0
            ;;

    esac

    return 1
}


# =====================================================================
# CONTAS EXCLUÍDAS MANUALMENTE
# =====================================================================

is_manually_excluded()
{
    local account="$1"

    [ -f "$EXCLUDED_FILE" ] || return 1

    grep -Fxiq "$account" "$EXCLUDED_FILE"
}


# =====================================================================
# CRIAR ARQUIVO DE EXCLUSÕES CASO NÃO EXISTA
# =====================================================================

create_exclusion_file()
{
    if [ ! -f "$EXCLUDED_FILE" ]; then

        cat > "$EXCLUDED_FILE" <<'EOF'
# Uma conta por linha.
#
# Linhas iniciadas com # são ignoradas.
#
# Exemplo:
#
# admin@empresa.com.br
# teste@empresa.com.br

EOF

    fi
}


# Consulta e valida listagens antes de substituir os arquivos exportados.
# O status de comandos dentro de < <(...) não é propagado ao loop leitor.
get_export_list()
{
    local kind="$1" output line
    shift

    if ! output="$(zimbra_cmd "$@" 2>> "$LOG_FILE")"; then
        printf '%s\n' "$output" >> "$LOG_FILE"
        error "Falha ao listar $kind no Zimbra. Consulte $LOG_FILE"
        return 1
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ [[:space:]] ]] ||
           { [ "$kind" != "domínios" ] &&
             [[ ! "$line" =~ ^[^@]+@[^@]+$ ]]; } ||
           { [ "$kind" = "domínios" ] &&
             [[ ! "$line" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; }; then
            printf '%s\n' "$output" >> "$LOG_FILE"
            error "Saída inválida ao listar $kind. Consulte $LOG_FILE"
            return 1
        fi
    done <<< "$output"

    printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | sort -u
}


# =====================================================================
# EXPORTAR
# =====================================================================

do_export()
{
    require_root

    id zimbra >/dev/null 2>&1 ||
        die "Usuário zimbra não encontrado."

    mkdir -p "$DATA_DIR" "$LOG_DIR"

    create_exclusion_file

    info "Validando listagens do Zimbra antes de exportar."
    local domains accounts groups
    domains="$(get_export_list domínios gad)" ||
        die "Exportação interrompida; arquivos de dados anteriores preservados."
    accounts="$(get_export_list contas -l gaa)" ||
        die "Exportação interrompida; arquivos de dados anteriores preservados."
    groups="$(get_export_list listas gadl)" ||
        die "Exportação interrompida; arquivos de dados anteriores preservados."

    : > "$ACCOUNTS_FILE"
    : > "$ALIASES_FILE"
    : > "$FORWARDING_FILE"
    : > "$GROUPS_FILE"
    : > "$GROUP_ALIASES_FILE"
    : > "$GROUP_MEMBERS_FILE"
    : > "$DOMAINS_FILE"

    info "Iniciando exportação do Zimbra."


    # =================================================================
    # DOMÍNIOS
    # =================================================================

    info "Exportando lista de domínios."

    printf '%s\n' "$domains" |
        sed '/^[[:space:]]*$/d' |
        sort -u \
        > "$DOMAINS_FILE"


    # =================================================================
    # CONTAS
    # =================================================================

    info "Exportando contas."

    total_accounts=0
    ignored_accounts=0
    total_aliases=0
    total_forwarding=0

    while IFS= read -r account
    do

        [ -z "$account" ] && continue


        # -------------------------------------------------------------
        # INTERNA
        # -------------------------------------------------------------

        if is_internal_account "$account"; then

            warn "Ignorando conta interna: $account"

            ((ignored_accounts++)) || true

            continue

        fi


        # -------------------------------------------------------------
        # EXCLUSÃO MANUAL
        # -------------------------------------------------------------

        if is_manually_excluded "$account"; then

            warn "Ignorando conta definida em excluded-accounts.txt: $account"

            ((ignored_accounts++)) || true

            continue

        fi


        info "Conta: $account"


        # -------------------------------------------------------------
        # ATRIBUTOS
        # -------------------------------------------------------------

        given_name="$(get_account_attr "$account" givenName || true)"
        surname="$(get_account_attr "$account" sn || true)"
        display_name="$(get_account_attr "$account" displayName || true)"

        external_dn="$(
            get_account_attr \
                "$account" \
                zimbraAuthLdapExternalDn \
            || true
        )"


        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(clean_field "$account")" \
            "$(clean_field "$given_name")" \
            "$(clean_field "$surname")" \
            "$(clean_field "$display_name")" \
            "$(clean_field "$external_dn")" \
            >> "$ACCOUNTS_FILE"


        # =============================================================
        # ALIASES DA CONTA
        # =============================================================

        while IFS= read -r alias
        do

            [ -z "$alias" ] && continue

            # Segurança: não grava o próprio endereço como alias
            if [ "${alias,,}" = "${account,,}" ]; then
                continue
            fi

            printf '%s\t%s\n' \
                "$(clean_field "$account")" \
                "$(clean_field "$alias")" \
                >> "$ALIASES_FILE"

            ((total_aliases++)) || true

        done < <(
            get_account_multi_attr \
                "$account" \
                zimbraMailAlias \
            || true
        )


        # =============================================================
        # FORWARD CONFIGURADO PELO USUÁRIO
        # =============================================================

        pref_forward="$(
            get_account_attr \
                "$account" \
                zimbraPrefMailForwardingAddress \
            || true
        )"

        local_disabled="$(
            get_account_attr \
                "$account" \
                zimbraPrefMailLocalDeliveryDisabled \
            || true
        )"


        if [ -n "$pref_forward" ]; then

            [ -z "$local_disabled" ] &&
                local_disabled="FALSE"

            printf '%s\t%s\t%s\t%s\n' \
                "$(clean_field "$account")" \
                "PREF" \
                "$(clean_field "$pref_forward")" \
                "$(clean_field "$local_disabled")" \
                >> "$FORWARDING_FILE"

            ((total_forwarding++)) || true

        fi


        # =============================================================
        # FORWARD ADMINISTRATIVO / OCULTO
        # =============================================================

        while IFS= read -r hidden_forward
        do

            [ -z "$hidden_forward" ] && continue

            printf '%s\t%s\t%s\t%s\n' \
                "$(clean_field "$account")" \
                "ADMIN" \
                "$(clean_field "$hidden_forward")" \
                "-" \
                >> "$FORWARDING_FILE"

            ((total_forwarding++)) || true

        done < <(
            get_account_multi_attr \
                "$account" \
                zimbraMailForwardingAddress \
            || true
        )


        ((total_accounts++)) || true

    done <<< "$accounts"


    # =================================================================
    # DISTRIBUTION LISTS
    # =================================================================

    info "Exportando listas de distribuição."

    total_groups=0
    total_group_aliases=0
    total_group_members=0

    while IFS= read -r group
    do

        [ -z "$group" ] && continue

        info "Lista: $group"


        # -------------------------------------------------------------
        # DISPLAY NAME
        # -------------------------------------------------------------

        group_display="$(
            get_group_attr \
                "$group" \
                displayName \
            || true
        )"

        printf '%s\t%s\n' \
            "$(clean_field "$group")" \
            "$(clean_field "$group_display")" \
            >> "$GROUPS_FILE"


        # =============================================================
        # ALIASES DA LISTA
        # =============================================================

        while IFS= read -r alias
        do

            [ -z "$alias" ] && continue

            # zimbraMailAlias pode conter o próprio endereço da DL.
            if [ "${alias,,}" = "${group,,}" ]; then
                continue
            fi

            printf '%s\t%s\n' \
                "$(clean_field "$group")" \
                "$(clean_field "$alias")" \
                >> "$GROUP_ALIASES_FILE"

            ((total_group_aliases++)) || true

        done < <(
            get_group_multi_attr \
                "$group" \
                zimbraMailAlias \
            || true
        )


        # =============================================================
        # MEMBROS
        #
        # IMPORTANTE:
        #
        # Em uma Distribution List, os membros aparecem em
        # zimbraMailForwardingAddress.
        # =============================================================

        while IFS= read -r member
        do

            [ -z "$member" ] && continue

            printf '%s\t%s\n' \
                "$(clean_field "$group")" \
                "$(clean_field "$member")" \
                >> "$GROUP_MEMBERS_FILE"

            ((total_group_members++)) || true

        done < <(
            get_group_multi_attr \
                "$group" \
                zimbraMailForwardingAddress \
            || true
        )


        ((total_groups++)) || true

    done <<< "$groups"


    # =================================================================
    # REMOVE DUPLICIDADES
    # =================================================================

    for file in \
        "$ACCOUNTS_FILE" \
        "$ALIASES_FILE" \
        "$FORWARDING_FILE" \
        "$GROUPS_FILE" \
        "$GROUP_ALIASES_FILE" \
        "$GROUP_MEMBERS_FILE"
    do

        if [ -s "$file" ]; then

            sort -u "$file" -o "$file"

        fi

    done


    # =================================================================
    # RESUMO
    # =================================================================

    echo
    echo "================================================================="
    echo " EXPORTAÇÃO CONCLUÍDA"
    echo "================================================================="
    echo
    echo "Contas exportadas ..........: $total_accounts"
    echo "Contas ignoradas ...........: $ignored_accounts"
    echo "Aliases de contas ..........: $(wc -l < "$ALIASES_FILE")"
    echo "Forwardings ................: $(wc -l < "$FORWARDING_FILE")"
    echo
    echo "Listas de distribuição .....: $total_groups"
    echo "Aliases de listas ..........: $(wc -l < "$GROUP_ALIASES_FILE")"
    echo "Membros de listas ..........: $(wc -l < "$GROUP_MEMBERS_FILE")"
    echo
    echo "Domínios ...................: $(wc -l < "$DOMAINS_FILE")"
    echo
    echo "Diretório:"
    echo "  $DATA_DIR"
    echo
    echo "Log:"
    echo "  $LOG_FILE"
    echo

    ok "Exportação concluída."
}


# =====================================================================
# VERIFICAÇÕES CARBONIO
# =====================================================================

domain_exists()
{
    carbonio_cmd gd "$1" >/dev/null 2>&1
}


account_exists()
{
    carbonio_cmd ga "$1" >/dev/null 2>&1
}


group_exists()
{
    carbonio_cmd gdl "$1" >/dev/null 2>&1
}


# =====================================================================
# EXECUTAR COMANDO CARBONIO
# =====================================================================

run_carbonio()
{
    local description="$1"

    shift


    # -----------------------------------------------------------------
    # DRY RUN
    # -----------------------------------------------------------------

    if [ "$DRY_RUN" -eq 1 ]; then

        printf '[DRY-RUN] carbonio prov'

        local arg

        for arg in "$@"; do
            printf ' %q' "$arg"
        done

        echo

        log "DRY-RUN $description"

        return 0

    fi


    # -----------------------------------------------------------------
    # EXECUÇÃO REAL
    # -----------------------------------------------------------------

    if carbonio_cmd "$@" >> "$LOG_FILE" 2>&1; then

        ok "$description"

        return 0

    else

        error "$description"

        return 1

    fi
}


# =====================================================================
# IMPORT
# =====================================================================

do_import()
{
    require_root

    id zextras >/dev/null 2>&1 ||
        die "Usuário zextras não encontrado. Execute no Carbonio."


    # =================================================================
    # VALIDAR ARQUIVOS
    # =================================================================

    [ -f "$DOMAINS_FILE" ] ||
        die "Arquivo inexistente: $DOMAINS_FILE"

    [ -f "$ACCOUNTS_FILE" ] ||
        die "Arquivo inexistente: $ACCOUNTS_FILE"


    touch "$ALIASES_FILE"
    touch "$FORWARDING_FILE"
    touch "$GROUPS_FILE"
    touch "$GROUP_ALIASES_FILE"
    touch "$GROUP_MEMBERS_FILE"


    # =================================================================
    # VALIDAR TODOS OS DOMÍNIOS
    #
    # NÃO cria domínio automaticamente.
    # =================================================================

    info "Validando domínios no Carbonio."

    missing_domains=0

    while IFS= read -r domain
    do

        [ -z "$domain" ] && continue

        if domain_exists "$domain"; then

            ok "Domínio existente: $domain"

        else

            error "Domínio NÃO existe no Carbonio: $domain"

            ((missing_domains++)) || true

        fi

    done < "$DOMAINS_FILE"


    if [ "$missing_domains" -gt 0 ]; then

        echo
        die "Existem $missing_domains domínio(s) ausente(s). Nenhuma conta foi criada."

    fi


    # =================================================================
    # SENHA LOCAL
    # =================================================================

    if [ "$DRY_RUN" -eq 1 ]; then

        DEFAULT_PASSWORD='DRY-RUN-PASSWORD'

        warn "DRY-RUN ativo. Nenhuma alteração será realizada."

    else

        echo

        read -r -s \
            -p "Senha local padrão para TODAS as contas: " \
            DEFAULT_PASSWORD

        echo

        read -r -s \
            -p "Confirme a senha: " \
            DEFAULT_PASSWORD_CONFIRM

        echo
        echo


        if [ "$DEFAULT_PASSWORD" != "$DEFAULT_PASSWORD_CONFIRM" ]; then
            die "As senhas são diferentes."
        fi


        if [ -z "$DEFAULT_PASSWORD" ]; then
            die "A senha não pode estar vazia."
        fi

    fi


    # =================================================================
    # CONTADORES
    # =================================================================

    created_accounts=0
    existing_accounts=0
    failed_accounts=0

    created_groups=0
    existing_groups=0

    applied_aliases=0
    applied_group_aliases=0
    applied_group_members=0
    applied_forwards=0
    applied_ad=0


    # =================================================================
    # FASE 1 - CONTAS
    # =================================================================

    echo
    info "FASE 1/7 - Criando contas."

    while IFS=$'\t' read -r \
        account \
        given_name \
        surname \
        display_name \
        external_dn
    do

        [ -z "$account" ] && continue


        if account_exists "$account"; then

            warn "Conta já existe: $account"

            ((existing_accounts++)) || true

            continue

        fi


        args=(
            ca
            "$account"
            "$DEFAULT_PASSWORD"
        )


        [ -n "${given_name:-}" ] &&
            args+=(givenName "$given_name")

        [ -n "${surname:-}" ] &&
            args+=(sn "$surname")

        [ -n "${display_name:-}" ] &&
            args+=(displayName "$display_name")


        if run_carbonio \
            "Conta criada: $account" \
            "${args[@]}"
        then

            ((created_accounts++)) || true

        else

            ((failed_accounts++)) || true

        fi

    done < "$ACCOUNTS_FILE"


    # =================================================================
    # FASE 2 - VÍNCULO AD INDIVIDUAL
    #
    # Também aplica em contas que já existiam.
    # =================================================================

    echo
    info "FASE 2/7 - Aplicando vínculos individuais do Active Directory."

    while IFS=$'\t' read -r \
        account \
        given_name \
        surname \
        display_name \
        external_dn
    do

        [ -z "$account" ] && continue
        [ -z "${external_dn:-}" ] && continue


        if ! account_exists "$account" && [ "$DRY_RUN" -eq 0 ]; then

            error "Conta não existe para aplicar AD: $account"

            continue

        fi


        if run_carbonio \
            "AD: $account -> $external_dn" \
            ma \
            "$account" \
            zimbraAuthLdapExternalDn \
            "$external_dn"
        then

            ((applied_ad++)) || true

        fi

    done < "$ACCOUNTS_FILE"


    # =================================================================
    # FASE 3 - ALIASES DE CONTAS
    # =================================================================

    echo
    info "FASE 3/7 - Adicionando aliases das contas."

    while IFS=$'\t' read -r account alias
    do

        [ -z "$account" ] && continue
        [ -z "$alias" ] && continue


        if ! account_exists "$account" && [ "$DRY_RUN" -eq 0 ]; then

            error "Conta inexistente para alias: $account -> $alias"

            continue

        fi


        if run_carbonio \
            "Alias: $alias -> $account" \
            aaa \
            "$account" \
            "$alias"
        then

            ((applied_aliases++)) || true

        fi

    done < "$ALIASES_FILE"


    # =================================================================
    # FASE 4 - LISTAS DE DISTRIBUIÇÃO
    # =================================================================

    echo
    info "FASE 4/7 - Criando listas de distribuição."

    while IFS=$'\t' read -r group display_name
    do

        [ -z "$group" ] && continue


        if group_exists "$group"; then

            warn "Lista já existe: $group"

            ((existing_groups++)) || true

            continue

        fi


        args=(
            cdl
            "$group"
        )


        if [ -n "${display_name:-}" ]; then

            args+=(
                displayName
                "$display_name"
            )

        fi


        if run_carbonio \
            "Lista criada: $group" \
            "${args[@]}"
        then

            ((created_groups++)) || true

        fi

    done < "$GROUPS_FILE"


    # =================================================================
    # FASE 5 - ALIASES DAS LISTAS
    # =================================================================

    echo
    info "FASE 5/7 - Adicionando aliases das listas."

    while IFS=$'\t' read -r group alias
    do

        [ -z "$group" ] && continue
        [ -z "$alias" ] && continue


        if ! group_exists "$group" && [ "$DRY_RUN" -eq 0 ]; then

            error "Lista inexistente para alias: $group -> $alias"

            continue

        fi


        if run_carbonio \
            "Alias de lista: $alias -> $group" \
            adla \
            "$group" \
            "$alias"
        then

            ((applied_group_aliases++)) || true

        fi

    done < "$GROUP_ALIASES_FILE"


    # =================================================================
    # FASE 6 - MEMBROS DAS LISTAS
    # =================================================================

    echo
    info "FASE 6/7 - Adicionando membros das listas."

    while IFS=$'\t' read -r group member
    do

        [ -z "$group" ] && continue
        [ -z "$member" ] && continue


        if ! group_exists "$group" && [ "$DRY_RUN" -eq 0 ]; then

            error "Lista inexistente: $group"

            continue

        fi


        if run_carbonio \
            "Membro: $member -> $group" \
            adlm \
            "$group" \
            "$member"
        then

            ((applied_group_members++)) || true

        fi

    done < "$GROUP_MEMBERS_FILE"


    # =================================================================
    # FASE 7 - FORWARDINGS
    # =================================================================

    echo
    info "FASE 7/7 - Aplicando encaminhamentos."


    while IFS=$'\t' read -r \
        account \
        type \
        destination \
        local_disabled
    do

        [ -z "$account" ] && continue
        [ -z "$type" ] && continue
        [ -z "$destination" ] && continue


        if ! account_exists "$account" && [ "$DRY_RUN" -eq 0 ]; then

            error "Conta inexistente para forwarding: $account"

            continue

        fi


        # -------------------------------------------------------------
        # PREF
        #
        # Encaminhamento configurado pelo usuário.
        # -------------------------------------------------------------

        if [ "$type" = "PREF" ]; then

            case "${local_disabled^^}" in

                TRUE|FALSE)
                    ;;

                *)
                    local_disabled="FALSE"
                    ;;

            esac


            if run_carbonio \
                "Forward PREF: $account -> $destination (localDisabled=$local_disabled)" \
                ma \
                "$account" \
                zimbraPrefMailForwardingAddress \
                "$destination" \
                zimbraPrefMailLocalDeliveryDisabled \
                "$local_disabled"
            then

                ((applied_forwards++)) || true

            fi

        fi


        # -------------------------------------------------------------
        # ADMIN
        #
        # zimbraMailForwardingAddress é multivalorado.
        # O prefixo + adiciona um valor sem substituir os anteriores.
        # -------------------------------------------------------------

        if [ "$type" = "ADMIN" ]; then

            if run_carbonio \
                "Forward ADMIN: $account -> $destination" \
                ma \
                "$account" \
                +zimbraMailForwardingAddress \
                "$destination"
            then

                ((applied_forwards++)) || true

            fi

        fi

    done < "$FORWARDING_FILE"


    # =================================================================
    # RESUMO
    # =================================================================

    echo
    echo "================================================================="
    echo " IMPORTAÇÃO FINALIZADA"
    echo "================================================================="
    echo
    echo "CONTAS"
    echo "  Criadas ..................: $created_accounts"
    echo "  Já existentes ............: $existing_accounts"
    echo "  Falhas ...................: $failed_accounts"
    echo
    echo "ACTIVE DIRECTORY"
    echo "  Vínculos aplicados .......: $applied_ad"
    echo
    echo "ALIASES"
    echo "  Aliases de contas ........: $applied_aliases"
    echo
    echo "LISTAS"
    echo "  Criadas ..................: $created_groups"
    echo "  Já existentes ............: $existing_groups"
    echo "  Aliases de listas ........: $applied_group_aliases"
    echo "  Membros adicionados ......: $applied_group_members"
    echo
    echo "FORWARDING"
    echo "  Encaminhamentos aplicados : $applied_forwards"
    echo
    echo "Log:"
    echo "  $LOG_FILE"
    echo


    if [ "$DRY_RUN" -eq 1 ]; then

        warn "DRY-RUN: nenhuma alteração foi realizada."

    else

        ok "Migração de provisionamento concluída."

    fi
}


# =====================================================================
# RELATÓRIO
# =====================================================================

show_report()
{
    [ -d "$DATA_DIR" ] ||
        die "Diretório migration-data não encontrado."

    echo
    echo "================================================================="
    echo " RELATÓRIO DOS DADOS EXPORTADOS"
    echo "================================================================="
    echo

    echo "Domínios:"
    cat "$DOMAINS_FILE" 2>/dev/null || true

    echo
    echo "-----------------------------------------------------------------"
    echo "Contas:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            printf "%-40s  %s\n", $1, $4
        }
    ' "$ACCOUNTS_FILE" 2>/dev/null || true


    echo
    echo "-----------------------------------------------------------------"
    echo "Aliases:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            printf "%-40s -> %s\n", $2, $1
        }
    ' "$ALIASES_FILE" 2>/dev/null || true


    echo
    echo "-----------------------------------------------------------------"
    echo "Forwardings:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            if ($2 == "PREF") {

                localcopy="SIM"

                if (toupper($4) == "TRUE")
                    localcopy="NAO"

                printf "%-35s -> %-35s tipo=PREF copia-local=%s\n",
                       $1, $3, localcopy

            } else {

                printf "%-35s -> %-35s tipo=ADMIN\n",
                       $1, $3

            }
        }
    ' "$FORWARDING_FILE" 2>/dev/null || true


    echo
    echo "-----------------------------------------------------------------"
    echo "Listas:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            printf "%-40s %s\n", $1, $2
        }
    ' "$GROUPS_FILE" 2>/dev/null || true


    echo
    echo "-----------------------------------------------------------------"
    echo "Aliases das listas:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            printf "%-40s -> %s\n", $2, $1
        }
    ' "$GROUP_ALIASES_FILE" 2>/dev/null || true


    echo
    echo "-----------------------------------------------------------------"
    echo "Membros das listas:"
    echo "-----------------------------------------------------------------"

    awk -F'\t' '
        {
            printf "%-40s <- %s\n", $1, $2
        }
    ' "$GROUP_MEMBERS_FILE" 2>/dev/null || true

    echo
}


# =====================================================================
# TROCA OPCIONAL DE SENHAS LOCAIS NO CARBONIO
# =====================================================================

generate_account_password()
{
    local LC_ALL=C
    local pool='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%*_-'
    local candidate='' bytes byte
    local size=${#pool}
    local limit=$((256 / size * size))

    # Começar com letra evita fórmulas ao abrir a senha em uma planilha.
    # Rejeição evita viés na escolha dos caracteres; /dev/urandom fornece
    # aleatoriedade do sistema, sem usar RANDOM do Bash.
    while :; do
        bytes="$(od -An -v -tu1 -N64 /dev/urandom)" || return 1
        [ -n "$bytes" ] || return 1
        for byte in $bytes; do
            ((byte < limit)) || continue
            candidate+="${pool:byte % size:1}"
            if [ "${#candidate}" -eq 9 ]; then
                if [[ "$candidate" =~ ^[a-zA-Z] &&
                      "$candidate" =~ [a-z] && "$candidate" =~ [A-Z] &&
                      "$candidate" =~ [0-9] && "$candidate" =~ [!@#%*_-] ]]; then
                    printf '%s' "$candidate"
                    return 0
                fi
                candidate=''
            fi
        done
    done
}

password_csv_row()
{
    local account="$1" password="$2" status="$3"
    # Evita interpretar um endereço iniciado por operador como fórmula.
    case "$account" in [=+@-]*) account="'$account" ;; esac
    account="${account//\"/\"\"}"
    printf '"%s";"%s";"%s"\r\n' "$account" "$password" "$status"
}

password_csv_status()
{
    local csv="$1" row="$2" status="$3" temporary
    temporary="$(mktemp "${csv}.tmp.XXXXXX")" || return 1
    if ! awk -v row="$row" -v status="$status" '
        NR == row { sub(/"PENDENTE"\r?$/, "\"" status "\"\r") }
        { print }
    ' "$csv" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -f -- "$temporary" "$csv"
}

do_reset_passwords()
{
    # Não deixar bash -x registrar as senhas deste modo.
    set +x
    require_root
    id zextras >/dev/null 2>&1 || die "Execute este modo no Carbonio (usuário zextras ausente)."
    [ -s "$ACCOUNTS_FILE" ] || die "Arquivo de contas ausente ou vazio: $ACCOUNTS_FILE"

    local option
    for option in "$@"; do
        [ "$option" = '--dry-run' ] || die "Opção desconhecida: $option"
    done
    # Valida todo o arquivo antes de gerar senhas ou modificar contas.
    awk -F '\t' '
        NF != 5 || $1 !~ /^[^@[:space:]]+@[^@[:space:]]+$/ { bad=1 }
        END { exit bad }
    ' "$ACCOUNTS_FILE" || die "accounts.tsv inválido; gere uma exportação válida antes de trocar senhas."

    local listing account password csv='' row=1 failures=0 changed=0 index
    local -a accounts=() passwords=()
    listing="$(cut -f1 "$ACCOUNTS_FILE" | sort -u)" || die "Falha ao ler contas."
    while IFS= read -r account; do
        accounts+=("$account")
    done <<< "$listing"

    if [ "$DRY_RUN" -eq 1 ]; then
        for account in "${accounts[@]}"; do
            if account_exists "$account" </dev/null; then
                info "DRY-RUN: trocaria a senha local de $account"
            else
                error "DRY-RUN: conta ausente ou consulta falhou: $account"
                failures=$((failures + 1))
            fi
        done
        info "DRY-RUN: nenhuma senha gerada ou alterada; nenhum CSV criado."
        [ "$failures" -eq 0 ]
        return
    fi

    command -v od >/dev/null || die "Comando od não encontrado."
    [ -r /dev/urandom ] || die "/dev/urandom indisponível."
    csv="$(mktemp "${DATA_DIR}/senhas-${TIMESTAMP}-XXXXXX.csv")" || die "Não foi possível criar o CSV."
    chmod 600 "$csv" || die "Não foi possível restringir permissões do CSV."
    printf '\357\273\277"email";"senha";"status"\r\n' > "$csv" || die "Falha ao escrever CSV."

    for account in "${accounts[@]}"; do
        password="$(generate_account_password)" || die "Falha ao gerar senha; nenhuma conta alterada."
        passwords+=("$password")
        password_csv_row "$account" "$password" PENDENTE >> "$csv" ||
            die "Falha ao salvar senhas; nenhuma conta alterada."
    done

    info "CSV de senhas: $csv"
    for index in "${!accounts[@]}"; do
        account="${accounts[$index]}"
        password="${passwords[$index]}"
        row=$((index + 2))
        if ! account_exists "$account" </dev/null; then
            password_csv_status "$csv" "$row" FALHA_CONSULTA || die "Falha ao atualizar CSV; execução interrompida."
            error "Conta ausente ou consulta falhou: $account"
            failures=$((failures + 1))
            continue
        fi

        # Não registrar a saída do provisionamento: ela pode conter a senha.
        if carbonio_cmd sp "$account" "$password" </dev/null >/dev/null 2>&1; then
            password_csv_status "$csv" "$row" ALTERADA || die "Senha aplicada, mas CSV não atualizado para $account; verifique a linha PENDENTE."
            ok "Senha local alterada: $account"
            changed=$((changed + 1))
        else
            password_csv_status "$csv" "$row" FALHA_ALTERACAO || die "Falha ao atualizar CSV; execução interrompida."
            error "Troca não confirmada: $account (verifique a conta e a política de senhas)."
            failures=$((failures + 1))
        fi
    done
    unset password passwords
    info "Senhas confirmadas: $changed; falhas: $failures. CSV: $csv"
    [ "$failures" -eq 0 ]
}


# =====================================================================
# MIGRAÇÃO OPCIONAL DE MENSAGENS VIA IMAP
# =====================================================================

imap_install_help()
{
    cat <<'EOF'
Instale o imapsync somente na máquina que executará a migração.
Ubuntu 24.04 / Debian 13: consulte docs/IMAP.md (instalação e uso).

Nativo: dependências via apt e executável fornecido pelo autor:
  https://imapsync.lamiral.info/INSTALL.d/INSTALL.Ubuntu.txt
  https://imapsync.lamiral.info/INSTALL.d/INSTALL.Debian.txt
O autor também fornece https://imapsync.lamiral.info/dist2/imapsync.deb
Esse pacote externo é instalado com apt install ./imapsync.deb.

Docker em uma VM dedicada (se Docker já estiver instalado):
  docker pull gilleslamiral/imapsync:latest
  docker run --rm gilleslamiral/imapsync:latest imapsync --version
Depois use migrate-mail --engine docker.

Não é necessário Docker Compose, serviço web ou publicar portas.
O script não instala pacotes nem baixa imagens automaticamente.
EOF
}

imap_usage()
{
    cat <<'EOF'
Uso: bash migrate-zimbra-carbonio.sh migrate-mail [opções]
  --engine native|docker     Padrão: native
  --host1 HOST               Zimbra (nome presente no certificado TLS)
  --host2 HOST               Carbonio (nome presente no certificado TLS)
  --admin1 EMAIL             Administrador IMAP do Zimbra
  --admin2 EMAIL             Administrador IMAP do Carbonio
  --port1 PORT / --port2 PORT Padrão: 993, TLS implícito nos dois lados
  --account EMAIL            Somente esta conta, que deve constar em accounts.tsv
  --check-login              Testa autenticação; não copia mensagens
  --dry-run                  Simula sincronização; não copia mensagens
  --passfile1 ARQUIVO        Opcional: primeira linha contém a senha da origem
  --passfile2 ARQUIVO        Opcional: primeira linha contém a senha do destino
  --cafile1 PEM / --cafile2 PEM  CA privada para validar o TLS de cada lado
  --insecure1                Não valida o certificado do Zimbra (mantém TLS)
  --insecure2                Não valida o certificado do Carbonio (mantém TLS)
  --image IMAGEM             Docker; padrão: gilleslamiral/imapsync:latest
  --check-tool               Verifica somente executável/imagem e dependências
  --install-help             Mostra orientação de instalação
  --help                    Mostra esta ajuda
Sem hosts/administradores/senhas, esses dados são solicitados no terminal.
Sem --account, processa os endereços únicos de migration-data/accounts.tsv.
EOF
}

imap_prompt()
{
    local variable="$1" label="$2"
    read -r -p "$label" "$variable" </dev/tty || die "Não foi possível ler $label; informe pela opção correspondente."
    [ -n "${!variable}" ] || die "Valor vazio: $label"
}

imap_save_secret()
{
    local input="$1" output="$2" label="$3" secret=''
    if [ -n "$input" ]; then
        [ -f "$input" ] && [ -r "$input" ] || die "Arquivo de senha não pode ser lido: $input"
        IFS= read -r secret < "$input" || [ -n "$secret" ] || die "Arquivo de senha vazio: $input"
    else
        IFS= read -r -s -p "$label" secret </dev/tty || die "Não foi possível ler a senha; use --passfile1/--passfile2."
        printf '\n' >&2
    fi
    [ -n "$secret" ] && [[ "$secret" != *$'\r'* ]] || die "Senha vazia ou com CR; use arquivo com final de linha Linux (LF)."
    printf '%s\n' "$secret" > "$output" || die "Falha ao salvar credencial temporária."
    chmod 600 "$output" || die "Falha ao restringir a credencial temporária."
    unset secret
}

# Subshell mantém traps e variáveis exclusivos deste modo.
do_migrate_mail()
(
    set +x
    local engine=native host1='' host2='' admin1='' admin2='' port1=993 port2=993
    local selected='' passfile1='' passfile2='' image='gilleslamiral/imapsync:latest'
    local cafile1='' cafile2='' ca_path
    local verify1=1 verify2=1
    local check_login=0 dry=0 check_tool=0 value option binary image_id
    local run_dir='' secrets_dir='' active_pid='' container_name='' lock_fd
    local listing account index phase status code failures=0 total=0 summary logfile
    local -a runner=() connection=() accounts=() extra=()

    while [ "$#" -gt 0 ]; do
        option="$1"
        case "$option" in
            --help) imap_usage; exit 0 ;;
            --install-help) imap_install_help; exit 0 ;;
            --check-tool) check_tool=1; shift; continue ;;
            --check-login) check_login=1; shift; continue ;;
            --dry-run) dry=1; shift; continue ;;
            --insecure1) verify1=0; shift; continue ;;
            --insecure2) verify2=0; shift; continue ;;
            --engine|--host1|--host2|--admin1|--admin2|--port1|--port2|--account|--passfile1|--passfile2|--cafile1|--cafile2|--image)
                [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || die "Falta valor para $option"
                value="$2" ;;
            *) die "Opção desconhecida: $option. Use migrate-mail --help." ;;
        esac
        case "$option" in
            --engine) engine="$value" ;; --host1) host1="$value" ;; --host2) host2="$value" ;;
            --admin1) admin1="$value" ;; --admin2) admin2="$value" ;;
            --port1) port1="$value" ;; --port2) port2="$value" ;;
            --account) selected="$value" ;; --passfile1) passfile1="$value" ;;
            --passfile2) passfile2="$value" ;; --image) image="$value" ;;
            --cafile1) cafile1="$value" ;; --cafile2) cafile2="$value" ;;
        esac
        shift 2
    done
    [ "$check_login" -eq 0 ] || [ "$dry" -eq 0 ] || die "Escolha --check-login ou --dry-run."
    case "$engine" in
        native)
            binary="$(command -v imapsync)" || { imap_install_help; die "imapsync não encontrado no PATH."; }
            runner=("$binary") ;;
        docker)
            command -v docker >/dev/null || { imap_install_help; die "Docker não encontrado."; }
            docker info >/dev/null 2>&1 || die "Docker indisponível: verifique o serviço e a permissão de acesso."
            image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" ||
                { imap_install_help; die "Imagem ausente: $image. Faça o pull antes de executar."; }
            [ -n "$image_id" ] || die "Docker não retornou o identificador da imagem."
            runner=(docker run --rm --pull=never --network host --user "$(id -u):$(id -g)"
                --cap-drop ALL --security-opt no-new-privileges "$image_id" imapsync) ;;
        *) die "Engine inválido: use native ou docker." ;;
    esac
    "${runner[@]}" --version || { imap_install_help; die "imapsync não inicia; confira dependências/imagem."; }
    [ "$check_tool" -eq 0 ] || exit 0

    [ -s "$ACCOUNTS_FILE" ] || die "Arquivo ausente ou vazio: $ACCOUNTS_FILE"
    awk -F '\t' 'NF != 5 || $1 !~ /^[^@[:space:]]+@[^@[:space:]]+$/ { bad=1 } END { exit bad }' \
        "$ACCOUNTS_FILE" || die "accounts.tsv inválido."
    listing="$(cut -f1 "$ACCOUNTS_FILE" | sort -u)" || die "Falha ao ler contas."
    while IFS= read -r account; do
        if [ -z "$selected" ] || [ "$selected" = "$account" ]; then accounts+=("$account"); fi
    done <<< "$listing"
    [ "${#accounts[@]}" -gt 0 ] || die "A conta selecionada não consta em accounts.tsv."

    [ -n "$host1" ] || imap_prompt host1 'Servidor IMAP Zimbra: '
    [ -n "$host2" ] || imap_prompt host2 'Servidor IMAP Carbonio: '
    [ -n "$admin1" ] || imap_prompt admin1 'Administrador do Zimbra: '
    [ -n "$admin2" ] || imap_prompt admin2 'Administrador do Carbonio: '
    for value in "$host1" "$host2"; do
        [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || die "Host inválido: use nome/IP sem protocolo ou caminho."
    done
    for value in "$admin1" "$admin2"; do
        [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Administrador inválido: $value"
    done
    for value in "$port1" "$port2"; do
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) || die "Porta inválida: $value"
    done
    port1=$((10#$port1)); port2=$((10#$port2))
    [[ "${host1,,}:$port1" != "${host2,,}:$port2" ]] || die "Origem e destino são iguais."
    command -v flock >/dev/null || die "flock não encontrado (pacote util-linux)."
    exec {lock_fd}> "$DATA_DIR/.imap-migration.lock" || die "Não foi possível abrir o bloqueio."
    flock -n "$lock_fd" || die "Já existe uma migração IMAP usando esta pasta de dados."

    mkdir -p "$LOG_DIR" || die "Falha ao criar diretório de logs."
    run_dir="$(mktemp -d "$LOG_DIR/imap-${TIMESTAMP}-XXXXXX")" || die "Falha ao criar diretório da execução."
    container_name="migration-$(basename "$run_dir")-$$"
    imap_cleanup()
    {
        if [ -n "$active_pid" ]; then
            if [ "$engine" = docker ]; then docker stop -t 5 "$container_name" >/dev/null 2>&1 || true; fi
            kill "$active_pid" 2>/dev/null || true
            wait "$active_pid" 2>/dev/null || true
        fi
        # Remove somente os arquivos conhecidos da pasta criada por mktemp.
        if [ -n "$secrets_dir" ]; then
            rm -f -- "$secrets_dir/source" "$secrets_dir/destination" "$secrets_dir/ca1.pem" "$secrets_dir/ca2.pem"
            rmdir -- "$secrets_dir"
        fi
    }
    trap imap_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    secrets_dir="$(mktemp -d "${TMPDIR:-/tmp}/imap-credentials.XXXXXX")" || die "Falha ao criar pasta temporária de credenciais."
    imap_save_secret "$passfile1" "$secrets_dir/source" 'Senha administrativa do Zimbra: '
    imap_save_secret "$passfile2" "$secrets_dir/destination" 'Senha administrativa do Carbonio: '
    for index in 1 2; do
        option="cafile$index"
        if [ -n "${!option}" ]; then
            [ -f "${!option}" ] && [ -r "${!option}" ] || die "CA não pode ser lida: ${!option}"
            cp -- "${!option}" "$secrets_dir/ca$index.pem" || die "Falha ao copiar CA."
        fi
    done
    mkdir -p "$run_dir/tmp" || die "Falha ao criar diretório temporário."

    if [ "$engine" = docker ]; then
        runner=(docker run --rm --pull=never --name "$container_name" --network host
            --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges
            --mount "type=bind,src=$secrets_dir,dst=/credentials,readonly"
            --mount "type=bind,src=$run_dir/tmp,dst=/work" --workdir /work
            "$image_id" imapsync)
        connection=(--passfile1 /credentials/source --passfile2 /credentials/destination --tmpdir /work)
    else
        connection=(--passfile1 "$secrets_dir/source" --passfile2 "$secrets_dir/destination" --tmpdir "$run_dir/tmp")
    fi
    connection+=(--host1 "$host1" --port1 "$port1" --host2 "$host2" --port2 "$port2"
        --authuser1 "$admin1" --authuser2 "$admin2" --authmech1 PLAIN --authmech2 PLAIN
        --ssl1 --ssl2 --sslargs1 "SSL_verify_mode=$verify1" --sslargs2 "SSL_verify_mode=$verify2"
        --sslargs1 "SSL_verifycn_name=$host1" --sslargs2 "SSL_verifycn_name=$host2"
        --sslargs1 SSL_verifycn_scheme=imap --sslargs2 SSL_verifycn_scheme=imap
        --timeout1 120 --timeout2 120 --noreleasecheck --nolog)
    for index in 1 2; do
        if [ -f "$secrets_dir/ca$index.pem" ]; then
            ca_path="$secrets_dir/ca$index.pem"
            [ "$engine" != docker ] || ca_path="/credentials/ca$index.pem"
            connection+=("--sslargs$index" "SSL_ca_file=$ca_path")
        fi
    done

    summary="$run_dir/results.tsv"
    printf 'fase\tconta\tstatus\tcodigo\tlog\n' > "$summary" || die "Falha ao criar resumo."
    info "IMAP: $host1:$port1 -> $host2:$port2; ${#accounts[@]} conta(s); engine=$engine"
    info "Logs e resultados: $run_dir"
    [ "$verify1" -ne 0 ] || warn "Zimbra: validação do certificado desativada por --insecure1; TLS mantido."
    [ "$verify2" -ne 0 ] || warn "Carbonio: validação do certificado desativada por --insecure2; TLS mantido."
    if [ "$engine" = docker ]; then info "Imagem usada: $image_id"; fi

    imap_run_account()
    {
        local phase="$1" index="$2" account="$3" code
        shift 3
        logfile="$run_dir/$(printf '%05d' "$((index + 1))")-${phase}.log"
        "${runner[@]}" "${connection[@]}" --user1 "$account" --user2 "$account" "$@" \
            > "$logfile" 2>&1 </dev/null &
        active_pid=$!
        if wait "$active_pid"; then code=0; else code=$?; fi
        active_pid=''
        if [ "$code" -eq 0 ]; then status=OK; else status=FALHA; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$phase" "$account" "$status" "$code" "$(basename "$logfile")" >> "$summary" ||
            die "Falha ao registrar resultado; migração interrompida."
        if [ "$code" -eq 0 ]; then ok "$phase: $account"; else error "$phase: $account (código $code); consulte $logfile"; fi
        return "$code"
    }

    # Testar todas as contas selecionadas antes de permitir qualquer cópia.
    for index in "${!accounts[@]}"; do
        imap_run_account auth "$index" "${accounts[$index]}" --justlogin ||
            die "Autenticação falhou; nenhuma mensagem foi copiada nesta execução."
    done
    if [ "$check_login" -eq 1 ]; then
        ok "Autenticação validada nos dois lados; nenhuma mensagem copiada."
        exit 0
    fi
    phase=sync
    if [ "$dry" -eq 1 ]; then phase=dry-run; extra=(--dry); fi
    for index in "${!accounts[@]}"; do
        if imap_run_account "$phase" "$index" "${accounts[$index]}" "${extra[@]}"; then
            total=$((total + 1))
        else
            failures=$((failures + 1))
        fi
    done
    info "$phase: $total conta(s) sem erro; $failures falha(s). Resumo: $summary"
    [ "$failures" -eq 0 ]
)


# =====================================================================
# MAIN
# =====================================================================

MODE="${1:-}"

if [ "${2:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi


case "$MODE" in

    export)

        do_export
        ;;

    import)

        do_import
        ;;

    report)

        show_report
        ;;

    reset-passwords)

        do_reset_passwords "${@:2}"
        ;;

    migrate-mail)

        do_migrate_mail "${@:2}"
        ;;

    *)

        echo
        echo "Uso:"
        echo
        echo "  Exportar no Zimbra:"
        echo
        echo "    $0 export"
        echo
        echo
        echo "  Visualizar dados exportados:"
        echo
        echo "    $0 report"
        echo
        echo
        echo "  Simular importação no Carbonio:"
        echo
        echo "    $0 import --dry-run"
        echo
        echo
        echo "  Importar no Carbonio:"
        echo
        echo "    $0 import"
        echo

        echo "  Trocar senhas locais das contas de accounts.tsv no Carbonio:"
        echo
        echo "    $0 reset-passwords --dry-run"
        echo "    $0 reset-passwords"
        echo

        echo "  Migrar mensagens por IMAP (Zimbra -> Carbonio):"
        echo
        echo "    $0 migrate-mail --help"
        echo "    $0 migrate-mail --install-help"
        echo

        exit 1
        ;;

esac
