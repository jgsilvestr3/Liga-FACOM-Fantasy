-- =====================================================================
-- Liga FACOM Fantasy · testes/testes-regras.sql
-- Bateria de testes das regras de negócio. Tenta, de propósito, violar
-- cada regra e confere se o banco recusa com a mensagem certa; depois
-- joga uma rodada completa e confere os números da consolidação.
--
-- Roda DEPOIS dos scripts 01 a 05 e da carga, com a rodada 1 ainda
-- "futura". Tudo acontece dentro de uma transação que termina em
-- ROLLBACK: o banco volta exatamente como estava.
--
--   docker exec -i <container> psql -U lbd -d liga_fantasy < testes/testes-regras.sql
--
-- Resultado: uma tabela com cada teste e "ok" ou "FALHOU".
-- =====================================================================

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
SET search_path TO fantasy, public;
SET client_min_messages = warning;   -- esconde os NOTICE dos procedimentos

BEGIN;

CREATE TEMP TABLE resultado (
    n        serial,
    teste    text,
    situacao text,
    detalhe  text
);

-- espera_erro: executa o comando e espera que o banco o RECUSE com uma
-- mensagem que contenha o trecho informado. O bloco EXCEPTION funciona
-- como um savepoint: o comando recusado não deixa rastro.
CREATE FUNCTION pg_temp.espera_erro(p_teste text, p_comando text, p_trecho text)
RETURNS void AS $$
BEGIN
    EXECUTE p_comando;
    INSERT INTO resultado (teste, situacao, detalhe)
    VALUES (p_teste, 'FALHOU', 'o banco aceitou: ' || p_comando);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO resultado (teste, situacao, detalhe)
    VALUES (p_teste,
            CASE WHEN position(lower(p_trecho) IN lower(SQLERRM)) > 0 THEN 'ok' ELSE 'FALHOU' END,
            SQLERRM);
END;
$$ LANGUAGE plpgsql;

-- confere: registra se uma condição é verdadeira
CREATE FUNCTION pg_temp.confere(p_teste text, p_condicao boolean, p_detalhe text DEFAULT NULL)
RETURNS void AS $$
BEGIN
    INSERT INTO resultado (teste, situacao, detalhe)
    VALUES (p_teste, CASE WHEN p_condicao THEN 'ok' ELSE 'FALHOU' END, p_detalhe);
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 1. Exemplos do enunciado
-- ---------------------------------------------------------------------
SELECT pg_temp.confere('2.7 Igor Gomes fez 12,4 na rodada 31',
                       fn_pontuacao_atleta(100084, 31) = 12.4,
                       fn_pontuacao_atleta(100084, 31)::text);
SELECT pg_temp.confere('2.8 variação do exemplo = 0,84', fn_variacao_preco(12.4, 4.0) = 0.84);
SELECT pg_temp.confere('2.8 variação limitada a +1,50', fn_variacao_preco(40, 2) = 1.50);
SELECT pg_temp.confere('2.8 variação limitada a -1,50', fn_variacao_preco(-5, 20) = -1.50);
SELECT pg_temp.confere('2.8 sem média, variação zero', fn_variacao_preco(10, NULL) = 0);

-- ---------------------------------------------------------------------
-- 2. Estados da rodada
-- ---------------------------------------------------------------------
SELECT pg_temp.espera_erro('2.3 rodada não pula estados (futura → consolidada)',
    $c$UPDATE rodada SET estado = 'consolidada' WHERE numero = 1$c$, 'não é possível passar');
SELECT pg_temp.espera_erro('6g não consolida rodada que não está fechada',
    $c$CALL sp_consolidar_rodada(1)$c$, 'só uma rodada fechada');
CALL sp_abrir_rodada(1);
SELECT pg_temp.confere('abrir rodada 1', (SELECT estado FROM rodada WHERE numero = 1) = 'aberta');
SELECT pg_temp.espera_erro('2.3 só uma rodada aberta (procedimento)',
    $c$CALL sp_abrir_rodada(2)$c$, 'ainda está aberta');
SELECT pg_temp.espera_erro('2.3 só uma rodada aberta (índice único parcial, UPDATE direto)',
    $c$UPDATE rodada SET estado = 'aberta' WHERE numero = 2$c$, 'uq_rodada_uma_aberta');
SELECT pg_temp.espera_erro('2.3 rodada aberta não volta para futura',
    $c$UPDATE rodada SET estado = 'futura' WHERE numero = 1$c$, 'não é possível passar');

-- ---------------------------------------------------------------------
-- 3. Escalação: regras conferidas a cada atleta incluído (6c)
-- Técnico: Pedro (pedro.affonso@exemplo.com), esquema 4-3-3.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE t AS
SELECT (SELECT id FROM tecnico WHERE email = 'pedro.affonso@exemplo.com')   AS pedro,
       (SELECT id FROM tecnico WHERE email = 'bruno.rodrigues@exemplo.com') AS bruno,
       (SELECT id FROM tecnico WHERE email = 'joao.gabriel@exemplo.com')    AS joao,
       (SELECT id FROM esquema WHERE nome = '4-3-3') AS e433,
       (SELECT id FROM esquema WHERE nome = '3-4-3') AS e343;
-- CALL não aceita subconsulta nos argumentos: os ids viram variáveis do psql
SELECT pedro, bruno, joao,
       (SELECT id FROM tecnico WHERE email = 'william.cintra@exemplo.com')  AS william,
       (SELECT id FROM tecnico WHERE email = 'murilo.bassan@exemplo.com')   AS murilo,
       (SELECT id FROM tecnico WHERE email = 'samuel.fialho@exemplo.com')   AS samuel,
       (SELECT id FROM tecnico WHERE email = 'guilherme.kenzo@exemplo.com') AS kenzo,
       (SELECT id FROM liga WHERE codigo_convite = 'BITSBOLA')              AS liga_bits
  FROM t \gset

SELECT pg_temp.espera_erro('6c não inclui atleta sem escalação criada',
    format('INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (%s, 1, 100084)', (SELECT pedro FROM t)),
    'Crie a escalação');

INSERT INTO escalacao (tecnico_id, rodada, esquema_id) SELECT pedro, 1, e433 FROM t;
SELECT pg_temp.espera_erro('2.5 no máximo uma escalação por técnico por rodada',
    format('INSERT INTO escalacao (tecnico_id, rodada, esquema_id) VALUES (%s, 1, %s)', (SELECT pedro FROM t), (SELECT e433 FROM t)),
    'pk_escalacao');
SELECT pg_temp.espera_erro('escalação nasce em edição',
    format($c$INSERT INTO escalacao (tecnico_id, rodada, esquema_id, status, confirmada_em) VALUES (%s, 1, %s, 'confirmada', now())$c$,
           (SELECT bruno FROM t), (SELECT e433 FROM t)),
    'começa em edição');

-- atleta contundido
SELECT pg_temp.espera_erro('6c só prováveis ou dúvidas',
    format('INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (%s, 1, %s)',
           (SELECT pedro FROM t),
           (SELECT a.id FROM atleta a JOIN situacao s ON s.id = a.situacao_id WHERE s.nome = 'Contundido' ORDER BY a.id LIMIT 1)),
    'só atletas prováveis ou em dúvida');

-- goleiros: o primeiro entra, o segundo não cabe no 4-3-3
CREATE TEMP TABLE goleiros AS
SELECT atleta_id, preco FROM vw_mercado WHERE posicao = 'gol' ORDER BY preco, atleta_id LIMIT 2;
INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id, preco_pago)
SELECT pedro, 1, (SELECT atleta_id FROM goleiros ORDER BY preco, atleta_id LIMIT 1), 0.01 FROM t;
SELECT pg_temp.confere('2.4 preço pago = preço do momento (valor enviado é ignorado)',
    (SELECT ea.preco_pago = a.preco_atual FROM escalacao_atleta ea JOIN atleta a ON a.id = ea.atleta_id
      WHERE ea.tecnico_id = (SELECT pedro FROM t) AND ea.rodada = 1 LIMIT 1));
SELECT pg_temp.espera_erro('6c posição não passa do esquema (2º goleiro)',
    format('INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (%s, 1, %s)',
           (SELECT pedro FROM t), (SELECT atleta_id FROM goleiros ORDER BY preco DESC, atleta_id DESC LIMIT 1)),
    'aceita 1 atleta(s) na posição goleiro');
SELECT pg_temp.espera_erro('2.5 mesmo atleta não aparece duas vezes',
    format('INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (%s, 1, %s)',
           (SELECT pedro FROM t), (SELECT atleta_id FROM goleiros ORDER BY preco, atleta_id LIMIT 1)),
    'pk_escalacao_atleta');

-- orçamento: com o Bruno, incluindo os atletas mais caros até estourar
INSERT INTO escalacao (tecnico_id, rodada, esquema_id) SELECT bruno, 1, e433 FROM t;
DO $$
DECLARE
    v_bruno integer := (SELECT bruno FROM t);
    v_mais_caro RECORD;
    v_msg text := NULL;
BEGIN
    FOR v_mais_caro IN
        SELECT DISTINCT ON (posicao_id) atleta_id, posicao_id, preco
          FROM vw_mercado
         ORDER BY posicao_id, preco DESC
    LOOP
        BEGIN
            INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (v_bruno, 1, v_mais_caro.atleta_id);
        EXCEPTION WHEN OTHERS THEN
            v_msg := SQLERRM;
            EXIT;
        END;
    END LOOP;
    IF v_msg IS NULL THEN  -- os 6 mais caros (um por posição) ainda cabem: completa com caros
        FOR v_mais_caro IN
            SELECT m.atleta_id FROM vw_mercado m
             WHERE m.posicao IN ('mei', 'ata', 'zag', 'lat')
               AND NOT EXISTS (SELECT 1 FROM escalacao_atleta ea WHERE ea.tecnico_id = v_bruno AND ea.rodada = 1 AND ea.atleta_id = m.atleta_id)
             ORDER BY m.preco DESC
        LOOP
            BEGIN
                INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (v_bruno, 1, v_mais_caro.atleta_id);
            EXCEPTION WHEN OTHERS THEN
                IF SQLERRM LIKE 'Orçamento estourado%' THEN v_msg := SQLERRM; EXIT; END IF;
            END;
        END LOOP;
    END IF;
    PERFORM pg_temp.confere('2.4 soma dos preços não passa do patrimônio', v_msg LIKE 'Orçamento estourado%', v_msg);
END;
$$;

-- montagem completa e válida da escalação do Pedro (os mais baratos de cada posição)
DO $$
DECLARE
    v_pedro integer := (SELECT pedro FROM t);
    v_esq integer := (SELECT e433 FROM t);
    v_pos RECORD;
    v_atl RECORD;
BEGIN
    FOR v_pos IN SELECT id, fn_qtd_exigida(v_esq, id) AS qtd FROM posicao LOOP
        FOR v_atl IN
            SELECT m.atleta_id FROM vw_mercado m
             WHERE m.posicao_id = v_pos.id
               AND NOT EXISTS (SELECT 1 FROM escalacao_atleta ea WHERE ea.tecnico_id = v_pedro AND ea.rodada = 1 AND ea.atleta_id = m.atleta_id)
             ORDER BY m.preco, m.atleta_id
             LIMIT greatest(v_pos.qtd - (SELECT count(*) FROM escalacao_atleta ea JOIN atleta a ON a.id = ea.atleta_id
                                          WHERE ea.tecnico_id = v_pedro AND ea.rodada = 1 AND a.posicao_id = v_pos.id), 0)
        LOOP
            INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (v_pedro, 1, v_atl.atleta_id);
        END LOOP;
    END LOOP;
END;
$$;
SELECT pg_temp.confere('montagem: 12 escolhidos (11 + técnico real)',
    (SELECT count(*) FROM escalacao_atleta WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1) = 12);

-- ---------------------------------------------------------------------
-- 4. Capitão e confirmação (6e)
-- ---------------------------------------------------------------------
SELECT pg_temp.espera_erro('6e não confirma sem capitão',
    format('CALL sp_confirmar_escalacao(%s, 1)', (SELECT pedro FROM t)), 'nenhum capitão escolhido');
SELECT pg_temp.espera_erro('2.6 técnico real não pode ser capitão',
    format('UPDATE escalacao SET capitao_id = %s WHERE tecnico_id = %s AND rodada = 1',
           (SELECT ea.atleta_id FROM escalacao_atleta ea JOIN atleta a ON a.id = ea.atleta_id
             WHERE ea.tecnico_id = (SELECT pedro FROM t) AND ea.rodada = 1 AND a.posicao_id = 6),
           (SELECT pedro FROM t)),
    'não pode ser capitão');
SELECT pg_temp.espera_erro('2.6 capitão precisa estar na escalação (FK composta)',
    format('UPDATE escalacao SET capitao_id = 100084 WHERE tecnico_id = %s AND rodada = 1', (SELECT pedro FROM t)),
    'fk_escalacao_capitao');
UPDATE escalacao SET capitao_id = (
        SELECT ea.atleta_id FROM escalacao_atleta ea JOIN atleta a ON a.id = ea.atleta_id
         WHERE ea.tecnico_id = (SELECT pedro FROM t) AND ea.rodada = 1 AND a.posicao_id = 5
         ORDER BY ea.atleta_id LIMIT 1)
 WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1;
SELECT pg_temp.espera_erro('troca de esquema precisa caber nos atletas escolhidos',
    format('UPDATE escalacao SET esquema_id = %s WHERE tecnico_id = %s AND rodada = 1', (SELECT e343 FROM t), (SELECT pedro FROM t)),
    'não cabem no novo esquema');
SELECT pg_temp.espera_erro('confirmar direto por UPDATE também confere a escalação',
    format($c$UPDATE escalacao SET status = 'confirmada', confirmada_em = now(), capitao_id = NULL WHERE tecnico_id = %s AND rodada = 1$c$,
           (SELECT pedro FROM t)),
    'nenhum capitão');
SELECT pg_temp.espera_erro('6e não confirma escalação incompleta (Bruno)',
    format('CALL sp_confirmar_escalacao(%s, 1)', (SELECT bruno FROM t)), 'falta(m)');

CALL sp_confirmar_escalacao(:pedro, 1);
SELECT pg_temp.confere('6e escalação confirmada com data',
    (SELECT status = 'confirmada' AND confirmada_em IS NOT NULL FROM escalacao
      WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1));
SELECT pg_temp.espera_erro('6c confirmada não aceita remoção de atleta',
    format('DELETE FROM escalacao_atleta WHERE tecnico_id = %s AND rodada = 1', (SELECT pedro FROM t)),
    'já foi confirmada');
SELECT pg_temp.espera_erro('confirmada não troca capitão',
    format('UPDATE escalacao SET capitao_id = NULL WHERE tecnico_id = %s AND rodada = 1', (SELECT pedro FROM t)),
    'já foi confirmada');
SELECT pg_temp.espera_erro('confirmar duas vezes',
    format('CALL sp_confirmar_escalacao(%s, 1)', (SELECT pedro FROM t)), 'já foi confirmada');

-- remover o capitão de uma escalação em edição desfaz a escolha (ON DELETE SET NULL (capitao_id))
INSERT INTO escalacao (tecnico_id, rodada, esquema_id) SELECT joao, 1, e433 FROM t;
INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id)
SELECT (SELECT joao FROM t), 1, atleta_id FROM vw_mercado WHERE posicao = 'ata' ORDER BY preco, atleta_id LIMIT 1;
UPDATE escalacao SET capitao_id = (SELECT atleta_id FROM escalacao_atleta WHERE tecnico_id = (SELECT joao FROM t) AND rodada = 1)
 WHERE tecnico_id = (SELECT joao FROM t) AND rodada = 1;
DELETE FROM escalacao_atleta WHERE tecnico_id = (SELECT joao FROM t) AND rodada = 1;
SELECT pg_temp.confere('remover o capitão anula a escolha de capitão',
    (SELECT capitao_id IS NULL FROM escalacao WHERE tecnico_id = (SELECT joao FROM t) AND rodada = 1));

-- ---------------------------------------------------------------------
-- 5. Fechamento do mercado e consolidação (6g)
-- ---------------------------------------------------------------------
CALL sp_fechar_mercado(1);
SELECT pg_temp.espera_erro('2.3 mercado fechado: nenhuma escalação criada',
    format('INSERT INTO escalacao (tecnico_id, rodada, esquema_id) VALUES (%s, 1, %s)',
           :william, (SELECT e433 FROM t)),
    'não está aberta');
SELECT pg_temp.espera_erro('6c mercado fechado: nenhum atleta incluído',
    format('INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES (%s, 1, 100084)', (SELECT bruno FROM t)),
    'não está aberto');

CREATE TEMP TABLE antes AS
SELECT (SELECT patrimonio FROM tecnico WHERE id = (SELECT pedro FROM t)) AS patrimonio_pedro,
       (SELECT sum(preco_atual) FROM atleta) AS soma_precos;

SELECT pg_temp.espera_erro('6g falha no meio da consolidação',
    'CALL sp_consolidar_rodada(1, true)', 'Falha simulada');
SELECT pg_temp.confere('6g após a falha: rodada continua fechada',
    (SELECT estado FROM rodada WHERE numero = 1) = 'fechada');
SELECT pg_temp.confere('6g após a falha: nenhum preço mudou',
    (SELECT sum(preco_atual) FROM atleta) = (SELECT soma_precos FROM antes));
SELECT pg_temp.confere('6g após a falha: patrimônio igual',
    (SELECT patrimonio FROM tecnico WHERE id = (SELECT pedro FROM t)) = (SELECT patrimonio_pedro FROM antes));
SELECT pg_temp.confere('6g após a falha: histórico de preços vazio',
    NOT EXISTS (SELECT 1 FROM historico_preco WHERE rodada = 1));
SELECT pg_temp.confere('6g após a falha: escalação sem pontuação',
    (SELECT pontuacao IS NULL FROM escalacao WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1));

CALL sp_consolidar_rodada(1);
SELECT pg_temp.confere('6g rodada consolidada', (SELECT estado FROM rodada WHERE numero = 1) = 'consolidada');
SELECT pg_temp.confere('6g pontuação gravada = fn_pontuacao_escalacao (6b)',
    (SELECT pontuacao = fn_pontuacao_escalacao(tecnico_id, rodada) FROM escalacao
      WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1),
    (SELECT pontuacao::text FROM escalacao WHERE tecnico_id = (SELECT pedro FROM t) AND rodada = 1));
SELECT pg_temp.confere('6b pontuação = soma dos 11 (capitão × 1,5) + técnico real',
    (SELECT e.pontuacao = sum(fn_pontuacao_atleta(ea.atleta_id, 1)
                              * CASE WHEN ea.atleta_id = e.capitao_id THEN 1.5 ELSE 1 END)
       FROM escalacao e JOIN escalacao_atleta ea ON ea.tecnico_id = e.tecnico_id AND ea.rodada = e.rodada
      WHERE e.tecnico_id = (SELECT pedro FROM t) AND e.rodada = 1
      GROUP BY e.pontuacao));
SELECT pg_temp.confere('6g escalação não confirmada não pontua',
    (SELECT pontuacao IS NULL FROM escalacao WHERE tecnico_id = (SELECT bruno FROM t) AND rodada = 1));
SELECT pg_temp.confere('2.8 histórico de preços de todos os atletas',
    (SELECT count(*) FROM historico_preco WHERE rodada = 1) = (SELECT count(*) FROM atleta));
SELECT pg_temp.confere('2.8 preço atual = preço novo do histórico',
    NOT EXISTS (SELECT 1 FROM atleta a JOIN historico_preco h ON h.atleta_id = a.id AND h.rodada = 1
                 WHERE a.preco_atual <> h.preco_novo));
SELECT pg_temp.confere('2.8 quem não entrou em campo mantém o preço',
    NOT EXISTS (SELECT 1 FROM historico_preco h
                  LEFT JOIN atuacao at ON at.atleta_id = h.atleta_id AND at.rodada = h.rodada
                 WHERE h.rodada = 1 AND coalesce(at.entrou_em_campo, false) = false
                   AND h.preco_novo <> h.preco_rodada));
SELECT pg_temp.confere('2.8 primeira rodada: sem média anterior, variação zero',
    NOT EXISTS (SELECT 1 FROM historico_preco WHERE rodada = 1 AND preco_novo <> preco_rodada));
SELECT pg_temp.confere('2.8 patrimônio = 100 + soma de (preço novo − preço pago)',
    (SELECT patrimonio FROM tecnico WHERE id = (SELECT pedro FROM t))
    = 100 + (SELECT sum(h.preco_novo - ea.preco_pago)
               FROM escalacao_atleta ea
               JOIN historico_preco h ON h.atleta_id = ea.atleta_id AND h.rodada = ea.rodada
              WHERE ea.tecnico_id = (SELECT pedro FROM t) AND ea.rodada = 1));
SELECT pg_temp.espera_erro('6g não consolida duas vezes',
    'CALL sp_consolidar_rodada(1)', 'já foi consolidada');

-- ---------------------------------------------------------------------
-- 6. Rodada consolidada não muda mais (6d e afins)
-- ---------------------------------------------------------------------
SELECT pg_temp.espera_erro('6d scout de rodada consolidada não muda',
    'UPDATE scout SET quantidade = quantidade + 1 WHERE rodada = 1', 'já foi consolidada');
SELECT pg_temp.espera_erro('6d scout novo em rodada consolidada',
    format($c$INSERT INTO scout (atleta_id, rodada, sigla, quantidade)
              SELECT atleta_id, 1, 'G', 3 FROM atuacao WHERE rodada = 1 AND entrou_em_campo
               AND NOT EXISTS (SELECT 1 FROM scout s WHERE s.atleta_id = atuacao.atleta_id AND s.rodada = 1 AND s.sigla = 'G') LIMIT 1$c$),
    'já foi consolidada');
SELECT pg_temp.espera_erro('6d scout de rodada consolidada não sai',
    'DELETE FROM scout WHERE rodada = 1', 'já foi consolidada');
SELECT pg_temp.espera_erro('placar de rodada consolidada não muda',
    'UPDATE partida SET placar_mandante = 9 WHERE rodada = 1', 'já foi consolidada');
SELECT pg_temp.espera_erro('histórico de preços é imutável',
    'UPDATE historico_preco SET preco_novo = 50 WHERE rodada = 1', 'já foi consolidada');
SELECT pg_temp.espera_erro('tabela de pontos congelada',
    $c$UPDATE tipo_scout SET valor = 10 WHERE sigla = 'G'$c$, 'não pode mais mudar');
SELECT pg_temp.espera_erro('não reabre rodada anterior à última consolidada',
    'CALL sp_abrir_rodada(1)', 'consolidada e não pode ser aberta');
CALL sp_abrir_rodada(2);
SELECT pg_temp.confere('abre a rodada seguinte', (SELECT estado FROM rodada WHERE numero = 2) = 'aberta');
SELECT pg_temp.confere('mercado da rodada 2 mostra média e última pontuação',
    EXISTS (SELECT 1 FROM vw_mercado WHERE media IS NOT NULL AND ultima_rodada = 1));

-- ---------------------------------------------------------------------
-- 7. Ligas (6f)
-- ---------------------------------------------------------------------
-- Resenha do LBD (RESENHA26): privada, limite 6, começa com 4 participantes
SELECT pg_temp.espera_erro('6f liga privada sem código',
    format('CALL sp_entrar_liga(%s, %s)', (SELECT joao FROM t),
           (SELECT id FROM liga WHERE codigo_convite = 'RESENHA26')),
    'é privada');
SELECT pg_temp.espera_erro('6f liga privada com código errado',
    format($c$CALL sp_entrar_liga(%s, %s, 'ERRADO123')$c$, (SELECT joao FROM t),
           (SELECT id FROM liga WHERE codigo_convite = 'RESENHA26')),
    'é privada');
CALL sp_entrar_liga(:joao, NULL, 'resenha26');
SELECT pg_temp.confere('6f entra com o código (sem diferenciar maiúsculas)',
    EXISTS (SELECT 1 FROM participacao pa JOIN liga l ON l.id = pa.liga_id
             WHERE l.codigo_convite = 'RESENHA26' AND pa.tecnico_id = (SELECT joao FROM t)));
SELECT pg_temp.espera_erro('6f já participa',
    format($c$CALL sp_entrar_liga(%s, NULL, 'RESENHA26')$c$, (SELECT joao FROM t)),
    'já participa');
CALL sp_entrar_liga(:murilo, NULL, 'RESENHA26');   -- 6ª vaga: a liga enche
SELECT pg_temp.espera_erro('6f limite de participantes',
    format($c$CALL sp_entrar_liga(%s, NULL, 'RESENHA26')$c$, :samuel),
    'está cheia');
-- Bits e Bolas (BITSBOLA): pública; o Kenzo ainda não participa
CALL sp_entrar_liga(:kenzo, :liga_bits);
SELECT pg_temp.confere('6f liga pública: basta pedir',
    EXISTS (SELECT 1 FROM participacao pa JOIN liga l ON l.id = pa.liga_id
             WHERE l.codigo_convite = 'BITSBOLA' AND pa.tecnico_id = :kenzo));
CALL sp_criar_liga(:william, 'Liga do William', NULL, false, 5, NULL, NULL);
SELECT pg_temp.confere('2.9 dono participa da liga que criou',
    EXISTS (SELECT 1 FROM liga l JOIN participacao pa ON pa.liga_id = l.id AND pa.tecnico_id = l.dono_id
             WHERE l.nome = 'Liga do William'));
SELECT pg_temp.espera_erro('2.9 dono não sai da própria liga',
    $c$DELETE FROM participacao pa USING liga l WHERE l.id = pa.liga_id AND pa.tecnico_id = l.dono_id AND l.nome = 'Liga do William'$c$,
    'dono não pode sair');
SELECT pg_temp.espera_erro('2.9 limite mínimo de participantes',
    format($c$CALL sp_criar_liga(%s, 'Liga solo', NULL, true, 1, NULL, NULL)$c$, (SELECT pedro FROM t)),
    'ck_liga_limite');

-- ---------------------------------------------------------------------
-- 8. Técnico, esquema, partida (restrições declarativas e afins)
-- ---------------------------------------------------------------------
INSERT INTO tecnico (nome, email, apelido, nome_time, patrimonio)
VALUES ('  Teste   da Silva ', ' Teste.Silva@Exemplo.com ', 'Teste', 'Teste FC', 999);
SELECT pg_temp.confere('e-mail normalizado e patrimônio inicial 100',
    (SELECT email = 'teste.silva@exemplo.com' AND patrimonio = 100 AND nome = 'Teste da Silva'
       FROM tecnico WHERE apelido = 'Teste'));
SELECT pg_temp.espera_erro('3 e-mail não se repete (mesmo com outra caixa)',
    $c$INSERT INTO tecnico (nome, email, apelido, nome_time) VALUES ('Outro', 'TESTE.SILVA@exemplo.com', 'Outro', 'Outro FC')$c$,
    'uq_tecnico_email');
SELECT pg_temp.espera_erro('e-mail com formato inválido',
    $c$INSERT INTO tecnico (nome, email, apelido, nome_time) VALUES ('Outro', 'sem-arroba', 'Outro', 'Outro FC')$c$,
    'ck_tecnico_email');
SELECT pg_temp.espera_erro('2.5 esquema com goleiro e técnico únicos e nome coerente',
    $c$INSERT INTO esquema VALUES (99, '4-4-3', 1, 2, 2, 4, 3, 1)$c$, 'ck_esquema');
SELECT pg_temp.espera_erro('2.3 clube não enfrenta a si mesmo',
    'UPDATE partida SET visitante_id = mandante_id WHERE id = (SELECT min(id) FROM partida WHERE rodada = 38)',
    'ck_partida_clubes_distintos');
SELECT pg_temp.espera_erro('2.3 clube joga uma vez por rodada (caso cruzado)',
    format($c$INSERT INTO partida VALUES (2, 38, %s, %s, 'Estádio X', '2026-12-06 16:00', NULL, NULL, true)$c$,
           (SELECT mandante_id FROM partida WHERE rodada = 38 ORDER BY id LIMIT 1),
           (SELECT mandante_id FROM partida WHERE rodada = 38 ORDER BY id OFFSET 1 LIMIT 1)),
    'cada clube joga uma vez por rodada');
SELECT pg_temp.espera_erro('2.8 preço nunca abaixo de C$ 1,00',
    'UPDATE atleta SET preco_atual = 0.50 WHERE id = 100084', 'ck_atleta_preco');

-- ---------------------------------------------------------------------
-- 9. Segurança: a aplicação (liga_app) não passa por cima das regras
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT ON resultado TO liga_app;      -- só para registrar o resultado
GRANT USAGE ON SEQUENCE resultado_n_seq TO liga_app;
SET LOCAL ROLE liga_app;
SELECT pg_temp.espera_erro('05 app não altera patrimônio',
    'UPDATE tecnico SET patrimonio = 1000', 'permission denied');
SELECT pg_temp.espera_erro('05 app não altera preço de atleta',
    'UPDATE atleta SET preco_atual = 1', 'permission denied');
SELECT pg_temp.espera_erro('05 app não muda estado da rodada',
    $c$UPDATE rodada SET estado = 'fechada' WHERE numero = 2$c$, 'permission denied');
SELECT pg_temp.espera_erro('05 app não lê código de convite',
    'SELECT codigo_convite FROM liga', 'permission denied');
SELECT pg_temp.espera_erro('05 app não confirma por UPDATE direto',
    $c$UPDATE escalacao SET status = 'confirmada'$c$, 'permission denied');
SELECT pg_temp.confere('05 app lê o mercado', (SELECT count(*) FROM vw_mercado) > 0);
SELECT pg_temp.confere('05 dono vê o código pela função',
    fn_codigo_convite((SELECT id FROM liga WHERE nome = 'Liga FACOM Fantasy'),
                      (SELECT dono_id FROM liga WHERE nome = 'Liga FACOM Fantasy')) = 'FACOM2026');
RESET ROLE;

-- ---------------------------------------------------------------------
-- Resultado
-- ---------------------------------------------------------------------
\o
\pset footer off
SELECT n, situacao, teste, left(detalhe, 110) AS detalhe FROM resultado ORDER BY n;
SELECT count(*) FILTER (WHERE situacao = 'ok') AS ok,
       count(*) FILTER (WHERE situacao <> 'ok') AS falhas
  FROM resultado;

ROLLBACK;
