#!/bin/bash
# Ponto de entrada opcional; mantenha os três scripts no mesmo diretório.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

run_script() {
    local script=$1 status
    shift
    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        echo "Arquivo não encontrado: $SCRIPT_DIR/$script" >&2
        return
    fi
    bash "$SCRIPT_DIR/$script" "$@"
    status=$?
    if (( status != 0 )); then
        echo "A execução terminou com erro (código $status). Revise as mensagens acima." >&2
    fi
}

while true; do
    cat <<'MENU'

Zimbra → Carbonio
Execute as opções no servidor indicado. Migração requer root.
 1) Zimbra: exportar provisionamento
 2) Revisar relatório dos arquivos exportados
 3) Carbonio: simular importação
 4) Carbonio: importar provisionamento
 5) Carbonio: simular troca de senhas locais
 6) Carbonio: trocar senhas locais das contas importadas
 7) Migrar mensagens por IMAP
 8) Carbonio: configurar limites de anexos e mensagens
 9) Simular configuração de limites
 0) Sair
MENU
    read -r -p 'Opção: ' option || exit 0
    case "$option" in
        1) run_script migrate-zimbra-carbonio.sh export ;;
        2) run_script migrate-zimbra-carbonio.sh report ;;
        3) run_script migrate-zimbra-carbonio.sh import --dry-run ;;
        4) run_script migrate-zimbra-carbonio.sh import ;;
        5) run_script migrate-zimbra-carbonio.sh reset-passwords --dry-run ;;
        6) run_script migrate-zimbra-carbonio.sh reset-passwords ;;
        7)
            read -r -p 'Motor IMAP: 1) Docker [padrão]  2) Nativo: ' engine || exit 0
            case "$engine" in
                1|'') engine=docker ;;
                2) engine=native ;;
                *) echo 'Motor inválido.'; continue ;;
            esac
            echo '1) Ajuda de instalação  2) Verificar ferramenta  3) Verificar login'
            echo '4) Simular migração  5) Executar migração  0) Voltar'
            read -r -p 'Opção IMAP: ' action || exit 0
            case "$action" in
                1) run_script migrate-zimbra-carbonio.sh migrate-mail --install-help ;;
                2) run_script migrate-zimbra-carbonio.sh migrate-mail --engine "$engine" --check-tool ;;
                3) run_script migrate-zimbra-carbonio.sh migrate-mail --engine "$engine" --check-login ;;
                4) run_script migrate-zimbra-carbonio.sh migrate-mail --engine "$engine" --dry-run ;;
                5) run_script migrate-zimbra-carbonio.sh migrate-mail --engine "$engine" ;;
                0) ;;
                *) echo 'Opção inválida.' ;;
            esac
            ;;
        8) run_script configure-carbonio.sh ;;
        9) run_script configure-carbonio.sh --dry-run ;;
        0) exit 0 ;;
        *) echo 'Opção inválida.' ;;
    esac
done
