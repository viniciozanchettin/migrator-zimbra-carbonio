# Migração de Provisionamento — Zimbra 8.8.15 → Carbonio 26

Licenciado sob a [licença MIT](LICENSE). Uso, modificação e distribuição
permitidos, inclusive para fins comerciais, conforme os termos da licença.

Este projeto contém um script para auxiliar na migração do **provisionamento** de um servidor Zimbra 8.8.15 para Carbonio 26.

O script utiliza:

* `zmprov` no servidor Zimbra;
* `carbonio prov` no servidor Carbonio.

> **Importante:** os modos `export` e `import` migram a estrutura das contas.
> Para copiar mensagens e pastas, use o modo independente `migrate-mail`,
> descrito no [manual de migração IMAP](docs/IMAP.md).

---

## 1. O que é migrado

O script exporta e recria:

* Contas de e-mail;
* Nome (`givenName`);
* Sobrenome (`sn`);
* Nome de exibição (`displayName`);
* Vínculo individual com Active Directory (`zimbraAuthLdapExternalDn`);
* Aliases das contas;
* Listas/grupos de distribuição;
* Aliases das listas de distribuição;
* Membros das listas de distribuição;
* Encaminhamentos de e-mail;
* Configuração para manter ou não uma cópia da mensagem na caixa original.

Também é gerada uma lista dos domínios encontrados no Zimbra.

Os domínios **não são criados automaticamente no Carbonio**.

---

## 2. O que NÃO é migrado

Os modos de provisionamento (`export` e `import`) não migram:

* Mensagens de e-mail;
* Pastas das caixas postais;
* Contatos;
* Calendários;
* Senhas atuais dos usuários;
* COS;
* Quotas;
* Configuração global do servidor;
* Configuração completa do Active Directory;
* Regras/filtros pessoais das caixas;
* Assinaturas;
* Preferências do Webmail.

A migração das mensagens pode ser realizada separadamente com `migrate-mail`.
Contatos, calendários e outros dados não expostos por IMAP precisam de outro processo.

---

# 3. Contas internas ignoradas

O script tenta ignorar automaticamente contas internas utilizadas pelo Zimbra, incluindo:

```text
galsync
galsync-*
spam
spam-*
ham
ham-*
quarantine
quarantine-*
virus-quarantine
virus-quarantine-*
amavis
amavis-*
```

Essas contas não devem ser recriadas como usuários comuns no Carbonio.

---

# 4. Exclusões personalizadas

Além das contas internas, é possível informar manualmente contas que não deverão ser migradas.

O script cria:

```text
migration-data/excluded-accounts.txt
```

Exemplo:

```text
# Contas que não serão migradas

admin@empresa.com.br
teste@empresa.com.br
sistema-antigo@empresa.com.br
```

Linhas iniciadas por `#` são comentários.

É recomendável revisar esse arquivo antes da exportação definitiva.

---

# 5. Estrutura gerada

Após a exportação:

```text
migration-data/
├── accounts.tsv
├── aliases.tsv
├── forwarding.tsv
├── groups.tsv
├── group-aliases.tsv
├── group-members.tsv
├── domains.txt
├── excluded-accounts.txt
└── logs/
```

## accounts.tsv

Contém as contas que serão criadas.

Campos:

```text
email
givenName
sn
displayName
zimbraAuthLdapExternalDn
```

Exemplo:

```text
joao@empresa.com.br    João    Silva    João Silva    CN=Joao Silva,OU=Usuarios,DC=empresa,DC=local
```

---

## aliases.tsv

Contém os aliases associados às contas.

Exemplo:

```text
joao@empresa.com.br    comercial@empresa.com.br
```

Durante a importação será equivalente a:

```bash
carbonio prov aaa \
    joao@empresa.com.br \
    comercial@empresa.com.br
```

---

## domains.txt

Lista os domínios existentes no Zimbra.

Exemplo:

```text
empresa.com.br
empresa2.com.br
```

### IMPORTANTE

O script **não cria esses domínios no Carbonio**.

Eles deverão existir antes da importação.

O script verifica todos eles antes de começar. Se algum domínio estiver faltando, a importação é interrompida antes da criação das contas.

---

# 6. Active Directory

O script exporta o atributo:

```text
zimbraAuthLdapExternalDn
```

Exemplo:

```text
CN=Joao Silva,OU=Usuarios,DC=empresa,DC=local
```

Durante a importação será aplicado individualmente:

```bash
carbonio prov ma \
    joao@empresa.com.br \
    zimbraAuthLdapExternalDn \
    "CN=Joao Silva,OU=Usuarios,DC=empresa,DC=local"
```

Isso preserva o vínculo individual entre a conta de e-mail e o objeto correspondente no Active Directory.

## Atenção

O script **não configura a conexão do domínio com o Active Directory**.

Portanto, antes da migração, o administrador deverá configurar no Carbonio:

* servidor LDAP/AD;
* Base DN;
* método de autenticação;
* filtros necessários;
* demais parâmetros do Active Directory.

Depois disso, o script aplica o `External DN` de cada usuário.

---

# 7. Senhas das contas

As senhas atuais dos usuários **não são exportadas do Zimbra**.

Durante:

```bash
./migrate-zimbra-carbonio.sh import
```

será solicitado:

```text
Senha local padrão para TODAS as contas:
Confirme a senha:
```

Essa senha será utilizada para criar todas as contas.

Ela:

* não é gravada em `accounts.tsv`;
* não é colocada diretamente no script;
* é digitada de forma oculta;
* não fica exposta no histórico do shell pelo próprio comando de importação.

Em um ambiente com autenticação AD, o acesso normal dos usuários poderá utilizar a senha do Active Directory, de acordo com a configuração de autenticação realizada no Carbonio.

---

# 8. Listas de distribuição

As listas de distribuição existentes são exportadas para:

```text
groups.tsv
```

Exemplo:

```text
financeiro@empresa.com.br    Financeiro
diretoria@empresa.com.br     Diretoria
```

Durante a importação serão criadas utilizando o provisionamento do Carbonio.

---

# 9. Membros das listas

Os membros são armazenados em:

```text
group-members.tsv
```

Exemplo:

```text
financeiro@empresa.com.br    joao@empresa.com.br
financeiro@empresa.com.br    maria@empresa.com.br
financeiro@empresa.com.br    diretor@empresa.com.br
```

Depois da criação das listas, os membros são adicionados.

Exemplo conceitual:

```bash
carbonio prov adlm \
    financeiro@empresa.com.br \
    joao@empresa.com.br
```

---

# 10. Aliases das listas de distribuição

Listas também podem possuir aliases.

Eles são armazenados em:

```text
group-aliases.tsv
```

Exemplo:

```text
financeiro@empresa.com.br    contas@empresa.com.br
```

Durante a importação, o alias será associado à lista correspondente.

---

# 11. Encaminhamento de e-mails

Os encaminhamentos encontrados nas contas são armazenados em:

```text
forwarding.tsv
```

O script diferencia dois tipos.

## PREF

Forward configurado através das preferências da conta.

Exemplo:

```text
financeiro@empresa.com.br    PREF    diretor@empresa.com.br    FALSE
```

O último campo representa:

```text
zimbraPrefMailLocalDeliveryDisabled
```

### FALSE

Significa:

```text
Recebe mensagem
       │
       ├──► Caixa original
       │
       └──► Endereço de forwarding
```

Ou seja:

**encaminha e mantém uma cópia na caixa original.**

### TRUE

Significa:

```text
Recebe mensagem
       │
       └──► Endereço de forwarding

       X Caixa original
```

Ou seja:

**encaminha e não mantém a mensagem na caixa original.**

---

# 12. Forward administrativo

O script também procura:

```text
zimbraMailForwardingAddress
```

Esse atributo pode possuir múltiplos destinos.

Exemplo:

```text
usuario@empresa.com.br    ADMIN    auditoria@empresa.com.br    -
usuario@empresa.com.br    ADMIN    arquivo@empresa.com.br      -
```

Na importação, cada destino é adicionado ao atributo multivalorado sem substituir os demais.

---

# 13. Ordem da importação

A importação foi organizada para evitar dependências inexistentes.

A sequência é:

```text
VALIDAÇÃO
    │
    └── Verifica todos os domínios
              │
              ▼
1. Cria contas
              │
              ▼
2. Aplica vínculo individual AD
              │
              ▼
3. Adiciona aliases das contas
              │
              ▼
4. Cria listas de distribuição
              │
              ▼
5. Adiciona aliases das listas
              │
              ▼
6. Adiciona membros das listas
              │
              ▼
7. Configura forwarding
```

O forwarding fica por último propositalmente.

Dessa maneira, contas, aliases e listas já deverão existir quando os encaminhamentos forem configurados.

---

# 14. Procedimento de migração

## ETAPA 1 — Copiar o script para o Zimbra

Exemplo:

```bash
mkdir -p /root/zimbra-carbonio-migration
cd /root/zimbra-carbonio-migration
```

Coloque neste diretório:

```text
migrate-zimbra-carbonio.sh
```

Dê permissão:

```bash
chmod 700 migrate-zimbra-carbonio.sh
```

O arquivo `.sh` deve começar diretamente com `#!/bin/bash`. Não copie para
ele as marcações de bloco de código (três crases, com ou sem `bash`) exibidas
em respostas do ChatGPT. Essas marcações podem fazer o Bash abrir outro shell,
que só retorna ao terminal anterior após `exit`, em vez de executar a migração.

Salve o script com finais de linha Linux (LF). Para verificar a sintaxe antes
de executar:

```bash
bash -n migrate-zimbra-carbonio.sh
```

Se não aparecer nenhuma mensagem, a verificação de sintaxe passou. Execute o
arquivo com o argumento da etapa desejada, por exemplo
`./migrate-zimbra-carbonio.sh export`, sem usar `source` ou apenas `bash`.

---

# 15. Exportação inicial

Execute:

```bash
./migrate-zimbra-carbonio.sh export
```

O script utilizará:

```bash
su - zimbra -c 'zmprov -l gaa'
```

para consultar a configuração.

A listagem de contas utiliza o modo LDAP (`-l`), exigido pelo comando `gaa`.
As listagens de domínios, contas e listas são verificadas antes de substituir
os arquivos da exportação anterior. Se uma consulta falhar ou retornar texto
inválido, como a ajuda do `zmprov`, o script interrompe a exportação e registra
o problema no log.

Se uma versão anterior gravou mensagens de ajuda em `accounts.tsv`, substitua
o script pela versão corrigida e execute `export` novamente. Essa execução
regenera os arquivos de dados, mantendo `excluded-accounts.txt`. Revise com
`report` antes de copiar para o Carbonio; não importe o arquivo com erros.

Ao terminar será exibido um resumo semelhante a:

```text
EXPORTAÇÃO CONCLUÍDA

Contas exportadas ..........: 145
Contas ignoradas ...........: 5
Aliases de contas ..........: 18
Forwardings ................: 12

Listas de distribuição .....: 25
Aliases de listas ..........: 3
Membros de listas ..........: 184

Domínios ...................: 2
```

---

# 16. Revisar o relatório

Antes de levar os dados para o Carbonio:

```bash
./migrate-zimbra-carbonio.sh report
```

O relatório mostra:

* domínios;
* contas;
* aliases;
* forwardings;
* listas;
* aliases das listas;
* membros.

Dê atenção especial a:

```text
Forwardings
```

e:

```text
Membros das listas
```

---

# 17. Revisão manual recomendada

Confira diretamente os arquivos:

```bash
less migration-data/accounts.tsv
```

```bash
less migration-data/aliases.tsv
```

```bash
less migration-data/forwarding.tsv
```

```bash
less migration-data/groups.tsv
```

```bash
less migration-data/group-aliases.tsv
```

```bash
less migration-data/group-members.tsv
```

```bash
cat migration-data/domains.txt
```

Também é útil verificar a quantidade:

```bash
wc -l migration-data/*.tsv
```

---

# 18. Copiar para o Carbonio

Copie:

```text
migrate-zimbra-carbonio.sh
migration-data/
```

para o novo servidor.

Exemplo com SCP:

```bash
scp -r \
    migrate-zimbra-carbonio.sh \
    migration-data \
    root@SERVIDOR-CARBONIO:/root/zimbra-carbonio-migration/
```

---

# 19. Criar os domínios no Carbonio

Antes da importação, consulte:

```bash
cat migration-data/domains.txt
```

Todos os domínios deverão ser criados/configurados manualmente no Carbonio.

O script **não cria domínios**.

Também configure a autenticação com Active Directory antes da migração definitiva.

---

# 20. DRY-RUN

Esta etapa é fortemente recomendada.

Execute:

```bash
./migrate-zimbra-carbonio.sh import --dry-run
```

Nenhuma alteração deverá ser realizada no Carbonio.

O objetivo é visualizar comandos como:

```text
[DRY-RUN] carbonio prov ca joao@empresa.com.br ...
[DRY-RUN] carbonio prov ma joao@empresa.com.br ...
[DRY-RUN] carbonio prov aaa ...
[DRY-RUN] carbonio prov cdl ...
[DRY-RUN] carbonio prov adlm ...
```

Revise a saída antes da execução real.

---

# 21. Importação definitiva

Quando estiver satisfeito com a validação:

```bash
./migrate-zimbra-carbonio.sh import
```

Será solicitada a senha local padrão:

```text
Senha local padrão para TODAS as contas:
Confirme a senha:
```

Depois disso, o processo será executado.

---

# 22. Contas já existentes

Se uma conta já existir no Carbonio, o script não tenta recriá-la.

Será exibido:

```text
[WARN] Conta já existe: usuario@empresa.com.br
```

As etapas posteriores ainda poderão aplicar configurações como:

* vínculo AD;
* aliases;
* forwarding.

Isso é útil quando algumas contas já foram criadas manualmente antes da migração.

---

# 23. Listas já existentes

Da mesma forma, se uma lista já existir:

```text
[WARN] Lista já existe: financeiro@empresa.com.br
```

o script não tenta recriá-la.

As etapas posteriores ainda poderão tentar adicionar aliases e membros.

---

# 24. Logs

Cada execução gera um log em:

```text
migration-data/logs/
```

Exemplo:

```text
migration-data/logs/migration-20260912-170500.log
```

Para acompanhar:

```bash
tail -f migration-data/logs/migration-*.log
```

Ou:

```bash
less migration-data/logs/migration-20260912-170500.log
```

---

# 25. Validação após importação

Após a migração, confira inicialmente as contas:

```bash
su - zextras -c "carbonio prov gaa"
```

Uma conta específica:

```bash
su - zextras -c \
'carbonio prov ga usuario@empresa.com.br'
```

Confira especialmente:

```text
displayName
givenName
sn
zimbraAuthLdapExternalDn
zimbraMailAlias
zimbraPrefMailForwardingAddress
zimbraPrefMailLocalDeliveryDisabled
zimbraMailForwardingAddress
```

---

# 26. Validar Active Directory

Escolha algumas contas de teste.

Confira:

```bash
su - zextras -c \
'carbonio prov ga usuario@empresa.com.br zimbraAuthLdapExternalDn'
```

Depois faça login no Carbonio utilizando:

```text
usuário do e-mail
+
senha atual do Active Directory
```

Teste pelo menos usuários localizados em OUs diferentes no AD, caso existam.

---

# 27. Validar aliases

Teste:

```bash
su - zextras -c \
'carbonio prov ga usuario@empresa.com.br zimbraMailAlias'
```

Depois envie uma mensagem para um alias e confirme que ela chega à caixa correta.

---

# 28. Validar listas de distribuição

Confira uma lista:

```bash
su - zextras -c \
'carbonio prov gdl financeiro@empresa.com.br'
```

Verifique:

* endereço;
* display name;
* aliases;
* membros.

Depois envie uma mensagem de teste para a lista.

---

# 29. Validar forwarding

Para uma conta com forwarding:

```bash
su - zextras -c \
'carbonio prov ga usuario@empresa.com.br'
```

Confira:

```text
zimbraPrefMailForwardingAddress
zimbraPrefMailLocalDeliveryDisabled
zimbraMailForwardingAddress
```

Faça testes separados para:

### Forward mantendo original

Resultado esperado:

```text
Mensagem
   ├── Caixa original
   └── Destino
```

### Forward sem manter original

Resultado esperado:

```text
Mensagem
   └── Destino
```

A caixa original não deverá receber a mensagem.

---

# 30. Checklist antes do corte

Antes de alterar MX/DNS ou colocar o Carbonio em produção, confirme:

* [ ] Todos os domínios foram criados;
* [ ] Autenticação AD configurada;
* [ ] Contas importadas;
* [ ] Login AD testado;
* [ ] Aliases importados;
* [ ] Listas criadas;
* [ ] Membros das listas conferidos;
* [ ] Aliases das listas conferidos;
* [ ] Forwardings conferidos;
* [ ] Forward com cópia local testado;
* [ ] Forward sem cópia local testado;
* [ ] Envio interno testado;
* [ ] Envio externo testado;
* [ ] Recebimento externo testado;
* [ ] Logs da importação revisados;
* [ ] Migração das mensagens planejada/concluída;
* [ ] Backup/snapshot realizado antes do corte.

---

# 31. Segurança

A pasta:

```text
migration-data/
```

contém informações sobre:

* contas;
* aliases;
* estrutura de grupos;
* membros;
* forwarding;
* Distinguished Names do Active Directory.

Portanto, deve ser tratada como informação sensível.

O `.gitignore` exclui `migration-data/`, CSVs/TSVs, logs, arquivos de chaves,
credenciais locais e arquivos compactados. O CSV `senhas-*.csv` contém senhas
em texto legível e também não deve ser publicado. Guarde arquivos usados com
`--passfile1` e `--passfile2` fora do repositório ou dentro de `secrets/`, que
é ignorada; nomes arbitrários em outras pastas podem não ser cobertos.

Antes de publicar, revise `git status --short` e `git diff --cached` depois de
adicionar os arquivos. O `.gitignore` não remove arquivos já versionados nem
segredos do histórico. Nome e e-mail de autoria dos commits também ficam
visíveis em um repositório público. Os endereços e dados dos exemplos deste
manual devem ser substituídos apenas nas cópias locais usadas na migração.

As permissões são restringidas pelo script através de:

```bash
umask 077
```

Mesmo assim, recomenda-se:

```bash
chmod -R go-rwx migration-data
```

Não coloque esses arquivos em:

* Git público;
* GitHub;
* compartilhamentos abertos;
* diretórios web;
* armazenamento sem controle de acesso.

Após a conclusão e validação da migração, arquive de forma segura ou remova os dados temporários conforme a política da empresa.

---

# 32. O que fazer depois

Os modos `export` e `import` resolvem a parte de **provisionamento**.
O modo opcional `migrate-mail` acrescenta a cópia de mensagens e pastas IMAP.

A migração completa ainda possui uma segunda etapa:

```text
ZIMBRA
   │
   ├── Provisionamento ───────► ESTE SCRIPT
   │
   └── Dados das caixas
           │
           ├── E-mails
           ├── Pastas
           ├── Contatos
           └── Calendários
                    │
                    ▼
                 CARBONIO
```

Não desative o Zimbra antigo imediatamente após importar o provisionamento.

Primeiro migre os dados, valide as caixas e faça os testes de fluxo de e-mail.

---

# 33. Sequência resumida

## No Zimbra

```bash
chmod 700 migrate-zimbra-carbonio.sh

./migrate-zimbra-carbonio.sh export

./migrate-zimbra-carbonio.sh report
```

Revisar:

```bash
less migration-data/accounts.tsv
less migration-data/aliases.tsv
less migration-data/forwarding.tsv
less migration-data/groups.tsv
less migration-data/group-aliases.tsv
less migration-data/group-members.tsv
cat migration-data/domains.txt
```

## No Carbonio

Criar os domínios e configurar o AD.

Depois:

```bash
chmod 700 migrate-zimbra-carbonio.sh

./migrate-zimbra-carbonio.sh import --dry-run
```

Revisar cuidadosamente.

Finalmente:

```bash
./migrate-zimbra-carbonio.sh import
```

Depois da importação:

1. Validar contas;
2. Validar login AD;
3. Validar aliases;
4. Validar grupos;
5. Validar membros;
6. Validar forwarding;
7. Migrar os dados das caixas postais;
8. Realizar testes de envio e recebimento;
9. Somente então planejar o corte definitivo.

---

# 34. Trocar senhas locais das contas importadas (opcional)

Este modo é independente de `export`, `import` e `report`: somente é executado
quando você chama `reset-passwords`. Não é necessário importar novamente.
Copie apenas o script atualizado para o Carbonio e mantenha `migration-data`
ao lado dele. A pasta `tests` não precisa ser copiada.

O modo utiliza os endereços de `migration-data/accounts.tsv`, sem consultar uma
listagem global para alterar todas as contas do servidor. Endereços duplicados
são processados uma vez. A conta precisa existir no Carbonio; uma conta que
falhou na importação não será criada por este modo. Contas que já existiam e
constam nesse arquivo também terão a senha trocada. Revise a lista antes de usar.

Como root, no Carbonio, simule:

```bash
./migrate-zimbra-carbonio.sh reset-passwords --dry-run
```

A simulação verifica as contas, sem gerar senhas, criar CSV ou alterar senhas.
Para realizar a troca:

```bash
./migrate-zimbra-carbonio.sh reset-passwords
```

A execução real começa diretamente. Cada conta recebe uma senha aleatória com:

* exatamente **9 caracteres**;
* pelo menos uma letra minúscula e uma maiúscula;
* pelo menos um número;
* pelo menos um símbolo entre `!@#%*_-`;
* uma letra na primeira posição, para facilitar o uso em planilhas.

A geração usa `/dev/urandom`. O modo requer os utilitários Linux `od`, `awk`,
`cut`, `sort` e `mktemp`, além do provisionamento do Carbonio.
A troca utiliza `carbonio prov sp`, conforme a
[documentação oficial do Carbonio](https://docs.zextras.com/carbonio/html/install/post-install/web-access.html#set-or-change-password).

**São senhas locais do Carbonio.** As senhas do Active Directory não são
alteradas, nem a configuração de autenticação do domínio. Se uma política do
Carbonio não aceitar senhas com essas características, a troca pode falhar.

## CSV para Excel e Google Sheets

Cada execução real cria um arquivo exclusivo, sem sobrescrever CSVs anteriores:

```text
migration-data/senhas-AAAAMMDD-HHMMSS-XXXXXX.csv
```

O caminho completo aparece no terminal. O CSV usa UTF-8 com BOM, separador
**ponto e vírgula (`;`)**, finais de linha CRLF e as colunas `email`, `senha` e
`status`. No Excel ou Google Sheets, importe o arquivo escolhendo `;` como
separador e mantendo e-mail e senha como texto.

| Status | Significado |
| --- | --- |
| `ALTERADA` | O comando de troca retornou sucesso; esta é a nova senha local. |
| `FALHA_CONSULTA` | A conta não foi encontrada ou a consulta falhou; não foi tentada a troca. |
| `FALHA_ALTERACAO` | A troca foi tentada, mas não houve confirmação de sucesso; verifique no servidor. |
| `PENDENTE` | Não há resultado registrado; se houve interrupção, a troca pode não ter sido iniciada ou pode ter ocorrido antes da atualização do CSV. |

Distribua somente as senhas das linhas com status `ALTERADA`. Nas outras linhas,
a senha é uma candidata gerada, sem confirmação de que esteja aplicada.

As senhas são gravadas no CSV **antes de começar as alterações**, e o status é
atualizado após cada resultado. Se o script for interrompido, preserve esse
arquivo e confira as linhas pendentes. Executar o modo novamente gera novas
senhas e tenta trocar todas as contas da lista outra vez; não é uma retomada.

Havendo falhas, o script continua nas demais contas, informa as quantidades e
termina com código diferente de zero. Se não conseguir atualizar o CSV, ele
interrompe a execução. Mensagens brutas do comando de troca não são gravadas no
terminal ou no log, pois podem conter senhas.

O CSV contém senhas em texto legível, com permissão `600` (somente o proprietário
pode ler e escrever). Guarde-o em local restrito e compartilhe apenas com quem
deve ter acesso às credenciais.

---

# Menu principal e configurador de anexos

Para acessar as etapas pelo menu, mantenha `menu.sh`, `configure-carbonio.sh`
e `migrate-zimbra-carbonio.sh` no mesmo diretório e execute:

```bash
bash menu.sh
```

O menu reúne exportação, relatório, importação, troca de senhas, migração IMAP
(Docker ou nativa) e configuração dos limites, com opções de simulação.
Execute a exportação no Zimbra e a importação/configuração no Carbonio.
As opções de execução real iniciam a etapa selecionada e mantêm as perguntas
do script original. Ao terminar, o menu reaparece, inclusive em caso de erro.

## Configurador de anexos e mensagens no Carbonio

Copie também `configure-carbonio.sh` para o servidor Carbonio. Ele é independente
do script de migração e pode ser executado como **root** ou **zextras**:

```bash
bash configure-carbonio.sh
```

O menu permite consultar os limites atuais, aplicar a sugestão **20 MB por
arquivo / 30 MB geral e mensagem**, personalizar os dois valores ou sair.
Antes de aplicar, mostra os comandos e os valores atuais e solicita confirmação.
A sugestão executa exatamente:

```bash
carbonio prov mc default zimbraFileUploadMaxSizePerFile 20971520
carbonio prov mcf zimbraFileUploadMaxSize 31457280
carbonio prov mcf zimbraMtaMaxMessageSize 31457280
```

Para simular, sem alterar configurações (selecione a opção 2 ou 3):

```bash
bash configure-carbonio.sh --dry-run
```

O menu usa MB como 1024 × 1024 bytes (MiB), seguindo os valores acima.
O limite por arquivo é aplicado à COS `default`; contas com outra COS ou
configurações individuais podem ter limites diferentes. Os outros dois limites
são globais. Configurações específicas dos servidores também devem ser revisadas
se o limite efetivo continuar diferente.

O limite da mensagem inclui conteúdo e codificação dos anexos, portanto 30 MB
de mensagem não equivalem a 30 MB de arquivos anexados. Consulte a
[documentação de anexos do Carbonio](https://docs.zextras.com/carbonio-ce/html/admincli/management/attachments.html).

Após aplicar, o configurador consulta o provisionamento para confirmar os valores.
Ele não reinicia serviços. Faça um teste de upload, envio e migração na conta
de teste para validar o comportamento efetivo. Se um comando falhar, a execução
para e informa o erro; alterações anteriores não são desfeitas automaticamente.

---

# 35. Migração de mensagens por IMAP

O novo modo `migrate-mail` funciona com imapsync nativo ou Docker e usa
administradores de origem e destino para acessar as contas de `accounts.tsv`.
Consulte o [manual de instalação e uso no Ubuntu 24.04 / Debian 13](docs/IMAP.md).

```bash
bash migrate-zimbra-carbonio.sh migrate-mail --install-help
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker --check-tool
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker --check-login
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker --dry-run
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker
```

Sem os parâmetros de conexão, o script solicita hosts, administradores e senhas
no terminal. Cada comando acima é uma execução independente; o último realiza
a cópia. Para usar o executável instalado no sistema, troque `docker` por `native`.
