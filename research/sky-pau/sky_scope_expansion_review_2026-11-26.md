# Revisão de expansão do escopo Sky — 2026-11-26

## Resultado

Revisão estática adversarial dos contratos PAS, ValueRegistry, SBEBeam e FarmOwner listados no escopo Immunefi. **Nenhuma falha explorável por usuário não privilegiado, nem caminho confirmado para perda ou congelamento de fundos foi demonstrado nesta revisão.** Não enviar relatório de bounty com base nos pontos abaixo como se fossem vulnerabilidades confirmadas.

Foi feita também uma reprodução separada do fluxo WEETH em fork local. Ela demonstra somente griefing/atraso recuperável; não demonstra roubo, insolvência ou congelamento permanente. A elegibilidade do PAU/WEETH no bounty ainda não foi confirmada.

## Escopo e fontes

- PAS no commit [947e71cd5dbaaf9c5b3840dd1b23e8e99d9a564d](https://github.com/sky-ecosystem/pas/tree/947e71cd5dbaaf9c5b3840dd1b23e8e99d9a564d): `BeamState.sol`, `Configurator.sol`, `Timelock.sol`, `PASMom.sol`.
- [ValueRegistry.sol](https://github.com/sky-ecosystem/value-registry/blob/main/src/ValueRegistry.sol).
- DSS Flappers no commit [5d8215cee7b66591aa2f87023043c868a420fe27](https://github.com/sky-ecosystem/dss-flappers/tree/5d8215cee7b66591aa2f87023043c868a420fe27): `SBEBeam.sol`, `FarmOwner.sol`.
- A página oficial de escopo lista os ativos e limita recompensas aos impactos expressamente aceitos: [Sky Scope no Immunefi](https://immunefi.com/bug-bounty/sky/scope/). A página de recursos orienta pesquisadores aos repositórios em [sky-ecosystem](https://github.com/sky-ecosystem) e ao [Chainlog](https://chainlog.sky.money/) para endereços atuais.
- Correção de escopo: a lista atual inclui `L2_PAU_Factory` (alvo `PAUFactory.sol`, commit `cbf71b2ac840ca9288eb867d3dd354e08089e1d7`) e `L2_ADMINISTERED_AGENT_FACTORY` (commit `5e6b52f45266913a9bc0611d417aef2c7752ab25`). Além disso, a regra do programa permite submeter para consideração impactos críticos em qualquer contrato Sky implantado, desde que a falha exista no deployment atual. A elegibilidade do WEETH para impactos abaixo de crítico ainda depende de sua inclusão específica na lista de ativos.

## Verificações adversariais

### PAS — BeamState e Configurator
- Funções de configuração exigem `wards` ou combinação explícita de função e seletor. Não encontrei chamada permissionless capaz de alterar papéis, rate limits, whitelists ou ações de Controller.
- `Configurator.setRateLimit` usa configuração inicial, limite de mudança e cooldown antes de encaminhar a escrita a RateLimits. Os cálculos de multiplicação podem reverter em casos de overflow, mas isso não contorna autorização nem aumenta limites.
- Relações já configuradas com RateLimits/Controllers sobrevivem a `delRateLimits`/`delController`; os comentários definem a remoção como soft deprecation e exigem remover as relações individualmente. Não tratei esse comportamento documentado como bypass.

### PAS — Timelock
- Execução é permissionless após agendamento, mas agendar exige papel de proposer. Propostas maliciosas ou aprovação/governança maliciosa são exclusões expressas do programa.
- O Timelock chama os alvos antes de remover seu índice da lista de operações. Uma tentativa de reentrar na mesma operação pode fazer a transação reverter na remoção duplicada; para chegar a isso, seria necessário que a operação agendada incluísse um alvo com callback apropriado. Não foi encontrada rota independente de atacante nem impacto reproduzível.
- Pausa bloqueia agendamento, cancelamento e execução; o código documenta que o administrador pode despausar e cancelar em seguida.

### PAS — PASMom
- `PASInit.initMom` dá ao Mom ward em BeamState e `PAUSER_ROLE` no Timelock. Assim, as chamadas de emergência não dependem de um grant de papel ausente.
- `owner` e `authority` continuam sendo controles privilegiados; não foi identificada escalada permissionless.

### ValueRegistry
- Verifiquei inserção/atualização/remoção, inclusive chave `bytes32(0)`, posição trocada pela última chave e remoção repetida numa única chamada. Não encontrei corrupção de índice ou escrita sem `bud`.
- As mutações de valores são restritas a operadores; os fluxos que consumiriam os parâmetros precisam ser analisados no respectivo contrato consumidor para avaliar impacto econômico.

### SBEBeam e FarmOwner
- `SBEBeam.set` restringe facilitador, estado do Splitter, cooldown, múltiplo RAY, burn, hop e taxa máxima; alterações no farm seguem a ownership configurada.
- `FarmOwner` encaminha chamadas de administração do farm somente por wards. `recoverERC20` assume token padrão com retorno/reversão convencional, como indicado no comentário; não há evidência nesta revisão de que token não padrão esteja entre os ativos ativos relevantes.
- Nenhum caminho de atacante externo para alterar parâmetros do burn stream ou retirar tokens foi confirmado.

### PAU / WEETH — reprodução em fork
- Foundry 1.10.1 foi instalado; `forge`, `cast` e `anvil` estão disponíveis no ambiente.
- O teste local usa um fork da Ethereum no bloco `26502658`, contratos EtherFi reais lidos do fork e um WEETHModule novo implantado localmente. Não representa um deployment live do Controller PAU e não prova que um módulo de produção esteja configurado.
- Um endereço externo consumiu um pedido de saque finalizado de 10 ETH por meio do claim permissionless da NFT. O atacante recebeu 0 ETH; o pagamento foi ao módulo. O claim normal daquele ID falhou por já estar consumido.
- Um claim posterior válido de 1 ETH pelo módulo transferiu `11.000000000000000001 WETH` ao proxy, incluindo o saldo anterior retido. Isso demonstra atraso/consumo de pedido com recuperação posterior, não perda financeira líquida.
- Teste: `test/audit/WEETH_PublicClaimAttack.t.sol`, função `test_outsiderConsumesFinalizedRequestButCannotKeepFunds`; resultado: **1 aprovado, 0 falhos**. Nenhuma transação foi enviada à rede ao vivo.

## Validação executada

- `test/unit/rate-limits/RateLimits.t.sol`: **36 aprovados, 0 falhos**, incluindo testes fuzz.
- `test/integration/Controller.t.sol`: **22 aprovados, 0 falhos**.
- `test/audit/SiblingControllerReentrancy.t.sol`: **3 aprovados, 0 falhos**; reentrada em Controller irmão continua exigindo `ALLOCATOR_ROLE` nessa instância.
- Suíte ampla: não compilou devido a um teste legado em `test/mainnet-fork/ForkTestBase.t.sol` chamando `createSelectFork` numa API incompatível de dependência. O erro é do setup de testes e não foi corrigido, para não ampliar alterações de dependência fora do escopo.
- `test/unit/WEETHModule.t.sol`: 15 aprovados e 2 falhos por divergência entre o seletor de erro customizado da dependência OpenZeppelin e a expectativa textual `InvalidInitialization()`; não é falha no fluxo testado acima.

## Limitações e próximo passo

A revisão não encontrou até agora falha nova de alto impacto nos alvos PAS, ValueRegistry, SBEBeam ou FarmOwner. O próximo filtro para maximizar valor de bounty é confirmar os ativos e deployments elegíveis, depois priorizar hipóteses de roubo direto, insolvência ou congelamento permanente com PoC local. O resultado WEETH deve permanecer rotulado como candidato de disponibilidade fora de escopo ou elegibilidade não confirmada, sem ser apresentado como vulnerabilidade crítica.


## Alvos PAU explicitamente listados — análise adicional

A consulta ampliada da lista de ativos corrigiu a avaliação anterior: o bounty inclui o alvo `L2_PAU_Factory` no commit [cbf71b2](https://github.com/sky-ecosystem/diamond-pau/blob/cbf71b2ac840ca9288eb867d3dd354e08089e1d7/src/PAUFactory.sol) e `L2_ADMINISTERED_AGENT_FACTORY` no commit [5e6b52f](https://github.com/sky-ecosystem/pau-administered-agent/blob/5e6b52f45266913a9bc0611d417aef2c7752ab25/src/AdministeredAgentFactory.sol).

### PAUFactory
- No commit indicado pelo bounty, os métodos públicos criam componentes novos com parâmetros fornecidos pelo chamador. `deployController` aceita endereços externos para AccessControls, proxy e RateLimits, mas não concede ao Controller criado papel em nenhum desses contratos existentes.
- O chamador pode escolher os administradores dos componentes recém-criados; isso afeta apenas a instância solicitada pelo próprio chamador. Não foi identificado caminho para alterar ou drenar uma instância PAU já implantada.
- Observação de versão: o checkout local `dev` estava no commit `b0b7efd`, posterior ao commit exato listado pelo programa. Os 9 testes locais de `PAUFactory` passaram, mas exercitam esse checkout mais recente e não são evidência de PoC para o bytecode do alvo antigo.

### AdministeredAgentFactory
- O método público `deploy(admin)` cria um novo agente; o contrato agente rejeita admin zero e concede a administração inicial somente ao endereço recebido.
- A factory não retém papel e não escreve em AccessControls, ALMProxy ou RateLimits existentes. A análise do código não identificou escalada de papel ou efeito sobre instâncias pré-existentes.

### Critério de submissão
- A regra oficial da Sky exige que a falha exista no contrato implantado e permite considerar impacto crítico em qualquer contrato Sky implantado. O WEETH PoC continua demonstrando somente atraso recuperável: não satisfaz esse critério crítico e permanece não confirmado para impactos de menor severidade.


## EMSP stUSDS emergency spells — permissão de agendamento

Analisei os três alvos recém-adicionados: `StUsdsRateSetterDissBudSpell`, `StUsdsRateSetterHaltSpell` e `StUsdsWipeParamSpell`. A função base `DssEmergencySpell.schedule()` chama imediatamente a ação emergencial e não verifica diretamente o chamador, então testei a hipótese de disparo permissionless contra os três endereços implantados indicados pelo README do repositório.

- Fork local Ethereum no bloco `26502755`; para um endereço atacante, cada chamada reverteu com `StUsdsMom/not-authorized`.
- O motivo é que `StUsdsMom` autoriza chamadas via sua Authority (MCD_ADM); o spell precisa ser o endereço autorizado/hat. Os testes de integração upstream também exercitam esse requisito e esperam a reversão quando o spell não tem o hat.
- Resultado: **3 aprovados, 0 falhos** em `test/audit/EmergencySpellPermissionlessScheduleFork.t.sol`. Nenhuma transação foi enviada à rede.
- Conclusão: a ausência de ACL local em `schedule()` não forneceu bypass no deployment testado; o controle efetivo está no Mom. Usar um spell que foi legitimamente escolhido pela governança não é um ataque permissionless independente.
