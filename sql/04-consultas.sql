-- 04-consultas.sql
-- Os parâmetros tem valor fixo de exemplo, marcados com "-- PARÂMETRO".

SET search_path TO fantasy, public;
-- vw_pontuacao_rodada: pontuação de cada atleta em cada rodada, com o
-- clube e a posição daquela rodada. Usa a função 6(a).
CREATE OR REPLACE VIEW vw_pontuacao_rodada AS
SELECT at.atleta_id,
       at.rodada,
       v.clube_id,
       at.posicao_id,
       at.entrou_em_campo,
       fn_pontuacao_atleta(at.atleta_id, at.rodada) AS pontuacao,
       r.estado AS estado_rodada
  FROM atuacao at
  JOIN atleta_clube_rodada v ON v.atleta_id = at.atleta_id AND v.rodada = at.rodada
  JOIN rodada r ON r.numero = at.rodada;

-- vw_pontuacao_acumulada: soma das escalações de cada técnico nas rodadas
-- consolidadas. Quem nunca pontuou fica com zero.
CREATE OR REPLACE VIEW vw_pontuacao_acumulada AS
SELECT t.id                          AS tecnico_id,
       coalesce(sum(e.pontuacao), 0) AS pontuacao,
       count(e.pontuacao)            AS rodadas_pontuadas
  FROM tecnico t
  LEFT JOIN (escalacao e
             JOIN rodada r ON r.numero = e.rodada AND r.estado = 'consolidada')
         ON e.tecnico_id = t.id AND e.status = 'confirmada'
 GROUP BY t.id;

-- (a) Visão do mercado
-- Disponível = provável ou dúvida. A média usa as rodadas consolidadas em
-- que o atleta entrou em campo. Sem rodada aberta, a visão fica vazia.
CREATE OR REPLACE VIEW vw_mercado AS
WITH desempenho AS (
    SELECT atleta_id,
           round(avg(pontuacao), 2)                       AS media,
           count(*)                                       AS jogos,
           max(rodada)                                    AS ultima_rodada,
           (array_agg(pontuacao ORDER BY rodada DESC))[1] AS ultima_pontuacao
      FROM vw_pontuacao_rodada
     WHERE estado_rodada = 'consolidada'
       AND entrou_em_campo
     GROUP BY atleta_id
)
SELECT r.numero          AS rodada,
       a.id              AS atleta_id,
       a.apelido,
       c.abreviacao      AS clube,
       p.abreviacao      AS posicao,
       s.nome            AS situacao,
       a.preco_atual     AS preco,
       d.media,
       coalesce(d.jogos, 0) AS jogos,
       d.ultima_pontuacao,
       d.ultima_rodada,
       c.id              AS clube_id,
       p.id              AS posicao_id
  FROM rodada r
  JOIN atleta_clube_rodada v ON v.rodada = r.numero
  JOIN atleta a              ON a.id = v.atleta_id
  JOIN clube c               ON c.id = v.clube_id
  JOIN posicao p             ON p.id = a.posicao_id
  JOIN situacao s            ON s.id = a.situacao_id
  LEFT JOIN desempenho d     ON d.atleta_id = a.id
 WHERE r.estado = 'aberta'
   AND s.escalavel;

-- (b) Visão do ranking
-- RANK() dá a mesma posição aos empatados.
CREATE OR REPLACE VIEW vw_ranking_liga AS
SELECT l.id                  AS liga_id,
       l.nome                AS liga,
       t.id                  AS tecnico_id,
       t.apelido             AS tecnico,
       t.nome_time           AS time,
       ac.pontuacao,
       ac.rodadas_pontuadas,
       rank() OVER (PARTITION BY l.id ORDER BY ac.pontuacao DESC) AS posicao
  FROM liga l
  JOIN participacao pa           ON pa.liga_id = l.id
  JOIN tecnico t                 ON t.id = pa.tecnico_id
  JOIN vw_pontuacao_acumulada ac ON ac.tecnico_id = t.id;

-- Ranking por rodada, usado na aplicação (item 7c). Quem não escalou faz zero.
CREATE OR REPLACE VIEW vw_ranking_rodada AS
SELECT l.id                     AS liga_id,
       l.nome                   AS liga,
       r.numero                 AS rodada,
       t.id                     AS tecnico_id,
       t.apelido                AS tecnico,
       t.nome_time              AS time,
       coalesce(e.pontuacao, 0) AS pontuacao,
       rank() OVER (PARTITION BY l.id, r.numero
                    ORDER BY coalesce(e.pontuacao, 0) DESC) AS posicao
  FROM liga l
  JOIN participacao pa ON pa.liga_id = l.id
  JOIN tecnico t       ON t.id = pa.tecnico_id
  JOIN rodada r        ON r.estado = 'consolidada'
  LEFT JOIN escalacao e
         ON e.tecnico_id = t.id AND e.rodada = r.numero AND e.status = 'confirmada';

-- (c) Os 5 de cada posição com melhor custo-benefício,
-- só quem entrou em campo em pelo menos 3 rodadas consolidadas.
-- Empate: fica o mais barato.
WITH desempenho AS (
    SELECT atleta_id,
           avg(pontuacao) AS media,
           count(*)       AS rodadas
      FROM vw_pontuacao_rodada
     WHERE estado_rodada = 'consolidada'
       AND entrou_em_campo
     GROUP BY atleta_id
    HAVING count(*) >= 3
),
classificado AS (
    SELECT p.id    AS posicao_id,
           p.nome  AS posicao,
           a.apelido,
           a.preco_atual,
           d.media,
           d.rodadas,
           d.media / a.preco_atual AS custo_beneficio,
           row_number() OVER (PARTITION BY p.id
                              ORDER BY d.media / a.preco_atual DESC, a.preco_atual) AS lugar
      FROM desempenho d
      JOIN atleta a  ON a.id = d.atleta_id
      JOIN posicao p ON p.id = a.posicao_id
)
SELECT posicao,
       lugar,
       apelido,
       preco_atual                AS preco,
       round(media, 2)            AS media,
       rodadas,
       round(custo_beneficio, 3)  AS pontos_por_cartoleta
  FROM classificado
 WHERE lugar <= 5
 ORDER BY posicao_id, lugar;

-- (d) Top da rodada
-- Empate: vence quem confirmou a escalação primeiro.
SELECT e.rodada,
       t.apelido       AS tecnico,
       t.nome_time     AS time,
       e.pontuacao,
       cap.apelido     AS capitao,
       e.confirmada_em
  FROM escalacao e
  JOIN rodada r     ON r.numero = e.rodada AND r.estado = 'consolidada'
  JOIN tecnico t    ON t.id = e.tecnico_id
  JOIN atleta cap   ON cap.id = e.capitao_id
 WHERE e.rodada = 1                   -- PARÂMETRO: rodada consolidada
   AND e.status = 'confirmada'
 ORDER BY e.pontuacao DESC, e.confirmada_em ASC
 LIMIT 1;

-- (e) Clube com mais jogos sem sofrer gol nas últimas 5 rodadas consolidadas
-- Cada partida conta uma vez para o mandante e outra para o visitante.
-- Partida adiada não conta. Empatados aparecem juntos.
WITH ultimas AS (
    SELECT numero
      FROM rodada
     WHERE estado = 'consolidada'
     ORDER BY numero DESC
     LIMIT 5
),
jogos AS (
    SELECT p.mandante_id AS clube_id, p.placar_visitante = 0 AS sem_sofrer_gol
      FROM partida p JOIN ultimas u ON u.numero = p.rodada
     WHERE p.valida AND p.placar_mandante IS NOT NULL
    UNION ALL
    SELECT p.visitante_id, p.placar_mandante = 0
      FROM partida p JOIN ultimas u ON u.numero = p.rodada
     WHERE p.valida AND p.placar_mandante IS NOT NULL
)
SELECT c.nome                                  AS clube,
       c.abreviacao,
       count(*) FILTER (WHERE j.sem_sofrer_gol) AS jogos_sem_sofrer_gol,
       count(*)                                AS jogos
  FROM jogos j
  JOIN clube c ON c.id = j.clube_id
 GROUP BY c.id, c.nome, c.abreviacao
 ORDER BY jogos_sem_sofrer_gol DESC
 FETCH FIRST 1 ROWS WITH TIES;

-- (f) Atleta mais escolhido como capitão na liga
-- Só escalações confirmadas. Empatados aparecem juntos.
SELECT a.apelido  AS capitao,
       count(*)   AS vezes
  FROM liga l
  JOIN participacao pa ON pa.liga_id = l.id
  JOIN escalacao e     ON e.tecnico_id = pa.tecnico_id AND e.status = 'confirmada'
  JOIN atleta a        ON a.id = e.capitao_id
 WHERE l.codigo_convite = 'FACOM2026'      -- PARÂMETRO: liga (Liga FACOM Fantasy)
 GROUP BY a.id, a.apelido
 ORDER BY vezes DESC
 FETCH FIRST 1 ROWS WITH TIES;

-- (g) Técnicos que nunca escalaram atleta do clube informado
-- Vale o clube do atleta na rodada da escalação, não o de hoje.
-- Só escalações confirmadas.
SELECT t.apelido AS tecnico,
       t.nome_time AS time
  FROM tecnico t
 WHERE NOT EXISTS (
        SELECT 1
          FROM escalacao e
          JOIN escalacao_atleta ea   ON ea.tecnico_id = e.tecnico_id AND ea.rodada = e.rodada
          JOIN atleta_clube_rodada v ON v.atleta_id = ea.atleta_id AND v.rodada = ea.rodada
          JOIN clube c  ON c.id = v.clube_id
         WHERE e.tecnico_id = t.id
           AND e.status = 'confirmada'
           AND c.abreviacao = 'FLA')  -- PARÂMETRO: clube
 ORDER BY t.apelido;

-- (h) Atletas que pontuaram acima da média da posição em todas as rodadas consolidadas em que entraram em campo.
-- bool_and só é verdadeiro se a comparação vale em todas as rodadas.
WITH pontos AS (
    SELECT atleta_id, rodada, posicao_id, pontuacao
      FROM vw_pontuacao_rodada
     WHERE estado_rodada = 'consolidada'
       AND entrou_em_campo
),
media_posicao AS (
    SELECT rodada, posicao_id, avg(pontuacao) AS media FROM pontos
     GROUP BY rodada, posicao_id
)
SELECT a.apelido,
       ps.nome                       AS posicao,
       count(*)                      AS rodadas,
       round(avg(pt.pontuacao), 2)   AS media_do_atleta
  FROM pontos pt
  JOIN media_posicao m ON m.rodada = pt.rodada AND m.posicao_id = pt.posicao_id
  JOIN atleta a ON a.id = pt.atleta_id
  JOIN posicao ps ON ps.id = a.posicao_id
 GROUP BY a.id, a.apelido, ps.nome
HAVING bool_and(pt.pontuacao > m.media)
 ORDER BY rodadas DESC, media_do_atleta DESC;

-- (i) Evolução do patrimônio de um técnico rodada a rodada
-- Começa em C$ 100,00 e muda pela variacao_patrimonio de cada rodada
-- (zero se não escalou).
WITH tecnico_escolhido AS (
    SELECT id FROM tecnico
     WHERE email = 'pedro.affonso@exemplo.com'   -- PARAMETRO: técnico
),
por_rodada AS (
    SELECT r.numero AS rodada,
           coalesce(e.variacao_patrimonio, 0) AS variacao
      FROM rodada r
     CROSS JOIN tecnico_escolhido te
      LEFT JOIN escalacao e
             ON e.tecnico_id = te.id AND e.rodada = r.numero AND e.status = 'confirmada'
     WHERE r.estado = 'consolidada'
),
evolucao AS (
    SELECT rodada,
           100.00 + sum(variacao) OVER (ORDER BY rodada) AS patrimonio
      FROM por_rodada
)
SELECT rodada,
       patrimonio,
       patrimonio - lag(patrimonio, 1, 100.00) OVER (ORDER BY rodada) AS variacao_sobre_anterior
  FROM evolucao ORDER BY rodada;

-- (j) Ligas com pelo menos 3 participantes e média acima da média geral
-- A média geral inclui técnicos que não estão em liga nenhuma.
WITH media_geral AS (
    SELECT avg(pontuacao) AS media FROM vw_pontuacao_acumulada
)
SELECT l.nome AS liga,
       count(*) AS participantes,
       round(avg(ac.pontuacao), 2) AS media_da_liga,
       round(mg.media, 2) AS media_geral
  FROM liga l
  JOIN participacao pa           ON pa.liga_id = l.id
  JOIN vw_pontuacao_acumulada ac ON ac.tecnico_id = pa.tecnico_id
 CROSS JOIN media_geral mg
 GROUP BY l.id, l.nome, mg.media
HAVING count(*) >= 3
   AND avg(ac.pontuacao) > mg.media
 ORDER BY media_da_liga DESC;

-- (k) Seleção da rodada: o melhor de cada posição que custava até
-- C$ 12,00 naquela rodada, e o custo do time.
-- Empate: fica o mais barato.
WITH candidatos AS (
    SELECT pr.atleta_id,
           pr.posicao_id,
           pr.clube_id,
           pr.pontuacao,
           h.preco_rodada,
           row_number() OVER (PARTITION BY pr.posicao_id
                              ORDER BY pr.pontuacao DESC, h.preco_rodada, pr.atleta_id) AS lugar
      FROM vw_pontuacao_rodada pr
      JOIN historico_preco h ON h.atleta_id = pr.atleta_id AND h.rodada = pr.rodada
     WHERE pr.rodada = 1                  -- PARÂMETRO: rodada consolidada
       AND pr.estado_rodada = 'consolidada'
       AND pr.entrou_em_campo
       AND h.preco_rodada <= 12.00
)
SELECT ps.nome AS posicao,
       a.apelido,
       c.abreviacao AS clube,
       ca.pontuacao,
       ca.preco_rodada AS preco_na_rodada,
       sum(ca.preco_rodada) OVER () AS custo_total_do_time
  FROM candidatos ca
  JOIN atleta a   ON a.id = ca.atleta_id
  JOIN posicao ps ON ps.id = ca.posicao_id
  JOIN clube c    ON c.id = ca.clube_id
 WHERE ca.lugar = 1
 ORDER BY ps.id;
 