# Revisão adversarial — Uniswap v4 (2026-11-26)

## Resultado

Não foi confirmado caminho de chamada permissionless que retire ativos ou contorne os controles do `UniswapV4Facet`. Esta revisão não encontrou falha crítica reproduzível. O resultado não certifica a ausência de bugs e a suíte de fork completa permaneceu bloqueada por incompatibilidade do harness/dependências.

## Superfície revisada

- `mintPosition`, `increasePosition`, `decreasePosition` e `swap` exigem `ALLOCATOR_ROLE` e `nonReentrant`.
- O Controller delega aos facets e o ALMProxy executa chamadas externas somente sob seu papel de Controller; o facet obtém `ALLOCATOR_ROLE` da instância `AccessControls` configurada.
- Aumento de liquidez exige que a posição pertença ao proxy; mint envia o NFT ao proxy.
- Diminuição usa o proxy como destinatário. O PositionManager continua aplicando sua autorização de proprietário/aprovador.
- Swap valida o pool ID a partir da pool key, aceita apenas os dois tokens da pool, verifica piso de saída normalizado por decimais e revalida a quantidade recebida após a chamada ao router.
- A chamada de Permit2 define allowance temporária com expiração no timestamp atual; o Permit2 considera expirada apenas quando `block.timestamp > expiration`, permitindo o uso na mesma transação. O allowance interno restante não permanece válido em blocos seguintes.

## Validação

- `forge test --match-path test/integration/facets/UniswapV4Facet.t.sol -vv`: **19 aprovados, 0 falhos**. São testes de integração focados principalmente em construtor, configuração e getters; não substituem fork de liquidez/swap.
- `forge test --match-contract Controller_UniswapV4Facet_Tests -vv`: falhou antes da execução por erro preexistente no `ForkTestBase.t.sol`: chamada `getChain("mainnet").createSelectFork(...)` não suportada pela versão instalada de `forge-std`.
- Ajustei essa chamada temporariamente no setup e restaurei o arquivo ao final. A compilação avançou e encontrou mais incompatibilidades herdadas nas chamadas `AllocatorInit.initShared/initIlk` (referência `DssInstance storage` passada onde a dependência atual espera `memory`). Não alterei dependências nem o código de produção para contornar isso.
- Estado do repositório após o experimento: nenhuma mudança em `test/mainnet-fork/ForkTestBase.t.sol`; seguem apenas o submódulo previamente inicializado e os arquivos de auditoria locais existentes.

## Conclusão e próximo passo

O caminho provável de maior valor não é alegar bypass nesta integração com a evidência atual. Para avançar com confiança, é necessário alinhar a versão de `forge-std`/dependências do checkout à versão esperada pelos testes de fork (ou preparar um harness isolado compatível) e então executar as funções de mint, increase, decrease e swap contra estado de fork, em modo somente local. Até essa validação, não há base para classificar impacto financeiro como crítico nem para submeter este vetor como vulnerabilidade.


## Atualização — fork compatível e testes de barreira (2026-11-27)

Para destravar a validação seletiva, ajustei temporariamente o harness para usar um endpoint RPC somente de leitura, importei o mesmo tipo `DssInstance` usado por `AllocatorInit` e selecionei o bloco de fork 26502755, já acessível no endpoint. Os três arquivos foram restaurados ao final; não houve escrita persistente no fork nem transação enviada à rede.

- Testes de chamadas sem `ALLOCATOR_ROLE`: mint, increase, decrease e swap — **4 aprovados, 0 falhos**.
- Testes de reentrância para mint, increase, decrease e swap — **4 aprovados, 0 falhos**.
- Isso exercitou o Controller/facets recém-deployados pelo teste em fork e confirma que os chamadores sem papel não passam por essas quatro entradas nos cenários avaliados.
- Tentei também os dois testes de swap funcional. Eles não são válidos como oráculo nesse bloco posterior: um falhou porque o valor exato esperado no evento corresponde ao estado antigo do pool; o outro porque o mínimo de saída pré-calculado para o bloco antigo passou a ser baixo demais para a validação normalizada. Não interpreto esses resultados como bug do contrato nem como evidência de perda.
- O bloco fixado originalmente (23470490) não está disponível no endpoint público utilizado, cujo histórico começa em 26492729. A suíte financeira completa permanece sem validação contra seu estado original.

Conclusão atualizada: os testes de autorização e reentrância não encontraram bypass. O resultado não exclui outras falhas no facet; swaps de produção localizados em fork exigem fixtures recalculadas para o bloco selecionado, e devem comparar saldos/resultados reais em vez de eventos com quantias absolutas históricas.


## Tentativas ampliadas de contorno de autorização (2026-11-27)

Adicionei o teste reproduzível [UniswapV4AuthBoundaryFork.t.sol](https://github.com/bamboozorigens-ai/spark-alm-controller/blob/sky-audit-2026-11-26/research/sky-pau/UniswapV4AuthBoundaryFork.t.sol). O teste cria um relay malicioso dentro do processo local e tenta invocar as entradas do Controller como contrato intermediário, escalar papel, reconfigurar limites e contornar o Controller chamando diretamente o ALMProxy.

- Resultado em fork Ethereum no bloco 26502755: **13 aprovados, 0 falhos**.
- As quatro entradas financeiras (mint, increase, decrease, swap) reverteram para o relay sem `ALLOCATOR_ROLE`. O teste comparou o erro de autorização e verificou saldos USDC/USDT do proxy antes e depois.
- Tentativas de obter `ALLOCATOR_ROLE`, obter `CONTROLLER` no ALMProxy, mudar admin de papel, zerar slippage, alterar tick limits, chamar `ALMProxy.doCall` para transferir USDC, usar `doDelegateCall` e `doCallWithValue` também falharam com os papéis esperados. Nenhum saldo foi transferido ao relay.
- Os quatro testes herdados também confirmam bloqueio de reentrância e de chamador sem allocator.
- O harness e as dependências foram compatibilizados apenas durante a execução e restaurados depois. A única mutação foi no estado temporário do fork criado pelo Foundry; não houve transação externa.

Esta bateria não encontrou rota para obter privilégio ou retirar fundos neste Controller recém-deployado pelo harness. Ela valida especificamente as barreiras de chamada e não prova ausência de vulnerabilidades em outros facets, deployments ou combinações de estado.
