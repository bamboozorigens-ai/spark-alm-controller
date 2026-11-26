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
