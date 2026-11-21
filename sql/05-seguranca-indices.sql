-- Liga FACOM Fantasy - 05-seguranca-indices.sql
-- Usuarios do banco e indices. Rodar depois do 03 e 04.

SET search_path TO fantasy, public;

-- ---------------------------------------------------------------
-- Usuarios
-- liga_app: usado pela aplicacao
-- liga_carga: usado pelo programa de carga
-- Patrimonio, preco, estado da rodada e pontuacao so mudam pelas
-- procedures do 03 (security definer).
-- ---------------------------------------------------------------

-- role vale pro servidor todo, entao so cria se nao existir
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'liga_app') THEN
        CREATE ROLE liga_app LOGIN PASSWORD 'liga_app_2026';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'liga_carga') THEN
        CREATE ROLE liga_carga LOGIN PASSWORD 'liga_carga_2026';
    END IF;
END $$;

ALTER ROLE liga_app SET search_path TO fantasy, public;
ALTER ROLE liga_carga SET search_path TO fantasy, public;

REVOKE ALL ON ALL TABLES IN SCHEMA fantasy FROM PUBLIC, liga_app, liga_carga;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA fantasy FROM PUBLIC, liga_app, liga_carga;
GRANT USAGE ON SCHEMA fantasy TO liga_app, liga_carga;

-- liga_app
GRANT SELECT ON ALL TABLES IN SCHEMA fantasy TO liga_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA fantasy TO liga_app;

-- codigo de convite so aparece pela fn_codigo_convite (so para o dono)
REVOKE SELECT ON liga FROM liga_app;
GRANT SELECT (id, dono_id, nome, descricao, limite_participantes, publica, criada_em) ON liga TO liga_app;

-- patrimonio nao esta na lista, entra pelo default (100)
GRANT INSERT (nome, email, apelido, nome_time) ON tecnico TO liga_app;
-- liga se cria pela sp_criar_liga (o gatilho coloca o dono na participacao)

-- status nao esta na lista: confirmar so pela procedure
GRANT INSERT (tecnico_id, rodada, esquema_id) ON escalacao TO liga_app;
GRANT UPDATE (esquema_id, capitao_id) ON escalacao TO liga_app;
GRANT DELETE ON escalacao TO liga_app;

-- preco_pago quem preenche e o gatilho
GRANT INSERT (tecnico_id, rodada, atleta_id) ON escalacao_atleta TO liga_app;
GRANT DELETE ON escalacao_atleta TO liga_app;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA fantasy TO liga_app;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA fantasy TO liga_app;

-- liga_carga: so as tabelas que vem da API
GRANT SELECT ON posicao, situacao, clube, esquema, rodada, partida, atleta,
                atleta_clube_rodada, atuacao, scout, tipo_scout TO liga_carga;
GRANT INSERT, UPDATE ON posicao, situacao, clube, esquema, partida,
                        atleta_clube_rodada, atuacao TO liga_carga;
GRANT INSERT, UPDATE, DELETE ON scout TO liga_carga;

-- so cria as rodadas, nao muda o estado
GRANT INSERT (numero) ON rodada TO liga_carga;

-- insere o preco inicial mas nao pode alterar depois
GRANT INSERT ON atleta TO liga_carga;
GRANT UPDATE (nome, apelido, posicao_id, situacao_id) ON atleta TO liga_carga;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA fantasy TO liga_carga;

-- ---------------------------------------------------------------
-- Indices
-- PK e UNIQUE ja tem indice, aqui sao FKs e filtros das consultas
-- ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_acr_rodada_clube ON atleta_clube_rodada (rodada, clube_id);   -- mercado por clube, consulta g
CREATE INDEX IF NOT EXISTS ix_atuacao_rodada_posicao ON atuacao (rodada, posicao_id);       -- consolidacao, consulta h
CREATE INDEX IF NOT EXISTS ix_scout_rodada ON scout (rodada);                               -- consolidacao e carga
CREATE INDEX IF NOT EXISTS ix_escalacao_rodada_status ON escalacao (rodada, status);        -- consolidacao, consulta d
CREATE INDEX IF NOT EXISTS ix_escalacao_atleta_atleta ON escalacao_atleta (atleta_id);      -- consulta g
CREATE INDEX IF NOT EXISTS ix_participacao_tecnico ON participacao (tecnico_id);            -- ligas do tecnico, consulta j
CREATE INDEX IF NOT EXISTS ix_atleta_posicao ON atleta (posicao_id);                        -- filtro do mercado
CREATE INDEX IF NOT EXISTS ix_atleta_situacao ON atleta (situacao_id);                      -- filtro do mercado
CREATE INDEX IF NOT EXISTS ix_partida_mandante ON partida (mandante_id);                    -- consulta e
CREATE INDEX IF NOT EXISTS ix_partida_visitante ON partida (visitante_id);                  -- consulta e
CREATE INDEX IF NOT EXISTS ix_liga_dono ON liga (dono_id);
CREATE INDEX IF NOT EXISTS ix_historico_preco_rodada ON historico_preco (rodada);

-- teste: EXPLAIN ANALYZE SELECT * FROM atleta_clube_rodada WHERE rodada = 10 AND clube_id = 262;
