# coding-agent-control

**Developer control for coding agents.**

Uma camada local ao repositório para controle, verificação e confiança no
trabalho de agentes de programação.

[English](README.md)

Claude Code, Codex e outros coding agents podem executar o trabalho, mas o
desenvolvedor e o projeto mantêm autoridade sobre o que é permitido, o que é
obrigatório e o que pode ser aceito como concluído. Regras, estado operacional,
verificação, requisitos de Risk e limites de evidência acompanham o repositório,
mesmo quando o agente ou fornecedor do modelo muda.

`Status: done` é uma declaração de conclusão, não uma prova. A declaração só é
aceita depois que os requisitos aplicáveis de estado, verificação, Risk,
evidência independente e aprovação forem satisfeitos.

## O problema

O comportamento de um coding agent costuma depender do host, modelo e sessão
em uso. Regras podem ser esquecidas, handoffs podem perder o estado atual e uma
mensagem confiante de conclusão pode não ter evidência reproduzível.

`coding-agent-control` mantém o contrato do projeto dentro do repositório e
torna determinísticas as garantias observáveis nas superfícies em que o host
oferece uma integração capaz de bloquear.

## O que o projeto faz

- instala diretivas compartilhadas e faz merge idempotente dos hooks do host;
- bloqueia casos suportados de comandos destrutivos, paths perigosos e limites
  de secrets;
- mantém estado operacional atual e pequeno para handoff determinístico;
- executa a verificação declarada e usa o exit code como fonte de verdade;
- aumenta requisitos de conclusão conforme o Risk declarado da tarefa;
- valida evidência com autoridade separada e ligada ao SHA exato em trabalhos
  `high` e `critical`;
- funciona sozinho quando CI e memória semântica opcionais estão ausentes.

## O que o projeto não faz

O projeto não controla o raciocínio interno do LLM, não fornece um sandbox
completo, não substitui permissões do host, não executa agentes, não orquestra
modelos e não substitui Git ou CI. Também não é um sistema de memória semântica.

Uma regra escrita apenas em Markdown é advisory. Uma garantia só é chamada de
enforced quando o host suportado invoca um mecanismo determinístico capaz de
bloquear a ação ou transição e essa integração é coberta por testes.

## Garantias principais

- Git permanece a fonte de verdade factual.
- Controles de safety e integridade falham de forma fechada nas superfícies
  suportadas.
- Texto no output não transforma em sucesso um check obrigatório com falha.
- Risk aumenta requisitos de evidência e aprovação; não certifica segurança.
- Evidência independente e aprovação crítica só são aceitas quando possuem
  autoridade separada do executor.
- A ausência de capabilities opcionais não interrompe o trabalho comum.

## Hosts suportados

Claude Code e Codex recebem regras e hooks nativos do repositório. Cursor e
Windsurf recebem regras e podem usar o fallback opcional de pre-commit. Outros
agentes podem ler as regras e executar os helpers, mas isso, isoladamente, é
advisory.

O vocabulário público é preciso:

- **Enforced** — uma integração determinística e testada pode bloquear a ação
  ou transição naquele host.
- **Advisory** — diretiva, warning ou revisão sem bloqueio comprovado.
- **Unsupported** — não existe integração determinística para a superfície.
- **Experimental** — existe integração, mas ela ainda não sustenta uma garantia
  pública estável.

Consulte a [matriz detalhada no README principal](README.md#enforcement-matrix)
antes de depender de um bloqueio específico.

## Início rápido

Dentro do diretório do seu projeto:

```bash
curl -fsSL https://raw.githubusercontent.com/Ernanidacosta/agent-md/main/install.sh | bash
```

Esse é o endereço atual deste projeto e será alterado somente numa transição
separadamente autorizada do repositório GitHub. Não é a URL de instalação do
upstream.

O installer adiciona suporte a Claude Code, Codex, Cursor e Windsurf. Não é
necessário criar `agent-md.toml`, instalar `gh`, configurar CI, verifier,
aprovação ou provider de memória semântica para começar.

Fluxo básico:

1. Instale coding-agent-control no projeto.
2. Opcionalmente, execute `./.agent-md/bin/doctor.sh` para inspecionar a
   instalação.
3. Trabalhe normalmente; o agente mantém o estado atual pequeno em `memory/`.
4. Declare checks determinísticos quando forem úteis e habilite garantias
   avançadas somente quando o Risk exigir.

## Como funciona

A instalação mantém um arquivo de regras canônico e adapta esse conteúdo aos
hosts suportados. Hooks de Claude Code e Codex aplicam os controles nas
superfícies oferecidas por cada host. O pre-commit é um fallback opcional e não
é ativado silenciosamente.

```text
repositório
├── AGENT.md                 regras canônicas
├── AGENTS.md                adapter Codex/Cursor/Windsurf
├── CLAUDE.md                adapter Claude Code
├── agent-md.toml.example    configuração determinística opcional
├── .claude/hooks/           enforcement Claude Code
├── .codex/hooks/            enforcement Codex
├── .agent-md/bin/           doctor, verify e helpers
└── memory/                  estado operacional compatível atual
```

Os nomes `agent-md.toml`, `.agent-md/`, `memory/`, `$agent-md-verify` e os
nomes instalados das regras permanecem como interfaces de compatibilidade na
arquitetura atual. Nenhuma remoção está planejada como parte desta transição.

## Verificação

Quando o projeto já expõe convenções conhecidas, coding-agent-control pode
inferir um contrato pequeno como fallback identificado como heurístico. Para
uma garantia explícita, copie o exemplo e declare os comandos reais:

```bash
cp agent-md.toml.example agent-md.toml
```

```toml
[verify]
lint = "ruff check ."
test = "pytest"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 300
```

Execute o contrato completo com:

```bash
./.agent-md/bin/verify.sh
```

Check obrigatório com falha, indisponível ou em timeout bloqueia. Check
opcional nessas condições produz warning. Um check não configurado nunca é
apresentado como executado.

## Estado operacional

`memory/` contém apenas a verdade operacional atual: status, tarefa, scope,
próximos passos, bloqueios, plano vigente, critérios de verificação e gotchas
ainda aplicáveis. Não é um changelog nem memória histórica. Git guarda o
histórico factual.

O formato atual é preservado por compatibilidade. A direção arquitetural futura
é separar estado de trabalho volátil, que pode permanecer local e não
versionado, de estado de controle cuja integridade e binding afetam Risk,
safety, verificação, trust, aprovação ou conclusão. Essa separação ainda não foi
implementada; veja [`docs/architecture.md`](docs/architecture.md).

## Risk e conclusão

Risk responde “quanta evidência, revisão e aprovação são necessárias?”, não “a
implementação é segura?”. O agente pode propor o Risk; o projeto e o
desenvolvedor mantêm a autoridade final.

| Risk | Requisito adicional de conclusão |
|---|---|
| `low` | contrato normal de verificação obrigatória |
| `medium` | runtime ou smoke quando declarado e aplicável |
| `high` | evidência independente confiável |
| `critical` | evidência independente e aprovação humana externa |

Requisitos finais bloqueiam a declaração `done`, não o trabalho intermediário
em `active`, `blocked` ou `verifying`. Risk e aprovação nunca liberam um
bloqueio fatal de safety.

## Verificação independente

Evidência independente não é apenas o executor rodando outro script. Ela deve
vir de uma autoridade ou execução separada, passar por um trust anchor
preexistente e estar ligada ao commit exato.

GitHub Actions com `gh` é a implementação de referência em
[`examples/github-actions/`](examples/github-actions/), não uma dependência do
core. Outros provedores podem emitir o mesmo contrato estruturado sem alterar o
core. Um verifier ou workflow novo/modificado não pode atestar a própria
mudança que o introduziu.

## Memória semântica opcional

A arquitetura separa responsabilidades:

```text
Git
  -> verdade factual

estado operacional local
  -> trabalho atual e handoff

provider opcional de memória semântica
  -> recall histórico e semântico
```

ICM é a integração de referência atual e pode ser habilitada explicitamente:

```toml
[integrations.icm]
enabled = true
```

ICM não participa de safety, verificação, Risk, trust, aprovação ou conclusão.
Sem provider de memória, o fluxo principal permanece integralmente funcional.

## Arquitetura e limites

O desenvolvedor/projeto define intenção, regras e autoridade. O coding agent
propõe e executa. O host controla sandbox, filesystem, processos e lifecycle de
hooks. Git registra fatos. Verifiers externos produzem evidência independente.
Providers de memória fornecem apenas recall opcional.

A descrição dos limites, interfaces compatíveis e direção futura do estado está
em [`docs/architecture.md`](docs/architecture.md). A referência técnica completa,
incluindo severity, códigos, attestation, classificação de paths e formatos de
estado, permanece no [README principal em inglês](README.md).

## Origem e attribution

Originalmente derivado de
[`iamfakeguru/agent-md`](https://github.com/iamfakeguru/agent-md) sob a licença
MIT e substancialmente evoluído para uma direção de projeto própria. O aviso de
copyright original permanece em [`LICENSE`](LICENSE), e o histórico Git é
preservado. O upstream é a origem histórica, não uma dependência de runtime ou
instalação.

## Licença

MIT. Consulte [`LICENSE`](LICENSE).
