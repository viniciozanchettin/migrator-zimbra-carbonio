# Migração de mensagens: Zimbra → Carbonio

O modo `migrate-mail` é independente dos modos de provisionamento e troca de
senhas. Ele usa `imapsync` para copiar mensagens e a hierarquia de pastas IMAP
das contas de `migration-data/accounts.tsv`, mantendo o mesmo endereço no
destino. As contas precisam ter sido provisionadas antes.

Pode ser executado no Ubuntu 24.04 ou em uma VM intermediária Debian 13. A
máquina executora precisa alcançar os dois servidores por IMAPS, normalmente
na porta TCP 993. Não precisa ter Zimbra, Carbonio ou usuário `zextras` instalado.
Use nomes DNS que correspondam aos certificados dos servidores.

## Qual instalação escolher

Para uma **VM intermediária dedicada**, recomendamos Docker: as dependências do
imapsync ficam na imagem e não precisam ser instaladas individualmente na VM.
O script executa containers temporários, sequencialmente, sem publicar portas.
Não há interface web, Compose ou container permanente para manter.

Se o imapsync já estiver instalado, use `--engine native` (padrão). A ferramenta
só precisa existir na máquina que executa o script. Nenhum pacote ou imagem é
instalado automaticamente pelo modo de migração.

Esta implementação foi verificada com testes simulados. A instalação nas duas
distribuições, as conexões reais e a migração das suas caixas devem ser validadas
no ambiente de destino, começando por uma conta.

## Opção A: Docker na VM intermediária

Em uma VM Ubuntu 24.04 ou Debian 13 sem Docker, execute como root:

```bash
apt update
apt install docker.io util-linux ca-certificates
systemctl enable --now docker
docker version
docker pull gilleslamiral/imapsync:latest
docker run --rm gilleslamiral/imapsync:latest imapsync --version
```

Os pacotes `docker.io` estão disponíveis nos repositórios das distribuições:
[Ubuntu 24.04](https://packages.ubuntu.com/noble/docker.io) e
[Debian 13](https://packages.debian.org/trixie/docker.io).
No Ubuntu, o repositório `universe` precisa estar habilitado.
Se já houver Docker Engine instalado por outro método, use a instalação
existente; não instale `docker.io` por cima dela.

A imagem é publicada pelo autor do imapsync. Consulte também a
[documentação Docker do projeto](https://imapsync.lamiral.info/FAQ.d/FAQ.Docker.txt).
O exemplo é destinado a VM Linux amd64; para outra arquitetura, confira a
disponibilidade da imagem.

Na pasta do script:

```bash
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker --check-tool
```

Esse comando verifica o acesso ao Docker, a presença local da imagem e a
inicialização do imapsync. Se faltar a imagem, faça o `docker pull` acima. O
script usa `--pull=never` e fixa o ID da imagem durante cada migração, registrando
esse ID no log. `--image IMAGEM` permite selecionar outra tag ou digest já
disponível localmente.

O container recebe somente a pasta temporária das credenciais em leitura e uma
pasta de trabalho da execução em escrita. Ele usa a rede do host Linux, sem
publicar portas. Os logs ficam no host e sobrevivem à remoção do container.

## Opção B: instalação nativa

Se já existe uma instalação, primeiro execute:

```bash
command -v imapsync
imapsync --version
bash migrate-zimbra-carbonio.sh migrate-mail --engine native --check-tool
```

O autor disponibiliza um pacote `.deb` externo, documentado em seu
[manual para Debian](https://imapsync.lamiral.info/INSTALL.d/INSTALL.Debian.txt).
Isso permite usar `apt install ./imapsync.deb`, mesmo sem encontrar o pacote
nos repositórios configurados. O manual consultado enumera versões até Debian
12; não declara explicitamente validação no Debian 13. Confira as dependências
no sistema antes de instalar:

```bash
apt update
apt install curl ca-certificates util-linux
mkdir -p /root/imapsync-install
cd /root/imapsync-install
curl --fail --location --output imapsync.deb https://imapsync.lamiral.info/dist2/imapsync.deb
apt --simulate install ./imapsync.deb
```

Se a simulação resolver as dependências sem remover pacotes necessários:

```bash
apt install ./imapsync.deb
imapsync --version
```

Não force a instalação com dependências quebradas. No Ubuntu 24.04, ou caso o
pacote externo não seja compatível, a instalação manual usa dependências do
`apt` e o executável do autor. A lista abaixo reúne dependências usadas pelo
projeto; o teste final identifica módulos ainda ausentes:

```bash
apt update
apt install perl curl ca-certificates util-linux \
  libauthen-ntlm-perl libcgi-pm-perl libcrypt-openssl-rsa-perl \
  libdata-uniqid-perl libdigest-hmac-perl libencode-imaputf7-perl \
  libfile-copy-recursive-perl libfile-tail-perl libhtml-parser-perl \
  libhttp-daemon-perl libhttp-daemon-ssl-perl libhttp-message-perl \
  libio-socket-inet6-perl libio-socket-ssl-perl libio-tee-perl \
  libjson-perl libjson-webtoken-perl libmail-imapclient-perl \
  libmodule-scandeps-perl libnet-dns-perl libnet-server-perl \
  libnet-ssleay-perl libparse-recdescent-perl libproc-processtable-perl \
  libreadonly-perl libregexp-common-perl libsys-meminfo-perl \
  libterm-readkey-perl libtest-mockobject-perl libunicode-string-perl \
  liburi-perl libwww-perl
mkdir -p /root/imapsync-install
cd /root/imapsync-install
curl --fail --location --output imapsync https://imapsync.lamiral.info/imapsync
chmod 700 imapsync
./imapsync --version
```

Somente depois que o teste funcionar:

```bash
install -m 755 imapsync /usr/local/bin/imapsync
imapsync --version
```

Referências de instalação e dependências do autor:
[Ubuntu](https://imapsync.lamiral.info/INSTALL.d/INSTALL.Ubuntu.txt) e
[Debian](https://imapsync.lamiral.info/INSTALL.d/INSTALL.Debian.txt).

## Arquivos necessários

Na máquina executora, mantenha:

```text
zimbra-carbonio-migration/
├── migrate-zimbra-carbonio.sh
└── migration-data/
    └── accounts.tsv
```

Você também pode copiar a pasta `migration-data` existente inteira. `docs/IMAP.md`
é apenas o manual e `tests/` não precisa ser copiado. Para executar sem root,
o usuário precisa conseguir ler os dados e escrever os logs; no modo Docker,
também precisa de acesso ao daemon Docker.

## Credenciais administrativas

Use uma conta administrativa com permissão para acessar as caixas em cada
servidor. A senha de root do Linux não serve para autenticação IMAP.
O uso de `--authuser1` e `--authuser2` é apresentado na
[documentação de migração do Carbonio](https://docs.zextras.com/carbonio-ce/html/admincli/migration.html).

Não é necessário usar o CSV de senhas locais nem alterar senhas dos usuários.
O script solicita as duas senhas de forma oculta, grava cópias temporárias com
permissão `600`, usa `--passfile1/--passfile2` e as remove ao terminar ou receber
uma interrupção tratável. As senhas não são colocadas nos argumentos dos
processos. Não use depuração externa para capturar o tráfego de autenticação.

Para automação, `--passfile1 /caminho/origem` e `--passfile2 /caminho/destino`
aceitam arquivos existentes: primeira linha com a senha exata, sem aspas
adicionais, em formato Linux (LF). Proteja os originais com `chmod 600`.
O script remove apenas suas cópias temporárias, preservando esses originais.

## Primeiro teste: uma conta

Na pasta do script, execute (substitua os exemplos):

```bash
bash migrate-zimbra-carbonio.sh migrate-mail \
  --engine docker \
  --host1 zimbra.empresa.com.br \
  --host2 carbonio.empresa.com.br \
  --admin1 admin@empresa.com.br \
  --admin2 admin@empresa.com.br \
  --account usuario@empresa.com.br \
  --check-login
```

O mesmo endereço administrativo pode ter senhas diferentes em cada servidor.
Esse teste autentica e encerra, sem criar pastas ou copiar mensagens. Ele também
verifica conexão e TLS, mas não garante espaço, quota ou permissão de escrita.

Troque `--check-login` por `--dry-run` para simular a sincronização e revisar as
pastas nos logs. Para copiar essa caixa de teste, remova `--check-login` ou
`--dry-run`, mantendo `--account`.

Para usar instalação nativa, substitua `--engine docker` por `--engine native`.

## Migrar todas as contas

Depois de conferir a caixa de teste, execute sem `--account`:

```bash
bash migrate-zimbra-carbonio.sh migrate-mail \
  --engine docker \
  --host1 zimbra.empresa.com.br \
  --host2 carbonio.empresa.com.br \
  --admin1 admin@empresa.com.br \
  --admin2 admin@empresa.com.br
```

Também é possível usar o modo interativo:

```bash
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker
```

Ele solicita os hosts, administradores e senhas. A execução real começa após
essas informações, sem outra confirmação. O script valida todo o TSV e testa
o login de todas as contas selecionadas antes de iniciar a cópia. Uma falha
nessa etapa interrompe o lote sem copiar mensagens. Contas duplicadas na lista
são processadas uma vez; contas fora dela não são incluídas.

## Certificados e portas

As conexões usam TLS implícito, porta 993 por padrão, validando certificado e
nome do servidor. `--port1` e `--port2` permitem outras portas com TLS implícito;
este modo não implementa STARTTLS na porta 143.

Se houver uma autoridade certificadora privada, informe os certificados CA
em PEM com `--cafile1 /caminho/ca-zimbra.pem` e/ou
`--cafile2 /caminho/ca-carbonio.pem`. Funciona nos modos nativo e Docker.
O arquivo deve conter o certificado da CA, sem chave privada. O nome informado
em `--host1/--host2` ainda precisa corresponder ao certificado do servidor.

O script recusa origem e destino com o mesmo host e porta. Nomes diferentes
podem apontar ao mesmo servidor; confira os endereços antes da execução.

Para uma migração em que você opte por não validar os certificados, adicione
`--insecure1` para o Zimbra e/ou `--insecure2` para o Carbonio. Essas opções
funcionam com instalação nativa e Docker, mantêm a criptografia TLS, mas não
verificam a identidade do servidor. Sem elas, a validação continua habilitada.

Exemplo para testar o Carbonio acessado por IP sem validar seu certificado:

```bash
bash migrate-zimbra-carbonio.sh migrate-mail --engine docker \
  --host2 192.168.0.100 --insecure2 --check-login
```

Os demais dados serão solicitados no terminal. Para ignorar a validação nos
dois lados, acrescente também `--insecure1`. Mantenha as opções escolhidas ao
executar a simulação ou a cópia real; elas não ficam salvas entre execuções.

## Logs, falhas e repetição

Cada execução cria uma pasta exclusiva:

```text
migration-data/logs/imap-DATA-HORA-XXXXXX/
├── results.tsv
├── 00001-auth.log
├── 00002-auth.log
├── 00001-sync.log
├── 00002-sync.log
└── tmp/
```

`results.tsv` contém fase, conta, status, código de saída e nome do log.
As fases são `auth`, `dry-run` e `sync`. **Somente `sync` com `OK` indica que
uma cópia terminou sem erro reportado pelo imapsync.** `auth` valida acesso e
`dry-run` é simulação. Confira também as estatísticas do log da caixa.

Se uma cópia falhar, o script registra a falha, tenta as próximas contas e
retorna código diferente de zero no final. Cada execução mantém seus próprios
logs. Uma interrupção pode deixar o log da conta em andamento sem linha de
resultado final; essa conta precisa ser conferida ou executada novamente.
Não há mensagem de sucesso para uma operação interrompida.

Para acompanhar uma caixa em outro terminal, use `tail -f` no arquivo de log
cujo caminho foi mostrado. As credenciais temporárias ficam fora da pasta dos
logs. Em desligamento abrupto ou `SIGKILL`, a limpeza automática não pode ser
garantida: verifique pastas `imap-credentials.*` na pasta temporária do sistema.

O modo bloqueia outra execução IMAP que use a mesma pasta `migration-data`.
Esse bloqueio não coordena outras VMs ou outras cópias da pasta; execute somente
um processo de migração por caixa de destino.

Pode-se repetir o comando para uma sincronização incremental. O script usa a
identificação padrão do imapsync, sem forçar recópia nem excluir mensagens em
qualquer lado. Mudanças nos cabeçalhos ou no mapeamento de pastas podem afetar
a identificação; teste a repetição na caixa piloto antes do lote. Veja o
[tutorial do imapsync](https://imapsync.lamiral.info/doc/TUTORIAL_Unix.html).

Preserva-se a hierarquia padrão das pastas: o script não aplica `--automap` nem
regras personalizadas de nomes. Revise Enviados, Rascunhos e Lixeira na simulação.
Sincronização de flags, como lida/não lida, segue o comportamento do imapsync.
Contatos, calendários, tarefas e permissões de compartilhamento não são migrados
por este modo. Não altere o fluxo de recebimento/DNS antes de planejar a
sincronização final e validar as caixas.
