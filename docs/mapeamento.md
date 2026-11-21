# Liga FACOM Fantasy · Mapeamento ER

As decisões citadas como D1, D2... estão explicadas em [decisoes.md](decisoes.md).

| Passo | Regra |
|---|---|
| 1 | Entidade regular → tabela com os atributos simples (atributo composto entra pelos componentes) |
| 2 | Entidade fraca → tabela com a chave do(s) dono(s) como FK; PK = chave do(s) dono(s) + chave parcial |
| 3 | Relacionamento 1:1 → FK no lado de participação total, ou **fusão** das duas entidades quando a participação é total dos dois lados |
| 4 | Relacionamento 1:N → FK no lado N |
| 5 | Relacionamento M:N → tabela própria com as duas FKs (PK composta) e os atributos do relacionamento |
| 6 | Atributo multivalorado → tabela própria |
| 7 | Relacionamento n-ário → tabela com uma FK por entidade; a PK é formada pelas FKs dos lados "N" |

Atributos **derivados** não viram coluna, salvo quando a decisão está justificada em [decisoes.md](decisoes.md).

---

## 1. Esquema relacional

### Futebol real (dados da API do Cartola)

**POSICAO**(<ins>id</ins>, nome, abreviacao)
Passo 1 (entidade POSICAO). Chaves candidatas: nome, abreviacao.

**SITUACAO**(<ins>id</ins>, nome, escalavel)
Passo 1 (entidade SITUACAO). escalavel é o atributo derivado do ER, guardado como **coluna gerada** (D8).

**CLUBE**(<ins>id</ins>, nome, abreviacao, escudo_url)
Passo 1. Chave candidata: abreviacao.

**ATLETA**(<ins>id</ins>, nome, apelido, preco_atual, posicao_id → POSICAO, situacao_id → SITUACAO)
Passo 1 (entidade ATLETA) + passo 4 (JOGA_COMO e ESTÁ_EM são N:1; a FK fica no lado N, o atleta).
media (derivado) não é coluna: é calculado pela função fn_media_atleta e pelas visões (D6).

**RODADA**(<ins>numero</ins>, estado, aberta_em, fechada_em, consolidada_em)
Passo 1. O estado futura foi acrescentado (D14).

**PARTIDA**(<ins>id</ins>, rodada → RODADA, mandante_id → CLUBE, visitante_id → CLUBE, local, data_hora, placar_mandante, placar_visitante, valida)
Passo 1 (o atributo composto placar entra pelos dois componentes) + passo 4 (TEM, MANDANTE e VISITANTE são 1:N; as FKs ficam na partida). Chaves candidatas: (rodada, mandante_id) e (rodada, visitante_id).

**ATLETA_CLUBE_RODADA**(<ins>atleta_id → ATLETA, rodada → RODADA</ins>, clube_id → CLUBE)
Passo 7 (relacionamento ternário DEFENDE). Como para cada par (atleta, rodada) existe **um** clube (cardinalidade 1 do lado de CLUBE), a PK é só (atleta_id, rodada) e clube_id é FK comum (D11).

**ATUACAO**(<ins>atleta_id, rodada</ins>, posicao_id → POSICAO, entrou_em_campo, pontuacao_cartola)
(atleta_id, rodada) → ATLETA_CLUBE_RODADA
Passo 2 (entidade fraca de ATLETA e RODADA: a PK é a chave dos dois donos) + passo 4 (ATUOU_COMO, N:1).
Refinamento: as duas chaves do dono formam uma única FK composta para ATLETA_CLUBE_RODADA, que por sua vez referencia ATLETA e RODADA. Assim, só existe atuação de quem tem clube conhecido na rodada (D12). A posição fica na atuação porque pode mudar durante o campeonato (D13).
pontuacao (derivado) não é coluna (D2).

**TIPO_SCOUT**(<ins>sigla</ins>, descricao, valor)
Passo 1.

**TIPO_SCOUT_POSICAO**(<ins>sigla → TIPO_SCOUT, posicao_id → POSICAO</ins>)
Passo 5 (PONTUA_PARA, M:N).

**SCOUT**(<ins>atleta_id, rodada, sigla → TIPO_SCOUT</ins>, quantidade)
(atleta_id, rodada) → ATUACAO
Passo 5 (REGISTRA, M:N entre ATUACAO e TIPO_SCOUT, com o atributo quantidade).

**ESQUEMA**(<ins>id</ins>, nome, qtd_gol, qtd_lat, qtd_zag, qtd_mei, qtd_ata, qtd_tec)
Passo 1 (o atributo composto formacao entra pelos seis componentes, D10). Chave candidata: nome.

### O jogo (dados da liga)

**TECNICO**(<ins>id</ins>, nome, email, apelido, data_cadastro, nome_time, patrimonio)
Passo 1 (entidade TECNICO) + passo 3 (POSSUI é 1:1 com participação total dos dois lados: TECNICO e TIME foram **fundidos**, D9; nome_time e patrimonio são os atributos de TIME). Chave candidata: email.
pontuacao_acumulada (derivado, de TIME) vira a visão vw_pontuacao_acumulada (D7). O patrimônio é armazenado (D4).

**LIGA**(<ins>id</ins>, dono_id → TECNICO, nome, descricao, codigo_convite, limite_participantes, publica, criada_em)
Passo 1 + passo 4 (CRIA, 1:N: a FK dono_id fica na liga). Chave candidata: codigo_convite.
qtd_participantes (derivado) é contado na hora (D7).

**PARTICIPACAO**(<ins>liga_id → LIGA, tecnico_id → TECNICO</ins>, data_entrada)
Passo 5 (PARTICIPA, M:N com o atributo data_entrada).

**ESCALACAO**(<ins>tecnico_id → TECNICO, rodada → RODADA</ins>, esquema_id → ESQUEMA, capitao_id, status, criada_em, confirmada_em, pontuacao, variacao_patrimonio)
(tecnico_id, rodada, capitao_id) → ESCALACAO_ATLETA
Passo 2 (entidade fraca de TIME e RODADA; como TIME foi fundido em TECNICO, a chave do dono é tecnico.id) + passo 4 (SEGUE e CAPITÃO são N:1).
O capitão referencia a própria escalação por FK composta (D15). pontuacao e variacao_patrimonio são derivados **armazenados na consolidação** (D3).

**ESCALACAO_ATLETA**(<ins>tecnico_id, rodada, atleta_id → ATLETA</ins>, preco_pago)
(tecnico_id, rodada) → ESCALACAO
Passo 5 (ESCALA, M:N com o atributo preco_pago).

**HISTORICO_PRECO**(<ins>atleta_id → ATLETA, rodada → RODADA</ins>, preco_rodada, preco_novo)
Passo 5 (VALE, M:N entre ATLETA e RODADA, com os atributos de preço, D5).

**Não houve passo 6**: o modelo não tem atributo multivalorado. O candidato natural ("as posições em que um scout vale") virou o relacionamento PONTUA_PARA, porque posição é entidade, tem número próprio na fonte e é referenciada por outras tabelas.

---

## 2. Normalização

Todas as tabelas estão na **3FN**: toda dependência funcional parte de uma chave candidata. Os pontos em que seria fácil criar redundância foram evitados de propósito:

- a partida de uma atuação **não** é guardada na atuação. Ela é determinada por (clube do atleta na rodada, rodada), e guardá-la criaria a dependência transitiva (atleta, rodada) → clube → partida (D12);
- o clube do atleta **não** fica em ATLETA, porque depende da rodada;
- a pontuação do atleta **não** é guardada, porque depende só dos scouts (D2).

---
