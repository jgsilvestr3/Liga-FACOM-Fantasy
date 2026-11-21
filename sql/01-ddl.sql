-- =====================================================================
-- Liga FACOM Fantasy - 01-ddl.sql
-- Criação do esquema e de todas as tabelas do mapeamento relacional.
--
-- Ordem de execução (ver README): 01 -> 02 -> 03 -> 04 -> 05 -> carga -> app.
-- Este script apaga e recria o esquema "fantasy": pode ser rodado de novo
-- sempre que for preciso voltar ao banco vazio.
--
-- Convenções (as mesmas das aulas):
--   pk_ chave primária, fk_ chave estrangeira, uq_ chave candidata
--   ck_ regra de CHECK, tg_/fn_tg_ gatilhos, fn_ funções, sp_ procedimentos
--
-- SOBRE OS TIPOS NUMÉRICOS (exigência 3c do enunciado)
--   Valores em cartoletas (preço, patrimônio) e pontuações usam NUMERIC
--   com casas decimais fixas, nunca REAL/DOUBLE PRECISION. Ponto flutuante
--   guarda o número em base 2 e não representa exatamente valores como
--   0,1 ou 9,84: SELECT 0.1::float8 + 0.2::float8 = 0.3::float8 dá FALSE.
--   Somando preços e variações rodada após rodada, o erro se acumularia e
--   o patrimônio de um técnico poderia virar 99,99999999 em vez de 100,00,
--   fazendo a regra "soma dos preços <= patrimônio" falhar por centavos.
--   NUMERIC faz a conta em base 10, exata, como dinheiro deve ser.
--
--   Cada chave estrangeira tem ON DELETE e ON UPDATE escritos e
--   justificados no comentário logo acima dela. A política geral é:
--   - RESTRICT ao apagar quando a linha referenciada é histórico do
--     campeonato (atleta, clube, rodada, técnico com escalação): apagar
--     mudaria pontuações e rankings já consolidados;
--   - CASCADE ao apagar quando a linha filha é "parte" da mãe e não faz
--     sentido sozinha (atleta da escalação, scout da atuação...);
--   - CASCADE ao atualizar quando a chave é natural e poderia ser
--     corrigida (número da fonte, sigla do scout); NO ACTION quando a chave
--     é gerada pelo banco (IDENTITY), porque ela nunca é alterada.
-- =====================================================================

DROP SCHEMA IF EXISTS fantasy CASCADE;
CREATE SCHEMA fantasy;
COMMENT ON SCHEMA fantasy IS 'Liga FACOM Fantasy - LBD 2026/2';

SET search_path TO fantasy, public;

-- Faz o banco usar o esquema fantasy por padrão em toda nova conexão
-- (psql, pgAdmin, aplicação) e mostrar datas no horário de Brasília, o
-- mesmo das partidas da fonte. Se o usuário não for dono do banco, só avisa.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path TO fantasy, public',
                   current_database());
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L',
                   current_database(), 'America/Sao_Paulo');
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'Sem permissão para ALTER DATABASE: use SET search_path TO fantasy, public;';
END;
$$;


-- =====================================================================
-- PARTE 1-FUTEBOL REAL (dados que vêm da API do Cartola)
-- Chave primária = nmr da propria fonte (ver docs/mapeamento.md):
-- eh estavel, único e já eh usado pela fonte para ligar os objetos
-- (o atleta traz clube_id e posicao_id), então a carga usa esses
-- numeros diretamente e o ON CONFLICT (id) impede duplicação.
-- =====================================================================

-- ---------------------------------------------------------------------
-- POSICAO: as seis posições do Cartola.
-- ---------------------------------------------------------------------
CREATE TABLE posicao (
    id          integer      NOT NULL,
    nome        varchar(20)  NOT NULL,
    abreviacao  char(3)      NOT NULL,
    CONSTRAINT pk_posicao PRIMARY KEY (id),
    CONSTRAINT uq_posicao_abreviacao UNIQUE (abreviacao),
    CONSTRAINT uq_posicao_nome UNIQUE (nome),
    -- o jogo tem exatamente estas seis posições
    CONSTRAINT ck_posicao_abreviacao
        CHECK (abreviacao IN ('gol', 'lat', 'zag', 'mei', 'ata', 'tec'))
);
COMMENT ON TABLE posicao IS 'Posições do Cartola: gol, lat, zag, mei, ata e tec (técnico real).';

-- ---------------------------------------------------------------------
-- SITUACAO: provável, dúvida, suspenso, contundido ou nulo.
-- escalavel é uma coluna gerada: a classificação "pode ser escalado" fica
-- declarada uma única vez, no DDL, e eh usada pelo gatilho de escalação e
-- pela visão do mercado. A regra que IMPEDE escalar fica no gatilho, pq
-- precisa olhar outra tabela (CHECK não consegue).
-- ---------------------------------------------------------------------
CREATE TABLE situacao (
    id         integer      NOT NULL,
    nome       varchar(20)  NOT NULL,
    escalavel  boolean      GENERATED ALWAYS AS (nome IN ('Provável', 'Dúvida')) STORED,
    CONSTRAINT pk_situacao PRIMARY KEY (id),
    CONSTRAINT uq_situacao_nome UNIQUE (nome)
);
COMMENT ON TABLE situacao IS 'Situação informada antes de cada rodada; só Provável e Dúvida podem ser escalados.';

-- ---------------------------------------------------------------------
-- CLUBE: os 20 clubes do Brasileirão.
-- ---------------------------------------------------------------------
CREATE TABLE clube (
    id          integer       NOT NULL,
    nome        varchar(60)   NOT NULL,
    abreviacao  char(3)       NOT NULL,
    escudo_url  varchar(300),
    CONSTRAINT pk_clube PRIMARY KEY (id),
    CONSTRAINT uq_clube_abreviacao UNIQUE (abreviacao),
    -- abreviação de três letras
    CONSTRAINT ck_clube_abreviacao CHECK (abreviacao ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_clube_nome CHECK (btrim(nome) <> '')
);

-- ---------------------------------------------------------------------
-- ATLETA: jogadores e tecnicos reais (o técnico real eh um "atleta" da
-- posiçao tec, exatamente como a fonte o trata).
-- O clube nn fica aqui: ele depende da rodada (tabela atleta_clube_rodada).
-- ---------------------------------------------------------------------
CREATE TABLE atleta (
    id           integer       NOT NULL,
    nome         varchar(120)  NOT NULL,
    apelido      varchar(60)   NOT NULL,
    posicao_id   integer       NOT NULL,
    situacao_id  integer       NOT NULL,
    preco_atual  numeric(6,2)  NOT NULL,
    CONSTRAINT pk_atleta PRIMARY KEY (id),
    -- RESTRICT: n se apaga uma posiçao que ainda tem atletas.
    -- CASCADE no UPDATE: se a fonte renumerar a posição, o atleta acompanha.
    CONSTRAINT fk_atleta_posicao FOREIGN KEY (posicao_id)
        REFERENCES posicao (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- mesma justificativa da posição
    CONSTRAINT fk_atleta_situacao FOREIGN KEY (situacao_id)
        REFERENCES situacao (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- o preço nunca fica abaixo de 1,00
    CONSTRAINT ck_atleta_preco CHECK (preco_atual >= 1.00),
    CONSTRAINT ck_atleta_apelido CHECK (btrim(apelido) <> '')
);
COMMENT ON COLUMN atleta.preco_atual IS 'Preço em cartoletas na rodada aberta (ou na próxima a abrir).';

-- ---------------------------------------------------------------------
-- RODADA: 38 rodadas e o seu estado.
-- tres estados (aberta, fechada, consolidada). Como as
-- 38 rodadas existem desde a carga (as partidas precisam delas), existe um
-- quarto estado, "futura", para a rodada que ainda n foi aberta, sem
-- ele, uma rodada nunca aberta teria de ser fechada e poderia ser
-- consolidada sem ter passado pelo mercado.
-- ---------------------------------------------------------------------
CREATE TABLE rodada (
    numero          integer      NOT NULL,
    estado          varchar(12)  NOT NULL DEFAULT 'futura',
    aberta_em       timestamptz,
    fechada_em      timestamptz,
    consolidada_em  timestamptz,
    CONSTRAINT pk_rodada PRIMARY KEY (numero),
    -- o campeonato tem 38 rodadas
    CONSTRAINT ck_rodada_numero CHECK (numero BETWEEN 1 AND 38),
    CONSTRAINT ck_rodada_estado
        CHECK (estado IN ('futura', 'aberta', 'fechada', 'consolidada')),
    -- as datas acompanham o estado
    CONSTRAINT ck_rodada_aberta_em
        CHECK ((estado = 'futura') = (aberta_em IS NULL)),
    CONSTRAINT ck_rodada_fechada_em
        CHECK ((estado IN ('fechada', 'consolidada')) = (fechada_em IS NOT NULL)),
    CONSTRAINT ck_rodada_consolidada_em
        CHECK ((estado = 'consolidada') = (consolidada_em IS NOT NULL)),
    CONSTRAINT ck_rodada_ordem_datas
        CHECK (aberta_em <= fechada_em AND fechada_em <= consolidada_em)
);
COMMENT ON TABLE rodada IS 'Estados: futura → aberta → fechada → consolidada (ordem garantida por tg_rodada_estado).';

-- indice unico PARCIAL: só as linhas com estado = "aberta" entram no
-- indice, e todas elas tem a mesma chave, ent no maximo uma existe.
-- eh uma regra declarativa (UNIQUE), sem gatilho.
CREATE UNIQUE INDEX uq_rodada_uma_aberta ON rodada (estado) WHERE estado = 'aberta';

-- ---------------------------------------------------------------------
-- PARTIDA: os jogos de cada rodada. O placar e um atributo composto
-- (placar_mandante, placar_visitante) e fica nulo até o jogo acontecer.
-- ---------------------------------------------------------------------
CREATE TABLE partida (
    id                integer       NOT NULL,
    rodada            integer       NOT NULL,
    mandante_id       integer       NOT NULL,
    visitante_id      integer       NOT NULL,
    local             varchar(100)  NOT NULL,
    data_hora         timestamp     NOT NULL,
    placar_mandante   smallint,
    placar_visitante  smallint,
    valida            boolean       NOT NULL DEFAULT true,
    CONSTRAINT pk_partida PRIMARY KEY (id),
    -- RESTRICT: rodada com partidas não some
	-- CASCADE: número natural.
    CONSTRAINT fk_partida_rodada FOREIGN KEY (rodada)
        REFERENCES rodada (numero) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- RESTRICT: apagar um clube apagaria o histórico de jogos.
    CONSTRAINT fk_partida_mandante FOREIGN KEY (mandante_id)
        REFERENCES clube (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_partida_visitante FOREIGN KEY (visitante_id)
        REFERENCES clube (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- chaves candidatas: numa rodada, o mandante identifica a partida, e o
    -- visitante também (cada clube joga uma vez por rodada). O caso
    -- cruzado (mandante numa partida e visitante em outra) não cabe em
    -- UNIQUE e eh barrado pelo gatilho tg_partida_um_jogo_por_rodada.
    CONSTRAINT uq_partida_rodada_mandante UNIQUE (rodada, mandante_id),
    CONSTRAINT uq_partida_rodada_visitante UNIQUE (rodada, visitante_id),
    -- Um clube nunca enfrenta a si mesmo
    CONSTRAINT ck_partida_clubes_distintos CHECK (mandante_id <> visitante_id),
    -- o placar existe dos dois lados ou de nenhum
    CONSTRAINT ck_partida_placar_completo
        CHECK ((placar_mandante IS NULL) = (placar_visitante IS NULL)),
    CONSTRAINT ck_partida_placar_positivo
        CHECK (placar_mandante >= 0 AND placar_visitante >= 0),
    CONSTRAINT ck_partida_local CHECK (btrim(local) <> '')
);
COMMENT ON COLUMN partida.valida IS 'false = partida adiada/não válida para a rodada (marcação da fonte).';
COMMENT ON COLUMN partida.data_hora IS 'Data e hora locais (Brasília), como vêm da fonte.';

-- ---------------------------------------------------------------------
-- ATLETA_CLUBE_RODADA: em qual clube o atleta estava em cada rodada
-- É o relacionamento ternário ATLETA–CLUBE–RODADA: para um par
-- (atleta, rodada) existe exatamente um clube, por isso a chave primária
-- é (atleta_id, rodada) e clube_id é atributo comum.
-- ---------------------------------------------------------------------
CREATE TABLE atleta_clube_rodada (
    atleta_id  integer  NOT NULL,
    rodada     integer  NOT NULL,
    clube_id   integer  NOT NULL,
    CONSTRAINT pk_atleta_clube_rodada PRIMARY KEY (atleta_id, rodada),
    -- RESTRICT: o vínculo é histórico; atleta, rodada e clube não somem.
    -- CASCADE no UPDATE: chaves naturais da fonte.
    CONSTRAINT fk_vinculo_atleta FOREIGN KEY (atleta_id)
        REFERENCES atleta (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_vinculo_rodada FOREIGN KEY (rodada)
        REFERENCES rodada (numero) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_vinculo_clube FOREIGN KEY (clube_id)
        REFERENCES clube (id) ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- ATUACAO: o que a fonte informa sobre o atleta numa rodada já jogada
-- (/atletas/pontuados/{rodada}). Entidade fraca de ATLETA e RODADA.
--   posicao_id - posição em que ele foi pontuado NAQUELA rodada
--   (a posição pode mudar no campeonato: caso real do
--   Dantas, meia na rodada 22 e zagueiro hoje);
--   pontuacao_cartola - valor calculado pelo Cartola, guardado SÓ para
--   conferência (seção 4.3). Nenhum cálculo da liga o usa.
-- A pontuação da liga não é coluna: é derivada dos scouts pela função
-- fn_pontuacao_atleta (decisão justificada em docs/mapeamento.md).
-- A partida em que o atleta jogou também não é coluna: ela é determinada
-- pelo clube do atleta na rodada, porque cada clube joga uma única
-- partida por rodada (guardá-la seria dependência transitiva).
-- ---------------------------------------------------------------------
CREATE TABLE atuacao (
    atleta_id          integer       NOT NULL,
    rodada             integer       NOT NULL,
    posicao_id         integer       NOT NULL,
    entrou_em_campo    boolean       NOT NULL,
    pontuacao_cartola  numeric(6,2),
    CONSTRAINT pk_atuacao PRIMARY KEY (atleta_id, rodada),
    -- só existe atuação se o clube do atleta na rodada é conhecido.
    -- RESTRICT: o vínculo de uma atuação não pode sumir.
    CONSTRAINT fk_atuacao_vinculo FOREIGN KEY (atleta_id, rodada)
        REFERENCES atleta_clube_rodada (atleta_id, rodada)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_atuacao_posicao FOREIGN KEY (posicao_id)
        REFERENCES posicao (id) ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- TIPO_SCOUT: a tabela de pontos
-- ---------------------------------------------------------------------
CREATE TABLE tipo_scout (
    sigla      varchar(2)    NOT NULL,
    descricao  varchar(60)   NOT NULL,
    valor      numeric(4,1)  NOT NULL,
    CONSTRAINT pk_tipo_scout PRIMARY KEY (sigla),
    CONSTRAINT ck_tipo_scout_sigla CHECK (sigla ~ '^[A-Z]{1,2}$'),
    CONSTRAINT ck_tipo_scout_valor CHECK (valor <> 0)
);

-- ---------------------------------------------------------------------
-- TIPO_SCOUT_POSICAO: para quais posições cada scout pontua
-- Um scout sem restrição tem uma linha para
-- cada posição de jogador; SG só tem gol, lat e zag; DE, DP e GS só gol.
-- ---------------------------------------------------------------------
CREATE TABLE tipo_scout_posicao (
    sigla       varchar(2)  NOT NULL,
    posicao_id  integer     NOT NULL,
    CONSTRAINT pk_tipo_scout_posicao PRIMARY KEY (sigla, posicao_id),
    -- CASCADE: a regra de posição é parte do tipo de scout. Sigla corrigida acompanha.
    CONSTRAINT fk_tsp_tipo_scout FOREIGN KEY (sigla)
        REFERENCES tipo_scout (sigla) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tsp_posicao FOREIGN KEY (posicao_id)
        REFERENCES posicao (id) ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- SCOUT: quantas vezes o atleta fez cada ação na rodada.
-- ---------------------------------------------------------------------
CREATE TABLE scout (
    atleta_id   integer     NOT NULL,
    rodada      integer     NOT NULL,
    sigla       varchar(2)  NOT NULL,
    quantidade  smallint    NOT NULL,
    CONSTRAINT pk_scout PRIMARY KEY (atleta_id, rodada, sigla),
    -- CASCADE: o scout é parte da atuação e não existe sem ela
    -- (o gatilho tg_scout_rodada_consolidada ainda impede apagar
    -- qualquer coisa de rodada consolidada).
    CONSTRAINT fk_scout_atuacao FOREIGN KEY (atleta_id, rodada)
        REFERENCES atuacao (atleta_id, rodada) ON DELETE CASCADE ON UPDATE CASCADE,
    -- RESTRICT: não se apaga um tipo de scout que já foi registrado.
    -- CASCADE no UPDATE: se a sigla mudar (o Cartola já trocou DD por DE),
    -- os registros acompanham.
    CONSTRAINT fk_scout_tipo FOREIGN KEY (sigla)
        REFERENCES tipo_scout (sigla) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_scout_quantidade CHECK (quantidade > 0)
);

-- ---------------------------------------------------------------------
-- ESQUEMA: os sete esquemas táticos
-- A quantidade exigida de cada posição é um atributo composto
-- (formação) mapeado em seis colunas, c as quantidades na mesma linha,
-- as regras da seção 2.5 viram check declarativos.
-- ---------------------------------------------------------------------
CREATE TABLE esquema (
    id       integer     NOT NULL,
    nome     varchar(5)  NOT NULL,
    qtd_gol  smallint    NOT NULL,
    qtd_lat  smallint    NOT NULL,
    qtd_zag  smallint    NOT NULL,
    qtd_mei  smallint    NOT NULL,
    qtd_ata  smallint    NOT NULL,
    qtd_tec  smallint    NOT NULL,
    CONSTRAINT pk_esquema PRIMARY KEY (id),
    CONSTRAINT uq_esquema_nome UNIQUE (nome),
    -- "o goleiro e o técnico são sempre um de cada"
    CONSTRAINT ck_esquema_goleiro CHECK (qtd_gol = 1),
    CONSTRAINT ck_esquema_tecnico CHECK (qtd_tec = 1),
    CONSTRAINT ck_esquema_nao_negativo
        CHECK (qtd_lat >= 0 AND qtd_zag >= 0 AND qtd_mei >= 0 AND qtd_ata >= 0),
    -- "formada por 11 atletas e 1 técnico real"
    CONSTRAINT ck_esquema_onze_atletas
        CHECK (qtd_gol + qtd_lat + qtd_zag + qtd_mei + qtd_ata = 11),
    -- "O nome do esquema indica a quantidade de defensores, meias e atacantes"
    CONSTRAINT ck_esquema_nome
        CHECK (nome = (qtd_lat + qtd_zag)::text || '-' || qtd_mei::text || '-' || qtd_ata::text)
);


-- =====================================================================
-- PARTE 2 - O JOGO (dados criados pela liga)
-- Chaves geradas pelo banco (IDENTITY), como na aula de Docker.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TECNICO: a pessoa cadastrada, ja com o seu TIME.
-- No modelo ER, TECNICO e TIME são entidades ligadas por um 1:1 com
-- participação total dos dois lados (cada técnico tem exatamente um
-- time). A regra de mapeamento para esse caso permite fundir as duas
-- numa tabela só, e com isso o "exatamente um" fica garantido por
-- NOT NULL, sem gatilho.
-- ---------------------------------------------------------------------
CREATE TABLE tecnico (
    id             integer       GENERATED ALWAYS AS IDENTITY,
    nome           varchar(100)  NOT NULL,
    email          varchar(254)  NOT NULL,
    apelido        varchar(40)   NOT NULL,
    data_cadastro  timestamptz   NOT NULL DEFAULT now(),
    nome_time      varchar(60)   NOT NULL,
    -- todo técnico começa com C$ 100,00
    patrimonio     numeric(8,2)  NOT NULL DEFAULT 100.00,
    CONSTRAINT pk_tecnico PRIMARY KEY (id),
    -- e-mail não pode se repetir (gravado sempre em minúsculas
    -- pelo gatilho tg_normaliza_tecnico, então a unicidade ignora caixa)
    CONSTRAINT uq_tecnico_email UNIQUE (email),
    CONSTRAINT ck_tecnico_email CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT ck_tecnico_nome CHECK (btrim(nome) <> ''),
    CONSTRAINT ck_tecnico_apelido CHECK (btrim(apelido) <> ''),
    CONSTRAINT ck_tecnico_nome_time CHECK (btrim(nome_time) <> ''),
    -- o patrimônio nunca fica negativo (na prática nem chega perto de 0:
    -- o preço mínimo eh 1,00, então a perda máxima numa rodada é menor
    -- que o próprio patrimônio)
    CONSTRAINT ck_tecnico_patrimonio CHECK (patrimonio >= 0)
);
COMMENT ON TABLE tecnico IS 'Participante do jogo e o seu time (1:1 total, fundidos). Não confundir com o técnico real (atleta da posição tec).';

-- ---------------------------------------------------------------------
-- LIGA
-- ---------------------------------------------------------------------
CREATE TABLE liga (
    id                    integer       GENERATED ALWAYS AS IDENTITY,
    dono_id               integer       NOT NULL,
    nome                  varchar(60)   NOT NULL,
    descricao             varchar(300),
    codigo_convite        varchar(12)   NOT NULL
        DEFAULT upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)),
    limite_participantes  integer       NOT NULL DEFAULT 20,
    publica               boolean       NOT NULL DEFAULT true,
    criada_em             timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT pk_liga PRIMARY KEY (id),
    -- RESTRICT: uma liga não pode ficar sem dono, para apagar o técnico,
    -- antes apaga-se a liga. NO ACTION no UPDATE: o id
    -- do técnico é IDENTITY e nunca muda.
    CONSTRAINT fk_liga_dono FOREIGN KEY (dono_id)
        REFERENCES tecnico (id) ON DELETE RESTRICT ON UPDATE NO ACTION,
    -- código de convite único
    CONSTRAINT uq_liga_codigo_convite UNIQUE (codigo_convite),
    CONSTRAINT ck_liga_codigo_convite CHECK (codigo_convite ~ '^[A-Z0-9]{6,12}$'),
    -- o dono já ocupa uma vaga; uma liga precisa de ao menos 2 técnicos
    CONSTRAINT ck_liga_limite CHECK (limite_participantes >= 2),
    CONSTRAINT ck_liga_nome CHECK (btrim(nome) <> '')
);

-- ---------------------------------------------------------------------
-- PARTICIPACAO: técnico M:N liga, com a data de entrada.
-- A chave primária (liga_id, tecnico_id) garante que ninguém entra duas
-- vezes na mesma liga.
-- ---------------------------------------------------------------------
CREATE TABLE participacao (
    liga_id       integer      NOT NULL,
    tecnico_id    integer      NOT NULL,
    data_entrada  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_participacao PRIMARY KEY (liga_id, tecnico_id),
    -- CASCADE: se a liga for apagada, as participações deixam de existir.
    CONSTRAINT fk_participacao_liga FOREIGN KEY (liga_id)
        REFERENCES liga (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    -- CASCADE: se a conta do técnico for apagada, ele sai das ligas
    -- (o RESTRICT de escalação e de liga.dono ainda protege o histórico).
    CONSTRAINT fk_participacao_tecnico FOREIGN KEY (tecnico_id)
        REFERENCES tecnico (id) ON DELETE CASCADE ON UPDATE NO ACTION
);

-- ---------------------------------------------------------------------
-- ESCALACAO: o time de um técnico numa rodada (entidade fraca de TECNICO
-- e RODADA). A chave (tecnico_id, rodada) garante a regra "no máximo uma
-- escalação por técnico por rodada" sem gatilho.
--   capitao_id - capitão escolhido (nulo durante a edição)
--   pontuacao - gravada na consolidação: é o resultado oficial
--   variacao_patrimonio - idem: quanto o patrimônio mudou por causa dela
-- ---------------------------------------------------------------------
CREATE TABLE escalacao (
    tecnico_id           integer       NOT NULL,
    rodada               integer       NOT NULL,
    esquema_id           integer       NOT NULL,
    capitao_id           integer,
    status               varchar(10)   NOT NULL DEFAULT 'em_edicao',
    criada_em            timestamptz   NOT NULL DEFAULT now(),
    confirmada_em        timestamptz,
    pontuacao            numeric(7,2),
    variacao_patrimonio  numeric(7,2),
    CONSTRAINT pk_escalacao PRIMARY KEY (tecnico_id, rodada),
    -- RESTRICT: apagar um técnico com escalações mudaria rankings já
    -- definitivos. NO ACTION no UPDATE: id IDENTITY não muda.
    CONSTRAINT fk_escalacao_tecnico FOREIGN KEY (tecnico_id)
        REFERENCES tecnico (id) ON DELETE RESTRICT ON UPDATE NO ACTION,
    -- RESTRICT: rodada é histórico. CASCADE: número natural.
    CONSTRAINT fk_escalacao_rodada FOREIGN KEY (rodada)
        REFERENCES rodada (numero) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- RESTRICT: não se apaga um esquema usado por alguma escalação.
    CONSTRAINT fk_escalacao_esquema FOREIGN KEY (esquema_id)
        REFERENCES esquema (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_escalacao_status CHECK (status IN ('em_edicao', 'confirmada')),
    -- a escalação registra quando foi confirmada
    CONSTRAINT ck_escalacao_confirmada_em
        CHECK ((status = 'confirmada') = (confirmada_em IS NOT NULL)),
    -- toda escalação confirmada tem capitão
    CONSTRAINT ck_escalacao_capitao_confirmada
        CHECK (status = 'em_edicao' OR capitao_id IS NOT NULL),
    -- só escalações confirmadas pontuam (e só elas mexem no
    -- patrimônio)
    CONSTRAINT ck_escalacao_pontua_se_confirmada
        CHECK (pontuacao IS NULL OR status = 'confirmada'),
    CONSTRAINT ck_escalacao_variacao_se_confirmada
        CHECK (variacao_patrimonio IS NULL OR status = 'confirmada')
);

-- ---------------------------------------------------------------------
-- ESCALACAO_ATLETA: os 12 escolhidos (11 atletas + 1 técnico real) e o
-- preço pago por cada um.
-- A chave (tecnico_id, rodada, atleta_id) impede o mesmo atleta duas
-- vezes na mesma escalação.
-- ---------------------------------------------------------------------
CREATE TABLE escalacao_atleta (
    tecnico_id  integer       NOT NULL,
    rodada      integer       NOT NULL,
    atleta_id   integer       NOT NULL,
    preco_pago  numeric(6,2)  NOT NULL,
    CONSTRAINT pk_escalacao_atleta PRIMARY KEY (tecnico_id, rodada, atleta_id),
    -- CASCADE: os atletas escolhidos são parte da escalação.
    CONSTRAINT fk_escalacao_atleta_escalacao FOREIGN KEY (tecnico_id, rodada)
        REFERENCES escalacao (tecnico_id, rodada) ON DELETE CASCADE ON UPDATE CASCADE,
    -- RESTRICT: um atleta que já foi escalado não pode sumir do banco.
    CONSTRAINT fk_escalacao_atleta_atleta FOREIGN KEY (atleta_id)
        REFERENCES atleta (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_escalacao_atleta_preco CHECK (preco_pago >= 1.00)
);

-- Capitão: chave estrangeira COMPOSTA para os atletas da própria
-- escalação. Com isso, "o capitão é um dos atletas escalados" vira regra
-- declarativa: não dá para apontar um capitão que não está no time.
-- ON DELETE SET NULL (capitao_id): se o capitão for removido do time
-- (só possível em edição), a escolha de capitão é desfeita; a lista de
-- colunas no SET NULL existe desde o PostgreSQL 15 e evita anular
-- tecnico_id e rodada, que fazem parte da chave.
-- ON UPDATE CASCADE: se o atleta capitão for trocado por UPDATE, a
-- braçadeira passa ao substituto (o gatilho confere se ele pode ser capitão).
-- A FK é criada aqui, depois das duas tabelas, porque uma referencia a outra.
ALTER TABLE escalacao
    ADD CONSTRAINT fk_escalacao_capitao FOREIGN KEY (tecnico_id, rodada, capitao_id)
        REFERENCES escalacao_atleta (tecnico_id, rodada, atleta_id)
        ON DELETE SET NULL (capitao_id) ON UPDATE CASCADE;

-- ---------------------------------------------------------------------
-- HISTORICO_PRECO: o preço de cada atleta em cada rodada consolidada. 
-- Gravado pelo procedimento de consolidação.
-- preco_rodada - preço que valia enquanto a rodada estava aberta
-- preco_novo - preço depois da valorização da rodada
-- ---------------------------------------------------------------------
CREATE TABLE historico_preco (
    atleta_id     integer       NOT NULL,
    rodada        integer       NOT NULL,
    preco_rodada  numeric(6,2)  NOT NULL,
    preco_novo    numeric(6,2)  NOT NULL,
    CONSTRAINT pk_historico_preco PRIMARY KEY (atleta_id, rodada),
    -- RESTRICT: histórico não pode perder o atleta nem a rodada.
    CONSTRAINT fk_historico_atleta FOREIGN KEY (atleta_id)
        REFERENCES atleta (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_historico_rodada FOREIGN KEY (rodada)
        REFERENCES rodada (numero) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- seção 2.8: preço mínimo de C$ 1,00 e variação limitada a ±1,50
    CONSTRAINT ck_historico_preco_minimo CHECK (preco_rodada >= 1.00 AND preco_novo >= 1.00),
    CONSTRAINT ck_historico_variacao CHECK (abs(preco_novo - preco_rodada) <= 1.50)
);


-- =====================================================================
-- PARTE 3 - MENSAGENS LEGÍVEIS DAS RESTRIÇÕES
-- Uma violação de CHECK, UNIQUE ou FK devolve uma mensagem técnica em
-- inglês. Para a aplicação mostrar algo claro ao técnico sem repetir
-- regras em código, a mensagem em português fica no próprio banco, como
-- comentário da restrição. A aplicação lê esse comentário pela função
-- fn_mensagem_restricao (03-programacao.sql).
-- =====================================================================
COMMENT ON CONSTRAINT uq_tecnico_email ON tecnico IS 'Já existe um técnico cadastrado com este e-mail.';
COMMENT ON CONSTRAINT ck_tecnico_email ON tecnico IS 'E-mail inválido: use o formato nome@dominio.com.';
COMMENT ON CONSTRAINT ck_tecnico_nome ON tecnico IS 'O nome do técnico não pode ficar em branco.';
COMMENT ON CONSTRAINT ck_tecnico_apelido ON tecnico IS 'O apelido não pode ficar em branco.';
COMMENT ON CONSTRAINT ck_tecnico_nome_time ON tecnico IS 'O nome do time não pode ficar em branco.';
COMMENT ON CONSTRAINT ck_tecnico_patrimonio ON tecnico IS 'O patrimônio não pode ficar negativo.';
COMMENT ON CONSTRAINT ck_liga_limite ON liga IS 'O limite de participantes da liga deve ser de pelo menos 2.';
COMMENT ON CONSTRAINT ck_liga_nome ON liga IS 'O nome da liga não pode ficar em branco.';
COMMENT ON CONSTRAINT uq_liga_codigo_convite ON liga IS 'Já existe uma liga com este código de convite.';
COMMENT ON CONSTRAINT ck_liga_codigo_convite ON liga IS 'O código de convite deve ter de 6 a 12 letras maiúsculas ou dígitos.';
COMMENT ON CONSTRAINT fk_liga_dono ON liga IS 'O dono da liga precisa ser um técnico cadastrado.';
COMMENT ON CONSTRAINT pk_participacao ON participacao IS 'Este técnico já participa desta liga.';
COMMENT ON CONSTRAINT pk_escalacao ON escalacao IS 'Você já tem uma escalação nesta rodada.';
COMMENT ON CONSTRAINT fk_escalacao_esquema ON escalacao IS 'Esquema tático inexistente.';
COMMENT ON CONSTRAINT fk_escalacao_rodada ON escalacao IS 'Rodada inexistente.';
COMMENT ON CONSTRAINT fk_escalacao_tecnico ON escalacao IS 'Técnico inexistente.';
COMMENT ON CONSTRAINT fk_escalacao_capitao ON escalacao IS 'O capitão precisa ser um dos atletas da sua escalação.';
COMMENT ON CONSTRAINT ck_escalacao_capitao_confirmada ON escalacao IS 'Uma escalação confirmada precisa ter capitão.';
COMMENT ON CONSTRAINT pk_escalacao_atleta ON escalacao_atleta IS 'Este atleta já está na sua escalação.';
COMMENT ON CONSTRAINT fk_escalacao_atleta_atleta ON escalacao_atleta IS 'Atleta inexistente.';
COMMENT ON CONSTRAINT fk_escalacao_atleta_escalacao ON escalacao_atleta IS 'Crie a escalação (escolha o esquema) antes de incluir atletas.';
COMMENT ON INDEX uq_rodada_uma_aberta IS 'Já existe uma rodada aberta: feche o mercado dela antes de abrir outra.';