#!/bin/bash
# Configurador independente: execute no servidor Carbonio como root ou zextras.
set -euo pipefail

dry_run=0
case "${1:-}" in
    --dry-run) dry_run=1 ;;
    -h|--help)
        echo 'Uso: bash configure-carbonio.sh [--dry-run]'
        echo 'Menu para consultar ou configurar limites de anexos e mensagens.'
        exit 0 ;;
    '') ;;
    *) echo 'Argumento inválido. Use --help.' >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo 'Argumentos em excesso.' >&2; exit 1; }

prov() {
    local cmd
    if [[ $(id -u) == 0 ]]; then
        printf -v cmd '%q ' carbonio prov "$@"
        su - zextras -c "$cmd"
    elif [[ $(id -un) == zextras ]]; then
        carbonio prov "$@"
    else
        echo 'Execute como root ou zextras no servidor Carbonio.' >&2
        return 1
    fi
}

show_current() {
    echo 'Limites configurados (bytes):'
    prov gc default zimbraFileUploadMaxSizePerFile || return 1
    prov gacf zimbraFileUploadMaxSize zimbraMtaMaxMessageSize || return 1
}

read_mb() {
    local label=$1 default=$2 value
    while true; do
        read -r -p "$label [$default]: " value || return 1
        value=${value:-$default}
        if [[ $value =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 2047 )); then
            REPLY=$value
            return 0
        fi
        echo 'Informe um número inteiro entre 1 e 2047, sem zeros à esquerda.'
    done
}

apply_limits() {
    local per_file=$1 general=$2 answer spec output attribute expected
    local -a args
    per_file=$((per_file * 1024 * 1024))
    general=$((general * 1024 * 1024))
    local -a commands=(
        "mc default zimbraFileUploadMaxSizePerFile $per_file"
        "mcf zimbraFileUploadMaxSize $general"
        "mcf zimbraMtaMaxMessageSize $general"
    )
    echo 'Comandos propostos:'
    printf 'carbonio prov %s\n' "${commands[@]}"
    echo 'O limite por arquivo será aplicado à COS default; os outros dois são globais.'
    if (( dry_run )); then
        echo '[DRY-RUN] Nenhuma alteração realizada.'
        return 0
    fi
    show_current || return 1
    read -r -p 'Aplicar estes limites? [s/N]: ' answer || return 1
    case "$answer" in s|S|sim|SIM) ;; *) echo 'Cancelado.'; return 0 ;; esac
    for spec in "${commands[@]}"; do
        read -r -a args <<< "$spec"
        if ! prov "${args[@]}"; then
            echo "Falha em: carbonio prov $spec" >&2
            echo 'Interrompido. Comandos anteriores podem ter sido aplicados; consulte os limites antes de tentar novamente.' >&2
            return 1
        fi
    done
    for attribute in zimbraFileUploadMaxSizePerFile zimbraFileUploadMaxSize zimbraMtaMaxMessageSize; do
        expected=$general
        if [[ $attribute == zimbraFileUploadMaxSizePerFile ]]; then
            expected=$per_file
            output=$(prov gc default "$attribute") || return 1
        else
            output=$(prov gacf "$attribute") || return 1
        fi
        if ! grep -Eq "^[[:space:]]*$attribute:[[:space:]]*$expected[[:space:]]*$" <<< "$output"; then
            echo "Não foi possível confirmar $attribute=$expected. Verifique a configuração; alterações podem ter sido aplicadas." >&2
            return 1
        fi
    done
    echo 'Limites gravados e confirmados no provisionamento.'
    echo 'Valide upload e envio em uma conta de teste para conferir os limites efetivos.'
}

while true; do
    printf '\nConfiguração do Carbonio — anexos e mensagens\n'
    echo '1) Consultar limites atuais'
    echo '2) Aplicar sugestão: 20 MB por arquivo / 30 MB geral e mensagem'
    echo '3) Personalizar limites'
    echo '0) Sair'
    echo 'MB neste menu = 1024 × 1024 bytes (MiB).'
    read -r -p 'Opção: ' option || exit 0
    case "$option" in
        1) show_current ;;
        2) apply_limits 20 30 ;;
        3)
            read_mb 'Limite por arquivo em MB' 20
            per_file_mb=$REPLY
            read_mb 'Limite geral de upload e mensagem em MB' 30
            general_mb=$REPLY
            if (( general_mb < per_file_mb )); then
                echo 'O limite geral deve ser maior ou igual ao limite por arquivo.'
                continue
            fi
            apply_limits "$per_file_mb" "$general_mb"
            ;;
        0) exit 0 ;;
        *) echo 'Opção inválida.' ;;
    esac
done
