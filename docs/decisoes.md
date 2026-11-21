# Liga FACOM Fantasy · Decisões de projeto

Decisões em que mais de uma alternativa seria válida (item 2 do enunciado). Cada uma é citada pelo código (D1, D2...) no [mapeamento.md](mapeamento.md).

**D1. Números da fonte como chave primária** (clube, atleta, posição, situação, partida, esquema).
Alternativa: chave substituta (IDENTITY) e o número da fonte como chave candidata (UNIQUE).
Escolhemos a PK porque a fonte é a única origem desses dados, o número é estável e único, e a própria fonte já o usa para ligar os objetos (o atleta vem com clube_id e posicao_id). Com isso a carga grava as FKs sem tabela de-para e o ON CONFLICT (id) impede duplicar (seção 3 do enunciado: "atualizar a base sem duplicar nada"). Para as entidades criadas pela liga (técnico, liga), que não têm número externo, a chave é gerada pelo banco (IDENTITY).

**D2. Pontuação do atleta na rodada: NÃO armazenada.**
Ela é derivada dos scouts e calculada sempre pela função fn_pontuacao_atleta (item 6a); a visão vw_pontuacao_rodada a entrega pronta, como a idade no exemplo da aula de views.
Para que o valor calculado nunca mude depois da consolidação, o gatilho do item 6(d), tg_scout_rodada_consolidada, impede incluir, alterar ou remover scouts de rodada consolidada. A mesma função congela tudo de que a pontuação depende: atuação, partida (placar do técnico real), clube do atleta na rodada e a tabela de pontos.
Alternativa: guardar a pontuação na atuação e mantê-la por gatilho. Isso teria custo de manutenção (scouts, placar, posição) e risco de valor desatualizado.

**D3. Pontuação da escalação e variação do patrimônio: armazenadas, mas só na consolidação.**
São o resultado oficial da rodada ("o ranking ficou definitivo"). Sem elas, cada ranking recalcularia 12 atletas × todas as rodadas de todos os técnicos. Elas não ficam desatualizadas porque tudo de que dependem está congelado depois da consolidação (D2 e gatilhos da escalação). A coerência é conferida nos testes: pontuacao = fn_pontuacao_escalacao(...).

**D4. Patrimônio armazenado** em TECNICO: o minimundo pede "o patrimônio atual". A evolução rodada a rodada é derivada de variacao_patrimonio (consulta (i)), e a última linha da evolução bate com o patrimônio atual.

**D5. Preço atual em ATLETA e histórico em HISTORICO_PRECO.**
preco_atual repete o preco_novo da última rodada consolidada. É uma redundância controlada: só a consolidação altera os dois, na mesma transação, e o mercado não precisa procurar a última linha do histórico. preco_novo também repete o preco_rodada da rodada seguinte, mas fica guardado como o fato da valorização daquela rodada (permite o CHECK abs(preco_novo - preco_rodada) <= 1.50).

**D6. Média do atleta: não armazenada** (fn_media_atleta, visões). Ela muda a cada rodada consolidada.

**D7. qtd_participantes e pontuacao_acumulada: não armazenadas** (contagem na hora e vw_pontuacao_acumulada).

**D8. situacao.escalavel como coluna gerada** (GENERATED ALWAYS AS (nome IN ('Provável','Dúvida')) STORED). A classificação fica declarada uma vez só, no DDL, e o banco a mantém sozinho. A regra que impede escalar continua no gatilho 6(c), porque precisa olhar outra tabela.

**D9. TECNICO e TIME fundidos** (passo 3, 1:1 total dos dois lados). Alternativa: duas tabelas com FK UNIQUE. A fusão garante "cada técnico tem exatamente um time" só com NOT NULL, sem gatilho.

**D10. Esquema com seis colunas de quantidade** (atributo composto). Alternativa: tabela ESQUEMA_POSICAO(esquema, posição, quantidade). Com as quantidades na mesma linha, as regras da seção 2.5 viram CHECKs: goleiro = 1, técnico = 1, 11 atletas e nome coerente com as quantidades.

**D11. Clube do atleta: uma linha por atleta por rodada** (38 rodadas). Alternativa: intervalos de vigência (rodada_inicio, rodada_fim), que exigiriam restrição de exclusão para não haver sobreposição.
As linhas vêm de observações exatas: o clube em /atletas/pontuados/{rodada} e o clube atual do mercado. Nas rodadas sem observação, vale o último clube observado antes; antes da primeira observação, o primeiro clube observado. A carga documenta essa inferência.

**D12. A partida da atuação não é coluna** (ver a normalização no mapeamento.md): cada clube joga uma vez por rodada, regra garantida pelas UNIQUE (rodada, mandante_id) e (rodada, visitante_id) e pelo gatilho tg_partida_um_jogo_por_rodada. A carga "descobre" a partida cruzando os endpoints e só registra a atuação se o clube tiver partida na rodada.

**D13. Posição guardada na atuação.** A posição pode mudar durante o campeonato (caso real: Dantas, meia na rodada 22 e zagueiro hoje). Como SG só pontua para goleiro, lateral e zagueiro, a pontuação de uma rodada usa a posição daquela rodada. É um fato histórico da fonte, não uma cópia de atleta.posicao_id.

**D14. Estado futura** além de aberta, fechada e consolidada. As 38 rodadas existem desde a carga (as partidas precisam delas), e sem esse estado a rodada nunca aberta teria de ser "fechada", podendo ser consolidada sem passar pelo mercado.

**D15. Capitão como FK composta** (tecnico_id, rodada, capitao_id) → ESCALACAO_ATLETA. Alternativa: coluna booleana capitao em ESCALACAO_ATLETA com índice único parcial. A FK composta torna declarativos o "no máximo um capitão" (uma coluna), o "o capitão está na escalação" (FK) e o "confirmada tem capitão" (CHECK). ON DELETE SET NULL (capitao_id), recurso do PostgreSQL 15+, desfaz a escolha se o capitão sair do time.

**D16. Preço mínimo na carga.** A API traz 15 atletas com preço abaixo de C$ 1,00, e a seção 2.8 diz que o preço nunca fica abaixo disso. A carga aplica o piso (greatest(preco, 1.00)), e o CHECK preco_atual >= 1.00 vale sempre.

**D17. Rodadas rejogadas em ordem.** Só se abre uma rodada se nenhuma outra estiver aberta ou fechada (o mercado reabre depois da consolidação, como no Cartola) e se ela for posterior à última consolidada. Isso deixa bem definidas a "média antes da rodada" e as "últimas 5 rodadas consolidadas".
