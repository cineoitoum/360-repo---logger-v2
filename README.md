# Unificador VR

App macOS (Apple Silicon, macOS 13+) que junta numa pasta só as pastas `VID_20…` de mesmo nome espalhadas pelos 7 cartões da Insta360 Pro 2 (6 microSD de lente + 1 SD de proxy) e organiza tudo por data:

```
DESTINO/
  261108/
    VID_20261108_162608/   ← conteúdo dos 7 cartões, nomes originais
    VID_20261108_170012/
  _sem_data/
    VID_20_nome_fora_do_padrao/
  UnificadorVR_log_20261109_101500.csv
```

**Nenhum arquivo ou pasta é renomeado.** O app cria pastas novas com os mesmos nomes. O único "rename" que ele faz é no próprio arquivo temporário: `nome.partial` vira `nome` depois de verificado.

## Instalação fácil (sem Terminal)

1. Baixe o projeto: no GitHub, botão verde **Code** › **Download ZIP**. Dê dois cliques no ZIP para descompactar.
2. Dentro da pasta, dê dois cliques em **`Instalar Unificador VR.command`**.
3. Se o macOS bloquear, você tem duas saídas:
   - **macOS 13–14:** botão direito no arquivo › **Abrir** › **Abrir**.
   - **macOS 15 ou mais novo:** Ajustes do Sistema › Privacidade e Segurança › role até o fim › **Abrir Mesmo Assim**.
   - Funciona em qualquer versão: abra o **Terminal**, digite `bash ` (com espaço), arraste o arquivo para a janela e aperte **Enter**.
4. Se faltarem as ferramentas da Apple, uma janela do macOS vai pedir para instalar: clique em **Instalar**. O instalador espera e continua sozinho.
5. No fim, o app vai para **Aplicativos** e abre sozinho.

Para **atualizar**, baixe o ZIP novo e rode o instalador de novo. Se algo falhar, o registro fica em `UnificadorVR_instalacao.log`, na Mesa.

## Compilar e rodar

Requisito: Xcode 15 ou superior (ou só as Command Line Tools com Swift 5.9+).

```bash
./build_app.sh             # roda os testes e gera build/UnificadorVR.app
./build_app.sh --install   # idem, e copia para /Applications
open build/UnificadorVR.app
```

Desenvolvimento:

```bash
swift test                 # testes do núcleo (também rodam no Linux)
swift run UnificadorVR     # abre a interface direto, sem empacotar
```

Para abrir no Xcode: `open Package.swift`.

### Primeira execução
- O app é assinado ad-hoc (sem Developer ID). Se o Gatekeeper bloquear, clique com o botão direito no app → **Abrir**.
- O macOS vai pedir permissão para acessar volumes removíveis. Se der erro de permissão em alguma pasta, conceda **Acesso Total ao Disco** em Ajustes do Sistema › Privacidade e Segurança.
- Como a assinatura ad-hoc muda a cada build, o macOS pode pedir as permissões de novo depois de recompilar.

## Uso
1. **Pasta raiz**: escolha ou arraste a pasta onde estão as cópias dos cartões.
2. **Destino**: obrigatório. Se estiver dentro da raiz, é ignorado na varredura.
3. **Modo**: Copiar (padrão, originais intocados) ou Mover. "Verificar checksum" vem ligado.
4. **Analisar**: a pré-visualização mostra cada grupo, o número de pastas de origem (aviso se for diferente do esperado, padrão 7), os arquivos, as duplicatas, o tamanho e a pasta de data. Também confere o espaço livre.
5. **Executar** (só fica ativo depois da análise). Mostra o progresso geral e por arquivo, a velocidade, o tempo restante e o botão Cancelar.
6. **Resumo**: contagens, avisos, erros e botões para abrir o log e a pasta de destino.

Para **retomar** depois de cancelar ou de uma falha: clique em Analisar e Executar de novo. Os arquivos completos não são refeitos (aparecem como "já presente no destino"), e os `.partial` órfãos são apagados.

## Regras implementadas
| Situação | Comportamento |
|---|---|
| Mesmo nome-base, extensão diferente (proxy) | Copia todos, lado a lado |
| Nome completo idêntico no grupo (duplicata real) | Copia o primeiro (ordem alfabética do caminho de origem), pula os demais e registra no log. Se o tamanho for diferente, gera aviso crítico |
| Nomes que diferem só em maiúsculas/minúsculas | Mantém o primeiro, o outro fica na origem e gera aviso (crítico se o tamanho for diferente). Nunca é apagado, nem no modo Mover |
| Já existe no destino com o mesmo tamanho | Considerado completo (retomada) |
| Já existe no destino com tamanho diferente | Conflito: não sobrescreve e avisa |
| Mover, volumes diferentes | Cópia → `.partial` → verificação (tamanho + SHA-256) → nome final → apaga a origem |
| Mover, mesmo volume | Movimentação direta (`rename`), sem nunca sobrescrever |
| Mover + duplicata pulada | Só apaga da origem se for idêntica (tamanho **e** checksum) ao arquivo final |
| Copiar, mesmo volume APFS | `clonefile` (instantâneo, sem ocupar espaço) |
| `.DS_Store`, `._*`, `.Trashes`, pastas ocultas | Ignorados |
| Links simbólicos | Não são seguidos e geram aviso |
| Raiz dentro do destino | Recusado (evita o app ler a própria saída) |

O log CSV usa `;` como separador e BOM UTF-8, para abrir direto no Excel/Numbers em português. As colunas são: origem, destino, ação, tamanho (bytes), resultado. Cada linha é gravada na hora em que acontece.

## Estrutura
```
Sources/UnificadorCore/   lógica pura (Foundation + POSIX), testável
  FolderScanner.swift     varredura VID_20* e agrupamento
  DateFolder.swift        VID_AAAAMMDD_HHMMSS → AAMMDD
  Planner.swift           plano / pré-visualização (não grava nada)
  Executor.swift          execução, .partial, retomada, progresso
  FileOps.swift           cópia em blocos, clonefile, rename exclusivo
  Checksum.swift          SHA-256 (CryptoKit no Mac)
  CSVLog.swift            log
Sources/UnificadorVR/     interface SwiftUI
Tests/UnificadorCoreTests XCTest com pastas temporárias
```

## Limitações conhecidas
- As pastas `VID_` que ficam vazias na origem depois de Mover **não** são apagadas.
- A verificação relê o destino com `F_NOCACHE`, mas o firmware do disco ainda pode ter cache próprio.
- Um arquivo que já existe no destino com o mesmo tamanho é considerado completo sem recalcular o checksum (no modo Copiar). Isso é seguro para arquivos gravados pelo app, porque o nome final só aparece depois da verificação.
