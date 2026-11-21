-- 03-programacao.sql
-- Funções, gatilhos e procedimentos (item 6).
--   6(a) fn_pontuacao_atleta          pontos do atleta na rodada
--   6(b) fn_pontuacao_escalacao       pontos da escalação
--   6(c) tg_escalacao_atleta_valida   regras ao mexer nos atletas do time
--   6(d) tg_scout_rodada_consolidada  scout de rodada consolidada não muda
--   6(e) sp_confirmar_escalacao       confirma a escalação
--   6(f) sp_entrar_liga               técnico entra numa liga
--   6(g) sp_consolidar_rodada         consolida a rodada

SET search_path TO fantasy, public;

-- PARTE 1 - FUNÇÕES DE APOIO
CREATE OR REPLACE FUNCTION fn_qtd_exigida(p_esquema_id integer, p_posicao_id integer)
RETURNS integer AS $$
DECLARE
    v_esquema  esquema%ROWTYPE;
    v_abrev    posicao.abreviacao%TYPE;
BEGIN
    SELECT * INTO v_esquema FROM esquema WHERE id = p_esquema_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esquema tático % não existe', p_esquema_id;
    END IF;

    SELECT abreviacao INTO v_abrev FROM posicao WHERE id = p_posicao_id;

    RETURN CASE v_abrev
 WHEN 'gol' THEN v_esquema.qtd_gol
 WHEN 'lat' THEN v_esquema.qtd_lat
 WHEN 'zag' THEN v_esquema.qtd_zag
  WHEN 'mei' THEN v_esquema.qtd_mei
 WHEN 'ata' THEN v_esquema.qtd_ata
  WHEN 'tec' THEN v_esquema.qtd_tec
               ELSE 0
           END;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION fn_cartoleta(p_valor numeric)
RETURNS text AS $$
BEGIN
    RETURN 'C$ ' || replace(to_char(p_valor, 'FM999990.00'), '.', ',');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_rodada_aberta()
RETURNS integer AS $$
DECLARE
    v_numero integer;
BEGIN
    SELECT numero INTO v_numero FROM rodada WHERE estado = 'aberta';
    RETURN v_numero;
END;
$$ LANGUAGE plpgsql STABLE;

-- fn_mensagem_restricao: mensagem amigável de uma CHECK/UNIQUE/FK.
-- Ela fica no COMMENT da restrição
CREATE OR REPLACE FUNCTION fn_mensagem_restricao(p_tabela text, p_restricao text)
RETURNS text AS $$
DECLARE
    v_mensagem text;
BEGIN
    SELECT obj_description(c.oid, 'pg_constraint') INTO v_mensagem
      FROM pg_constraint c
     WHERE c.conname = p_restricao
       AND c.conrelid = to_regclass('fantasy.' || p_tabela);

    IF v_mensagem IS NULL THEN
        v_mensagem := obj_description(to_regclass('fantasy.' || p_restricao), 'pg_class');
    END IF;
    RETURN v_mensagem;
END;
$$ LANGUAGE plpgsql STABLE;

-- fn_codigo_convite: código de convite da liga, só para o dono.
-- A aplicação não lê essa coluna direto, por isso a função é SECURITY DEFINER.
CREATE OR REPLACE FUNCTION fn_codigo_convite(p_liga_id integer, p_tecnico_id integer)
RETURNS varchar AS $$
DECLARE
    v_codigo liga.codigo_convite%TYPE;
BEGIN
    SELECT codigo_convite INTO v_codigo
      FROM liga
     WHERE id = p_liga_id AND dono_id = p_tecnico_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Só o dono da liga pode ver o código de convite';
    END IF;
    RETURN v_codigo;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- PARTE 2 - CÁLCULO DE PONTOS E DE PREÇOS
-- A pontuação não é guardada: sai sempre dos scouts. O gatilho 6(d)
-- garante que ela não muda depois da consolidação.

-- fn_pontuacao_tecnico: vitória 5, empate 2, derrota ou sem jogo 0.
-- Só pontua quem comandava o clube na rodada
-- Partida adiada conta como sem jogo.
CREATE OR REPLACE FUNCTION fn_pontuacao_tecnico(p_atleta_id integer, p_rodada integer)
RETURNS numeric AS $$
DECLARE
    v_clube_id      integer;
    v_partida       partida%ROWTYPE;
    v_gols_pro      integer;
    v_gols_contra   integer;
BEGIN
    PERFORM 1 FROM atuacao
     WHERE atleta_id = p_atleta_id AND rodada = p_rodada AND entrou_em_campo;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    SELECT clube_id INTO v_clube_id
      FROM atleta_clube_rodada
     WHERE atleta_id = p_atleta_id AND rodada = p_rodada;

    SELECT * INTO v_partida
      FROM partida
     WHERE rodada = p_rodada
       AND valida
       AND placar_mandante IS NOT NULL
       AND v_clube_id IN (mandante_id, visitante_id);
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    IF v_partida.mandante_id = v_clube_id THEN
        v_gols_pro    := v_partida.placar_mandante;
        v_gols_contra := v_partida.placar_visitante;
    ELSE
        v_gols_pro    := v_partida.placar_visitante;
        v_gols_contra := v_partida.placar_mandante;
    END IF;

    IF v_gols_pro > v_gols_contra THEN
        RETURN 5;
    ELSIF v_gols_pro = v_gols_contra THEN
        RETURN 2;
    ELSE
        RETURN 0;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- 6(a) fn_pontuacao_atleta: soma quantidade * valor dos scouts que
-- valem para a posição do atleta na rodada. Não jogou, zero.
-- SELECT fn_pontuacao_atleta(100084, 31); 12.4 (Igor Gomes)
CREATE OR REPLACE FUNCTION fn_pontuacao_atleta(p_atleta_id integer, p_rodada integer)
RETURNS numeric AS $$
DECLARE
    v_atuacao  atuacao%ROWTYPE;
    v_abrev    posicao.abreviacao%TYPE;
    v_pontos   numeric(6,2);
BEGIN
    SELECT * INTO v_atuacao
      FROM atuacao
     WHERE atleta_id = p_atleta_id AND rodada = p_rodada;

    IF NOT FOUND OR NOT v_atuacao.entrou_em_campo THEN
        RETURN 0;
    END IF;

    SELECT abreviacao INTO v_abrev FROM posicao WHERE id = v_atuacao.posicao_id;
    IF v_abrev = 'tec' THEN
        v_pontos := fn_pontuacao_tecnico(p_atleta_id, p_rodada);
        RETURN v_pontos;
    END IF;

    SELECT coalesce(sum(s.quantidade * ts.valor), 0)
      INTO v_pontos
      FROM scout s
      JOIN tipo_scout ts
        ON ts.sigla = s.sigla
      JOIN tipo_scout_posicao tsp
        ON tsp.sigla = s.sigla
       AND tsp.posicao_id = v_atuacao.posicao_id
     WHERE s.atleta_id = p_atleta_id
       AND s.rodada = p_rodada;

    RETURN v_pontos;
END;
$$ LANGUAGE plpgsql STABLE;

-- 6(b) fn_pontuacao_escalacao: soma dos 12 escolhidos, capitão * 1,5.
-- Escalação não confirmada faz zero.
CREATE OR REPLACE FUNCTION fn_pontuacao_escalacao(p_tecnico_id integer, p_rodada integer)
RETURNS numeric AS $$
DECLARE
    c_multiplicador_capitao  CONSTANT numeric := 1.5;
    v_escalacao  escalacao%ROWTYPE;
    v_item       RECORD;
    v_pontos     numeric(7,2);
    v_total      numeric(7,2) := 0;
BEGIN
    SELECT * INTO v_escalacao
      FROM escalacao
     WHERE tecnico_id = p_tecnico_id AND rodada = p_rodada;

    IF NOT FOUND OR v_escalacao.status <> 'confirmada' THEN
        RETURN 0;
    END IF;

    FOR v_item IN
        SELECT atleta_id
          FROM escalacao_atleta
         WHERE tecnico_id = p_tecnico_id AND rodada = p_rodada
    LOOP
        v_pontos := fn_pontuacao_atleta(v_item.atleta_id, p_rodada);
        IF v_item.atleta_id = v_escalacao.capitao_id THEN
            v_pontos := v_pontos * c_multiplicador_capitao;
        END IF;
        v_total := v_total + v_pontos;
    END LOOP;

    RETURN v_total;
END;
$$ LANGUAGE plpgsql STABLE;

-- fn_media_atleta: média nas rodadas consolidadas em que o atleta jogou.
-- Com p_antes_da_rodada, só as anteriores a ela. NULL se não houver.
CREATE OR REPLACE FUNCTION fn_media_atleta(p_atleta_id integer,
                                           p_antes_da_rodada integer DEFAULT NULL)
RETURNS numeric AS $$
DECLARE
    v_media numeric;
BEGIN
    SELECT avg(fn_pontuacao_atleta(a.atleta_id, a.rodada))
      INTO v_media
      FROM atuacao a
      JOIN rodada r ON r.numero = a.rodada
     WHERE a.atleta_id = p_atleta_id
       AND a.entrou_em_campo
       AND r.estado = 'consolidada'
       AND (p_antes_da_rodada IS NULL OR a.rodada < p_antes_da_rodada);
    RETURN v_media;
END;
$$ LANGUAGE plpgsql STABLE;

-- fn_variacao_preco: 0,10 * (pontos - média), entre -1,50 e +1,50.
-- Sem média, zero. O piso de C$ 1,00 entra na consolidação.
--   SELECT fn_variacao_preco(12.4, 4.0);  -- 0.84
CREATE OR REPLACE FUNCTION fn_variacao_preco(p_pontuacao numeric, p_media numeric)
RETURNS numeric AS $$
DECLARE
    c_fator    CONSTANT numeric := 0.10;
    c_limite   CONSTANT numeric := 1.50;
    v_variacao numeric;
BEGIN
    IF p_media IS NULL THEN
        RETURN 0;
    END IF;
    v_variacao := c_fator * (p_pontuacao - p_media);
    v_variacao := greatest(-c_limite, least(c_limite, v_variacao));
    RETURN round(v_variacao, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- fn_problemas_escalacao: lista o que impede a confirmação
-- Usada pelo 6(e) e pelo gatilho da escalação.
-- Esquema e capitão vêm por parâmetro porque, no BEFORE, a tabela ainda tem os valores antigos.
CREATE OR REPLACE FUNCTION fn_problemas_escalacao(p_tecnico_id integer, p_rodada integer,
                                                  p_esquema_id integer, p_capitao_id integer)
RETURNS text AS $$
DECLARE
    v_problemas   text[] := '{}';
    v_posicao     RECORD;
    v_cap_posicao posicao.abreviacao%TYPE;
    v_cap_apelido atleta.apelido%TYPE;
    v_total       numeric(8,2);
    v_patrimonio  tecnico.patrimonio%TYPE;
BEGIN
    FOR v_posicao IN
        SELECT p.nome,
               fn_qtd_exigida(p_esquema_id, p.id) AS exigida,
               (SELECT count(*)
                  FROM escalacao_atleta ea
                  JOIN atleta a ON a.id = ea.atleta_id
                 WHERE ea.tecnico_id = p_tecnico_id
                   AND ea.rodada = p_rodada
                   AND a.posicao_id = p.id) AS escolhidos
          FROM posicao p
         ORDER BY p.id
    LOOP
        IF v_posicao.escolhidos < v_posicao.exigida THEN
            v_problemas := v_problemas || format('falta(m) %s %s',
                               v_posicao.exigida - v_posicao.escolhidos, lower(v_posicao.nome));
        ELSIF v_posicao.escolhidos > v_posicao.exigida THEN
            v_problemas := v_problemas || format('sobra(m) %s %s',
                               v_posicao.escolhidos - v_posicao.exigida, lower(v_posicao.nome));
        END IF;
    END LOOP;

    IF p_capitao_id IS NULL THEN
        v_problemas := v_problemas || 'nenhum capitão escolhido'::text;
    ELSE
        SELECT p.abreviacao, a.apelido INTO v_cap_posicao, v_cap_apelido
          FROM atleta a JOIN posicao p ON p.id = a.posicao_id
         WHERE a.id = p_capitao_id;
        IF v_cap_posicao = 'tec' THEN
            v_problemas := v_problemas || format('o técnico real %s não pode ser capitão', v_cap_apelido);
        END IF;
    END IF;

    SELECT coalesce(sum(preco_pago), 0) INTO v_total
      FROM escalacao_atleta
     WHERE tecnico_id = p_tecnico_id AND rodada = p_rodada;
    SELECT patrimonio INTO v_patrimonio FROM tecnico WHERE id = p_tecnico_id;
    IF v_total > v_patrimonio THEN
        v_problemas := v_problemas || format('o time custa %s e o patrimônio é %s',
                                             fn_cartoleta(v_total), fn_cartoleta(v_patrimonio));
    END IF;

    IF cardinality(v_problemas) = 0 THEN
        RETURN NULL;
    END IF;
    RETURN array_to_string(v_problemas, '; ');
END;
$$ LANGUAGE plpgsql STABLE;

-- PARTE 3 - GATILHOS

-- Normaliza o técnico -> BEFORE ROW, INSERT OR UPDATE
-- E-mail em minúsculas, para a UNIQUE tratar "Bruno@X.com" e "bruno@x.com"
-- como o mesmo. No INSERT o patrimônio é sempre C$ 100,00, mesmo que
-- venha outro valor
CREATE OR REPLACE FUNCTION fn_tg_normaliza_tecnico()
RETURNS trigger AS $$
BEGIN
    NEW.email     := lower(btrim(NEW.email));
    NEW.nome      := regexp_replace(btrim(NEW.nome), '\s+', ' ', 'g');
    NEW.apelido   := btrim(NEW.apelido);
    NEW.nome_time := regexp_replace(btrim(NEW.nome_time), '\s+', ' ', 'g');
    IF TG_OP = 'INSERT' THEN
        NEW.patrimonio := 100.00;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_normaliza_tecnico
BEFORE INSERT OR UPDATE OF email, nome, apelido, nome_time ON tecnico
FOR EACH ROW EXECUTE FUNCTION fn_tg_normaliza_tecnico();

-- Estados da rodada -> BEFORE ROW, INSERT OR UPDATE
-- Só futura -> aberta -> fechada -> consolidada, um passo por vez, e grava
-- a data de cada passo
CREATE OR REPLACE FUNCTION fn_tg_rodada_estado()
RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado <> 'futura' THEN
            RAISE EXCEPTION 'Rodada %: toda rodada nasce no estado futura (use sp_abrir_rodada para abrir)',
                NEW.numero;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.numero <> OLD.numero THEN
        RAISE EXCEPTION 'O número de uma rodada não pode ser alterado (% -> %)', OLD.numero, NEW.numero;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        IF (OLD.estado, NEW.estado) NOT IN (('futura', 'aberta'),
                                            ('aberta', 'fechada'),
                                            ('fechada', 'consolidada')) THEN
            RAISE EXCEPTION 'Rodada %: não é possível passar de "%" para "%". A ordem é futura -> aberta -> fechada -> consolidada',
                NEW.numero, OLD.estado, NEW.estado;
        END IF;
        CASE NEW.estado
            WHEN 'aberta'  THEN NEW.aberta_em := now();
            WHEN 'fechada' THEN NEW.fechada_em := now();
            ELSE NEW.consolidada_em := now();
        END CASE;
    ELSE
        NEW.aberta_em      := OLD.aberta_em;
        NEW.fechada_em     := OLD.fechada_em;
        NEW.consolidada_em := OLD.consolidada_em;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_rodada_estado
BEFORE INSERT OR UPDATE ON rodada
FOR EACH ROW EXECUTE FUNCTION fn_tg_rodada_estado();

-- Um jogo por clube na rodada -> BEFORE ROW, INSERT OR UPDATE OF
-- As UNIQUE não pegam o clube mandante num jogo e visitante em outro.
CREATE OR REPLACE FUNCTION fn_tg_partida_um_jogo_por_rodada()
RETURNS trigger AS $$
DECLARE
    v_outra integer;
BEGIN
    SELECT p.id INTO v_outra
      FROM partida p
     WHERE p.rodada = NEW.rodada
       AND p.id <> NEW.id
       AND (p.mandante_id  IN (NEW.mandante_id, NEW.visitante_id)
         OR p.visitante_id IN (NEW.mandante_id, NEW.visitante_id))
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Partida %: um dos clubes já joga a partida % na rodada % (cada clube joga uma vez por rodada)',
            NEW.id, v_outra, NEW.rodada;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_partida_um_jogo_por_rodada
BEFORE INSERT OR UPDATE OF rodada, mandante_id, visitante_id ON partida
FOR EACH ROW EXECUTE FUNCTION fn_tg_partida_um_jogo_por_rodada();

-- 6(d) Rodada consolidada não muda -> BEFORE ROW, I/U/D
-- A pontuação sai dos scouts, então mexer num scout depois da consolidação mudaria médias e preços. A mesma função protege as outras
-- tabelas do cálculo e o histórico de preços
CREATE OR REPLACE FUNCTION fn_tg_protege_rodada_consolidada()
RETURNS trigger AS $$
DECLARE
    v_rodadas  integer[] := '{}';
    v_numero   integer;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_rodadas := v_rodadas || OLD.rodada;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_rodadas := v_rodadas || NEW.rodada;
    END IF;

    SELECT numero INTO v_numero
      FROM rodada
     WHERE numero = ANY (v_rodadas) AND estado = 'consolidada'
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'A rodada % já foi consolidada: os dados de % dessa rodada não podem mais ser incluídos, alterados ou removidos',
            v_numero, TG_TABLE_NAME;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- o gatilho do 6(d)
CREATE OR REPLACE TRIGGER tg_scout_rodada_consolidada
BEFORE INSERT OR UPDATE OR DELETE ON scout
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_rodada_consolidada();

CREATE OR REPLACE TRIGGER tg_atuacao_rodada_consolidada
BEFORE INSERT OR UPDATE OR DELETE ON atuacao
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_rodada_consolidada();

CREATE OR REPLACE TRIGGER tg_partida_rodada_consolidada
BEFORE INSERT OR UPDATE OR DELETE ON partida
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_rodada_consolidada();

CREATE OR REPLACE TRIGGER tg_vinculo_rodada_consolidada
BEFORE INSERT OR UPDATE OR DELETE ON atleta_clube_rodada
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_rodada_consolidada();

CREATE OR REPLACE TRIGGER tg_historico_preco_imutavel
BEFORE INSERT OR UPDATE OR DELETE ON historico_preco
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_rodada_consolidada();

-- Tabela de pontos congelada -> BEFORE ROW
-- Depois da primeira consolidação, mudar valores de scout mudaria pontuações já fechadas. Incluir tipo novo continua liberado.
CREATE OR REPLACE FUNCTION fn_tg_protege_tabela_pontos()
RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM 1 FROM tipo_scout_posicao
         WHERE sigla = NEW.sigla AND posicao_id = NEW.posicao_id;
        IF FOUND THEN
            RETURN NEW;
        END IF;
    END IF;

    PERFORM 1 FROM rodada WHERE estado = 'consolidada';
    IF FOUND THEN
        RAISE EXCEPTION 'Já existem rodadas consolidadas: a tabela de pontos dos scouts (seção 2.7) não pode mais mudar (%)',
            TG_TABLE_NAME;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_tipo_scout_protegido
BEFORE UPDATE OR DELETE ON tipo_scout
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_tabela_pontos();

CREATE OR REPLACE TRIGGER tg_tipo_scout_posicao_protegido
BEFORE INSERT OR UPDATE OR DELETE ON tipo_scout_posicao
FOR EACH ROW EXECUTE FUNCTION fn_tg_protege_tabela_pontos();

-- Regras da escalação -> BEFORE ROW, INSERT/UPDATE/DELETE
-- INSERT: só com a rodada aberta; começa em edição, sem capitão.
-- UPDATE: edição só com mercado aberto e time não confirmado; técnico
-- real não é capitão; o novo esquema tem que caber; confirmar
-- exige time completo. Pontuação só na consolidação.
-- DELETE: só em edição, com mercado aberto.
-- SECURITY DEFINER porque trava tabelas que a aplicação não pode escrever.
CREATE OR REPLACE FUNCTION fn_tg_escalacao_valida()
RETURNS trigger AS $$
DECLARE
    v_rodada    integer;
    v_estado    rodada.estado%TYPE;
    v_posicao   posicao.abreviacao%TYPE;
    v_apelido   atleta.apelido%TYPE;
    v_excesso   text;
    v_problemas text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_rodada := OLD.rodada;
    ELSE
        v_rodada := NEW.rodada;
    END IF;
    SELECT estado INTO v_estado FROM rodada WHERE numero = v_rodada FOR SHARE;

    IF TG_OP = 'INSERT' THEN
        IF v_estado IS DISTINCT FROM 'aberta' THEN
            RAISE EXCEPTION 'A rodada % não está aberta (estado: %): não é possível criar escalação',
                NEW.rodada, coalesce(v_estado, 'inexistente');
        END IF;
        IF NEW.status <> 'em_edicao' OR NEW.capitao_id IS NOT NULL
           OR NEW.pontuacao IS NOT NULL OR NEW.variacao_patrimonio IS NOT NULL THEN
            RAISE EXCEPTION 'Toda escalação começa em edição, sem capitão e sem pontuação';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF v_estado <> 'aberta' OR OLD.status <> 'em_edicao' THEN
            RAISE EXCEPTION 'Só é possível descartar uma escalação em edição, com o mercado aberto';
     END IF;
        RETURN OLD;
    END IF;

    IF NEW.tecnico_id <> OLD.tecnico_id OR NEW.rodada <> OLD.rodada THEN
        RAISE EXCEPTION 'Não é possível mudar o técnico ou a rodada de uma escalação';
    END IF;

    IF NEW.esquema_id    IS DISTINCT FROM OLD.esquema_id
    OR NEW.capitao_id    IS DISTINCT FROM OLD.capitao_id
    OR NEW.status        IS DISTINCT FROM OLD.status
    OR NEW.confirmada_em IS DISTINCT FROM OLD.confirmada_em
    OR NEW.criada_em     IS DISTINCT FROM OLD.criada_em THEN
        IF v_estado <> 'aberta' THEN
            RAISE EXCEPTION 'O mercado da rodada % não está aberto (rodada %): a escalação não pode mais ser alterada',
                NEW.rodada, v_estado;
        END IF;
        IF OLD.status = 'confirmada' THEN
            RAISE EXCEPTION 'Sua escalação da rodada % já foi confirmada e não pode mais ser alterada', NEW.rodada;
        END IF;

        IF NEW.capitao_id IS NOT NULL AND NEW.capitao_id IS DISTINCT FROM OLD.capitao_id THEN
            SELECT p.abreviacao, a.apelido INTO v_posicao, v_apelido
              FROM atleta a JOIN posicao p ON p.id = a.posicao_id
             WHERE a.id = NEW.capitao_id;
            IF v_posicao = 'tec' THEN
                RAISE EXCEPTION '% é técnico real e não pode ser capitão: escolha um dos 11 atletas', v_apelido;
            END IF;
        END IF;
        IF NEW.esquema_id IS DISTINCT FROM OLD.esquema_id THEN
            SELECT string_agg(format('%s %s (o novo esquema aceita %s)', x.qtd, lower(x.posicao), x.maximo), ', ')
              INTO v_excesso
              FROM (SELECT p.nome AS posicao, count(*) AS qtd,
                           fn_qtd_exigida(NEW.esquema_id, p.id) AS maximo
                      FROM escalacao_atleta ea
                      JOIN atleta a  ON a.id = ea.atleta_id
                      JOIN posicao p ON p.id = a.posicao_id
                     WHERE ea.tecnico_id = NEW.tecnico_id AND ea.rodada = NEW.rodada
                     GROUP BY p.id, p.nome) x
             WHERE x.qtd > x.maximo;
            IF v_excesso IS NOT NULL THEN
                RAISE EXCEPTION 'Os atletas já escolhidos não cabem no novo esquema: %', v_excesso
                    USING HINT = 'Remova os excedentes antes de trocar o esquema.';
            END IF;
        END IF;
        IF NEW.status = 'confirmada' AND OLD.status = 'em_edicao' THEN
            v_problemas := fn_problemas_escalacao(NEW.tecnico_id, NEW.rodada, NEW.esquema_id, NEW.capitao_id);
            IF v_problemas IS NOT NULL THEN
                RAISE EXCEPTION 'Escalação não pode ser confirmada: %', v_problemas;
            END IF;
        END IF;
ELSIF NEW.pontuacao IS DISTINCT FROM OLD.pontuacao
       OR NEW.variacao_patrimonio IS DISTINCT FROM OLD.variacao_patrimonio THEN
        IF v_estado <> 'fechada' THEN
            RAISE EXCEPTION 'O resultado da escalação só é gravado pela consolidação de uma rodada fechada (rodada % está %)',
                NEW.rodada, v_estado;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

CREATE OR REPLACE TRIGGER tg_escalacao_valida
BEFORE INSERT OR UPDATE OR DELETE ON escalacao
FOR EACH ROW EXECUTE FUNCTION fn_tg_escalacao_valida();

-- 6(c) Atletas da escalação -> BEFORE ROW, INSERT/UPDATE/DELETE
-- A cada inclusão, troca ou remoção:
-- 1. rodada aberta;
-- 2. escalação não confirmada;
-- 3. atleta provável ou em dúvida;
-- 4. preço total dentro do patrimônio;
-- 5. posição não passa do limite do esquema.
-- O preço pago é sempre o atual; o valor do INSERT é ignorado.
-- Atleta repetido quem barra é a PK, por isso a própria linha não entra nas contagens. SECURITY DEFINER pelo mesmo motivo do anterior.
CREATE OR REPLACE FUNCTION fn_tg_escalacao_atleta_valida()
RETURNS trigger AS $$
DECLARE
    v_tecnico_id    integer;
    v_rodada        integer;
    v_atleta_antigo integer;
    v_estado        rodada.estado%TYPE;
    v_status        escalacao.status%TYPE;
    v_esquema_id    escalacao.esquema_id%TYPE;
    v_esquema_nome  esquema.nome%TYPE;
    v_patrimonio    tecnico.patrimonio%TYPE;
    v_atleta        RECORD;
    v_qtd_posicao   integer;
    v_max_posicao   integer;
    v_total         numeric(8,2);
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tecnico_id := OLD.tecnico_id;
        v_rodada     := OLD.rodada;
    ELSE
        v_tecnico_id := NEW.tecnico_id;
        v_rodada     := NEW.rodada;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        v_atleta_antigo := OLD.atleta_id;
    END IF;

    -- trava a escalação para inclusoes simultaneas não furarem o orçamento
    SELECT e.status, e.esquema_id INTO v_status, v_esquema_id
      FROM escalacao e
     WHERE e.tecnico_id = v_tecnico_id AND e.rodada = v_rodada
       FOR UPDATE;

    IF NOT FOUND THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Crie a escalação da rodada % (escolha o esquema) antes de incluir atletas', v_rodada;
    END IF;

    SELECT estado INTO v_estado FROM rodada WHERE numero = v_rodada FOR SHARE;

    IF v_estado <> 'aberta' THEN
        RAISE EXCEPTION 'O mercado da rodada % não está aberto (rodada %): não é possível incluir, trocar ou remover atletas',
            v_rodada, v_estado;
    END IF;

    IF v_status = 'confirmada' THEN
        RAISE EXCEPTION 'Sua escalação da rodada % já foi confirmada e não pode mais ser alterada', v_rodada;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.atleta_id = OLD.atleta_id THEN
        NEW.preco_pago := OLD.preco_pago;
        RETURN NEW;
    END IF;

    SELECT a.apelido, a.preco_atual, a.posicao_id,
           p.nome AS posicao, s.nome AS situacao, s.escalavel
      INTO v_atleta
      FROM atleta a
      JOIN posicao p  ON p.id = a.posicao_id
      JOIN situacao s ON s.id = a.situacao_id
     WHERE a.id = NEW.atleta_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Atleta % não existe', NEW.atleta_id;
    END IF;

    IF NOT v_atleta.escalavel THEN
        RAISE EXCEPTION '% está com situação "%": só atletas prováveis ou em dúvida podem ser escalados',
            v_atleta.apelido, v_atleta.situacao;
    END IF;

    NEW.preco_pago := v_atleta.preco_atual;

    v_max_posicao := fn_qtd_exigida(v_esquema_id, v_atleta.posicao_id);
    SELECT count(*) INTO v_qtd_posicao
      FROM escalacao_atleta ea
      JOIN atleta a ON a.id = ea.atleta_id
     WHERE ea.tecnico_id = v_tecnico_id
       AND ea.rodada = v_rodada
       AND a.posicao_id = v_atleta.posicao_id
       AND ea.atleta_id IS DISTINCT FROM v_atleta_antigo
       AND ea.atleta_id <> NEW.atleta_id;
    IF v_qtd_posicao >= v_max_posicao THEN
        SELECT nome INTO v_esquema_nome FROM esquema WHERE id = v_esquema_id;
        RAISE EXCEPTION 'O esquema % aceita % atleta(s) na posição %, e a escalação já tem %: não cabe %',
            v_esquema_nome, v_max_posicao, lower(v_atleta.posicao), v_qtd_posicao, v_atleta.apelido;
    END IF;

    SELECT coalesce(sum(preco_pago), 0) INTO v_total
      FROM escalacao_atleta
     WHERE tecnico_id = v_tecnico_id
       AND rodada = v_rodada
       AND atleta_id IS DISTINCT FROM v_atleta_antigo
       AND atleta_id <> NEW.atleta_id;
    SELECT patrimonio INTO v_patrimonio FROM tecnico WHERE id = v_tecnico_id;
    IF v_total + NEW.preco_pago > v_patrimonio THEN
        RAISE EXCEPTION 'Orçamento estourado: o time já custa %, % custa % e o total de % passa do seu patrimônio de %',
            fn_cartoleta(v_total), v_atleta.apelido, fn_cartoleta(NEW.preco_pago),
            fn_cartoleta(v_total + NEW.preco_pago), fn_cartoleta(v_patrimonio)
            USING HINT = 'Troque algum atleta por outro mais barato.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

CREATE OR REPLACE TRIGGER tg_escalacao_atleta_valida
BEFORE INSERT OR UPDATE OR DELETE ON escalacao_atleta
FOR EACH ROW EXECUTE FUNCTION fn_tg_escalacao_atleta_valida();

-- Dono participa da liga -> AFTER ROW, INSERT OR UPDATE OF dono_id
-- AFTER porque a liga precisa existir antes da participação.
CREATE OR REPLACE FUNCTION fn_tg_dono_participa()
RETURNS trigger AS $$
BEGIN
    INSERT INTO participacao (liga_id, tecnico_id)
    VALUES (NEW.id, NEW.dono_id)
    ON CONFLICT (liga_id, tecnico_id) DO NOTHING;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_dono_participa
AFTER INSERT OR UPDATE OF dono_id ON liga
FOR EACH ROW EXECUTE FUNCTION fn_tg_dono_participa();

-- Dono não sai da liga -> BEFORE ROW, DELETE
-- Só sai se a liga for apagada
CREATE OR REPLACE FUNCTION fn_tg_dono_nao_sai()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM liga WHERE id = OLD.liga_id AND dono_id = OLD.tecnico_id;
    IF FOUND THEN
        RAISE EXCEPTION 'O dono não pode sair da própria liga';
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tg_dono_nao_sai
BEFORE DELETE ON participacao
FOR EACH ROW EXECUTE FUNCTION fn_tg_dono_nao_sai();

-- PARTE 4 - PROCEDIMENTOS
-- Todos SECURITY DEFINER: a aplicação só pode chamá-los e eles rodam
-- com os direitos do dono do banco. Nenhum faz COMMIT: o CALL é uma transação só, e qualquer erro desfaz tudo.

-- sp_abrir_rodada: abre o mercado de uma rodada.
-- a rodada tem que estar futura
-- não pode ter outra aberta ou esperando consolidação
-- não abre rodada anterior a uma consolidada
-- as partidas precisam estar carregadas
CREATE OR REPLACE PROCEDURE sp_abrir_rodada(p_rodada integer) AS $$
DECLARE
    v_estado     rodada.estado%TYPE;
    v_outra      rodada%ROWTYPE;
    v_ultima     integer;
    v_partidas   integer;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rodada % não existe (o campeonato tem as rodadas 1 a 38)', p_rodada;
    END IF;
    IF v_estado <> 'futura' THEN
        RAISE EXCEPTION 'A rodada % está % e não pode ser aberta de novo', p_rodada, v_estado;
    END IF;

    SELECT * INTO v_outra FROM rodada WHERE estado IN ('aberta', 'fechada') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'A rodada % ainda está %: feche o mercado e consolide antes de abrir outra rodada',
            v_outra.numero, v_outra.estado;
    END IF;

    SELECT max(numero) INTO v_ultima FROM rodada WHERE estado = 'consolidada';
    IF v_ultima IS NOT NULL AND p_rodada < v_ultima THEN
        RAISE EXCEPTION 'A rodada % já foi consolidada: só rodadas posteriores a ela podem ser abertas', v_ultima;
    END IF;

    SELECT count(*) INTO v_partidas FROM partida WHERE rodada = p_rodada;
    IF v_partidas = 0 THEN
        RAISE EXCEPTION 'A rodada % não tem partidas cadastradas: rode a carga antes de abri-la', p_rodada;
    END IF;

    UPDATE rodada SET estado = 'aberta' WHERE numero = p_rodada;
    RAISE NOTICE 'Rodada % aberta: mercado liberado para as escalações', p_rodada;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- sp_fechar_mercado: fecha o mercado da rodada aberta.
-- Escalações em edição ficam no banco, mas não pontuam.
CREATE OR REPLACE PROCEDURE sp_fechar_mercado(p_rodada integer) AS $$
DECLARE
    v_estado       rodada.estado%TYPE;
    v_confirmadas  integer;
    v_em_edicao    integer;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rodada % não existe', p_rodada;
    END IF;
    IF v_estado <> 'aberta' THEN
        RAISE EXCEPTION 'A rodada % está %: só o mercado de uma rodada aberta pode ser fechado', p_rodada, v_estado;
    END IF;

    UPDATE rodada SET estado = 'fechada' WHERE numero = p_rodada;

    SELECT count(*) FILTER (WHERE status = 'confirmada'),
           count(*) FILTER (WHERE status = 'em_edicao')
      INTO v_confirmadas, v_em_edicao
      FROM escalacao
     WHERE rodada = p_rodada;
    RAISE NOTICE 'Mercado da rodada % fechado: % escalação(ões) confirmada(s); % em edição não vão pontuar',
        p_rodada, v_confirmadas, v_em_edicao;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- 6(e) sp_confirmar_escalacao
-- Confere posições, capitão e orçamento, se estiver certo, confirma.
CREATE OR REPLACE PROCEDURE sp_confirmar_escalacao(p_tecnico_id integer, p_rodada integer) AS $$
DECLARE
    v_escalacao  escalacao%ROWTYPE;
    v_estado     rodada.estado%TYPE;
    v_problemas  text;
BEGIN
    SELECT * INTO v_escalacao
      FROM escalacao
     WHERE tecnico_id = p_tecnico_id AND rodada = p_rodada
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'O técnico % não tem escalação na rodada %', p_tecnico_id, p_rodada;
    END IF;

    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR SHARE;
    IF v_estado <> 'aberta' THEN
        RAISE EXCEPTION 'O mercado da rodada % não está aberto (rodada %): não é mais possível confirmar', p_rodada, v_estado;
    END IF;
    IF v_escalacao.status = 'confirmada' THEN
        RAISE EXCEPTION 'A escalação da rodada % já foi confirmada em %', p_rodada,
            to_char(v_escalacao.confirmada_em, 'DD/MM/YYYY HH24:MI:SS');
    END IF;

    v_problemas := fn_problemas_escalacao(p_tecnico_id, p_rodada,
                                          v_escalacao.esquema_id, v_escalacao.capitao_id);
    IF v_problemas IS NOT NULL THEN
        RAISE EXCEPTION 'Escalação não confirmada: %', v_problemas;
    END IF;

    UPDATE escalacao
       SET status = 'confirmada',
           confirmada_em = clock_timestamp()
     WHERE tecnico_id = p_tecnico_id AND rodada = p_rodada;

    RAISE NOTICE 'Escalação da rodada % confirmada. Boa sorte!', p_rodada;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- sp_criar_liga: cria a liga e devolve id e código de convite.
-- O dono entra pelo gatilho tg_dono_participa.
--  CALL sp_criar_liga(1, 'Minha liga', 'descrição', false, 10, NULL, NULL);
CREATE OR REPLACE PROCEDURE sp_criar_liga(p_dono_id integer, p_nome varchar, p_descricao varchar,
                                          p_publica boolean, p_limite integer,
                                          OUT p_liga_id integer, OUT p_codigo varchar) AS $$
BEGIN
    PERFORM 1 FROM tecnico WHERE id = p_dono_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Técnico % não existe', p_dono_id;
    END IF;

    INSERT INTO liga (dono_id, nome, descricao, publica, limite_participantes)
    VALUES (p_dono_id, btrim(p_nome), nullif(btrim(p_descricao), ''), p_publica, p_limite)
    RETURNING id, codigo_convite INTO p_liga_id, p_codigo;

    RAISE NOTICE 'Liga "%" criada (%). Código de convite: %', btrim(p_nome),
        CASE WHEN p_publica THEN 'pública' ELSE 'privada' END, p_codigo;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- 6(f) sp_entrar_liga
-- Entra pelo id (liga pública) ou pelo código (liga privada).
-- Confere se já participa e se tem vaga. A liga fica travada para dois técnicos não pegarem a mesma última vaga.
-- CALL sp_entrar_liga(7, 3);                 -- pública Bits e Bolas
-- CALL sp_entrar_liga(3, NULL, 'RESENHA26'); -- privada Resenha do LBD
CREATE OR REPLACE PROCEDURE sp_entrar_liga(p_tecnico_id integer,
                                           p_liga_id integer DEFAULT NULL,
                                           p_codigo varchar DEFAULT NULL) AS $$
DECLARE
    v_liga    liga%ROWTYPE;
    v_codigo  varchar := upper(btrim(p_codigo));
    v_ocupadas integer;
BEGIN
    IF p_liga_id IS NULL AND v_codigo IS NULL THEN
        RAISE EXCEPTION 'Informe a liga ou o código de convite';
    END IF;

    IF p_liga_id IS NOT NULL THEN
        SELECT * INTO v_liga FROM liga WHERE id = p_liga_id FOR UPDATE;
    ELSE
        SELECT * INTO v_liga FROM liga WHERE codigo_convite = v_codigo FOR UPDATE;
    END IF;
    IF NOT FOUND THEN
        IF p_liga_id IS NULL THEN
            RAISE EXCEPTION 'Nenhuma liga com o código de convite "%"', v_codigo;
        END IF;
        RAISE EXCEPTION 'Liga % não existe', p_liga_id;
    END IF;

    PERFORM 1 FROM tecnico WHERE id = p_tecnico_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Técnico % não existe', p_tecnico_id;
    END IF;

    PERFORM 1 FROM participacao WHERE liga_id = v_liga.id AND tecnico_id = p_tecnico_id;
    IF FOUND THEN
        RAISE EXCEPTION 'Você já participa da liga "%"', v_liga.nome;
    END IF;

    IF NOT v_liga.publica AND v_codigo IS DISTINCT FROM v_liga.codigo_convite THEN
        RAISE EXCEPTION 'A liga "%" é privada: para entrar, informe o código de convite correto', v_liga.nome;
    END IF;

    SELECT count(*) INTO v_ocupadas FROM participacao WHERE liga_id = v_liga.id;
    IF v_ocupadas >= v_liga.limite_participantes THEN
        RAISE EXCEPTION 'A liga "%" está cheia: % de % vagas ocupadas',
            v_liga.nome, v_ocupadas, v_liga.limite_participantes;
    END IF;

    INSERT INTO participacao (liga_id, tecnico_id) VALUES (v_liga.id, p_tecnico_id);
    RAISE NOTICE 'Bem-vindo à liga "%"!', v_liga.nome;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;

-- 6(g) sp_consolidar_rodada
-- Consolida uma rodada fechada numa transação só:
-- 1. pontua as escalações confirmadas;
-- 2. atualiza os preços e grava o histórico;
--3. atualiza o patrimônio de quem confirmou;
-- 4. marca a rodada como consolidada.
-- Qualquer erro desfaz tudo. A rodada fica travada, então não dá para consolidar duas vezes.
-- p_simular_falha = true força um erro antes do passo 4
CREATE OR REPLACE PROCEDURE sp_consolidar_rodada(p_rodada integer,
                                                 p_simular_falha boolean DEFAULT false) AS $$
DECLARE
    v_estado       rodada.estado%TYPE;
    v_pendentes    integer;
    v_escalacoes   integer;
    v_valorizados  integer;
    v_tecnicos     integer;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rodada % não existe', p_rodada;
    END IF;
    IF v_estado = 'consolidada' THEN
        RAISE EXCEPTION 'A rodada % já foi consolidada: a consolidação não pode ser executada duas vezes', p_rodada;
    END IF;
    IF v_estado <> 'fechada' THEN
        RAISE EXCEPTION 'A rodada % está %: só uma rodada fechada pode ser consolidada', p_rodada, v_estado;
    END IF;

    SELECT count(*) INTO v_pendentes
      FROM partida
     WHERE rodada = p_rodada AND valida AND placar_mandante IS NULL;
    IF v_pendentes > 0 THEN
        RAISE EXCEPTION 'A rodada % ainda tem % partida(s) válida(s) sem placar: carregue as estatísticas antes de consolidar',
            p_rodada, v_pendentes;
    END IF;
    PERFORM 1 FROM atuacao WHERE rodada = p_rodada;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A rodada % não tem scouts carregados: rode a carga antes de consolidar', p_rodada;
    END IF;

    -- 1. pontua as escalações confirmadas
    UPDATE escalacao
       SET pontuacao = fn_pontuacao_escalacao(tecnico_id, rodada)
     WHERE rodada = p_rodada AND status = 'confirmada';
    GET DIAGNOSTICS v_escalacoes = ROW_COUNT;

    -- 2. histórico de todos os atletas;
    -- a média só usa rodadas consolidadas antes desta
    INSERT INTO historico_preco (atleta_id, rodada, preco_rodada, preco_novo)
    SELECT a.id,
           p_rodada,
           a.preco_atual,
           greatest(1.00,                                       
                    a.preco_atual
                    + CASE WHEN at.entrou_em_campo
                           THEN fn_variacao_preco(fn_pontuacao_atleta(a.id, p_rodada),
                                                  fn_media_atleta(a.id, p_rodada))
                           ELSE 0
                      END)
      FROM atleta a
      LEFT JOIN atuacao at ON at.atleta_id = a.id AND at.rodada = p_rodada;

    UPDATE atleta a
       SET preco_atual = h.preco_novo
      FROM historico_preco h
     WHERE h.atleta_id = a.id
       AND h.rodada = p_rodada
       AND h.preco_novo <> h.preco_rodada;
    GET DIAGNOSTICS v_valorizados = ROW_COUNT;

    -- 3. patrimônio: soma de preço novo - preço pago dos 12
    UPDATE escalacao e
       SET variacao_patrimonio = (SELECT coalesce(sum(h.preco_novo - ea.preco_pago), 0)
                                    FROM escalacao_atleta ea
                                    JOIN historico_preco h
                                      ON h.atleta_id = ea.atleta_id AND h.rodada = ea.rodada
                                   WHERE ea.tecnico_id = e.tecnico_id AND ea.rodada = e.rodada)
     WHERE e.rodada = p_rodada AND e.status = 'confirmada';

    UPDATE tecnico t
       SET patrimonio = t.patrimonio + e.variacao_patrimonio
      FROM escalacao e
     WHERE e.tecnico_id = t.id
       AND e.rodada = p_rodada
       AND e.status = 'confirmada';
    GET DIAGNOSTICS v_tecnicos = ROW_COUNT;

    RAISE NOTICE 'Rodada %: % escalação(ões) pontuada(s), % atleta(s) com preço novo, % patrimônio(s) atualizado(s)',
        p_rodada, v_escalacoes, v_valorizados, v_tecnicos;

    IF p_simular_falha THEN
        RAISE EXCEPTION 'Falha simulada na consolidação da rodada % (antes de marcá-la como consolidada): tudo o que foi feito acima será desfeito',
            p_rodada;
    END IF;

    -- 4. daqui em diante a rodada não muda mais
    UPDATE rodada SET estado = 'consolidada' WHERE numero = p_rodada;
    RAISE NOTICE 'Rodada % consolidada: pontuações, preços e ranking definitivos', p_rodada; END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = fantasy, pg_temp;