-- Liga FACOM Fantasy - 02-dados.sql
-- Dados que nao vem da API: tipos de scout, tecnicos, ligas e participacoes.
-- Rodar depois do 01-ddl.sql e antes da carga.

BEGIN;
SET search_path TO fantasy, public;

-- posicoes (mesmos ids da API). Precisam existir antes do tipo_scout_posicao,
-- a carga depois so atualiza.
INSERT INTO posicao (id, nome, abreviacao) VALUES
(1, 'Goleiro', 'gol'),
(2, 'Lateral', 'lat'),
(3, 'Zagueiro', 'zag'),
(4, 'Meia', 'mei'),
(5, 'Atacante', 'ata'),
(6, 'Técnico', 'tec');

-- tipos de scout (tabela da secao 2.7)
INSERT INTO tipo_scout (sigla, descricao, valor) VALUES
('G', 'Gol', 8.0),
('A', 'Assistência', 5.0),
('FT', 'Finalização na trave', 3.0),
('FD', 'Finalização defendida', 1.2),
('FF', 'Finalização para fora', 0.8),
('FS', 'Falta sofrida', 0.5),
('PS', 'Pênalti sofrido', 1.0),
('DS', 'Desarme', 1.5),
('SG', 'Jogo sem sofrer gol', 5.0),
('DE', 'Defesa', 1.3),
('DP', 'Defesa de pênalti', 7.0),
('GS', 'Gol sofrido', -1.0),
('FC', 'Falta cometida', -0.3),
('I', 'Impedimento', -0.1),
('CA', 'Cartão amarelo', -1.0),
('CV', 'Cartão vermelho', -3.0),
('GC', 'Gol contra', -3.0),
('PC', 'Pênalti cometido', -1.0),
('PP', 'Pênalti perdido', -4.0);

-- para quais posicoes cada scout pontua
-- tecnico real (tec) nao entra: a pontuacao dele vem do placar
-- scouts que valem para qualquer jogador
INSERT INTO tipo_scout_posicao (sigla, posicao_id)
SELECT t.sigla, p.id
FROM tipo_scout t, posicao p
WHERE p.abreviacao <> 'tec'
  AND t.sigla NOT IN ('SG', 'DE', 'DP', 'GS');

-- SG so para goleiro, lateral e zagueiro
INSERT INTO tipo_scout_posicao (sigla, posicao_id)
SELECT 'SG', id FROM posicao WHERE abreviacao IN ('gol', 'lat', 'zag');

-- DE, DP e GS so para goleiro
INSERT INTO tipo_scout_posicao (sigla, posicao_id)
SELECT t.sigla, p.id
FROM tipo_scout t, posicao p
WHERE t.sigla IN ('DE', 'DP', 'GS')
  AND p.abreviacao = 'gol';

-- tecnicos. id e patrimonio (100) vem do default
INSERT INTO tecnico (nome, email, apelido, nome_time) VALUES
('Bruno Rodrigues', 'bruno.rodrigues@exemplo.com', 'Bruno', 'Bits Futebol Clube'),
('Pedro Affonso', 'pedro.affonso@exemplo.com', 'Pedro', 'Pantanal FC'),
('João Gabriel', 'joao.gabriel@exemplo.com', 'João', 'Ipê FC'),
('William Cintra', 'william.cintra@exemplo.com', 'William', 'Morenão EC'),
('Murilo Bassan', 'murilo.bassan@exemplo.com', 'Murilo', 'Tereré FC'),
('Samuel Fialho', 'samuel.fialho@exemplo.com', 'Samuel', 'Guaicurus FC'),
('Guilherme Kenzo', 'guilherme.kenzo@exemplo.com', 'Kenzo', 'Arara Azul FC'),
('Antony Solteiro', 'antony.solteiro@exemplo.com', 'Antony', 'Cerrado EC');

-- ligas: 2 publicas e 1 privada
INSERT INTO liga (dono_id, nome, descricao, codigo_convite, limite_participantes, publica) VALUES
((SELECT id FROM tecnico WHERE email = 'bruno.rodrigues@exemplo.com'),
 'Liga FACOM Fantasy', 'Liga da turma de LBD', 'FACOM2026', 30, true),
((SELECT id FROM tecnico WHERE email = 'pedro.affonso@exemplo.com'),
 'Resenha do LBD', 'So entra com convite', 'RESENHA26', 6, false),
((SELECT id FROM tecnico WHERE email = 'murilo.bassan@exemplo.com'),
 'Bits e Bolas', NULL, 'BITSBOLA', 6, true);

-- participacoes. O dono tambem participa da propria liga.
-- Liga FACOM Fantasy: todos
INSERT INTO participacao (liga_id, tecnico_id)
SELECT l.id, t.id
FROM liga l, tecnico t
WHERE l.codigo_convite = 'FACOM2026';

-- Resenha do LBD (privada)
INSERT INTO participacao (liga_id, tecnico_id)
SELECT l.id, t.id
FROM liga l, tecnico t
WHERE l.codigo_convite = 'RESENHA26'
  AND t.email IN ('pedro.affonso@exemplo.com', 'bruno.rodrigues@exemplo.com',
                  'william.cintra@exemplo.com', 'antony.solteiro@exemplo.com');

-- Bits e Bolas
INSERT INTO participacao (liga_id, tecnico_id)
SELECT l.id, t.id
FROM liga l, tecnico t
WHERE l.codigo_convite = 'BITSBOLA'
  AND t.email IN ('murilo.bassan@exemplo.com', 'bruno.rodrigues@exemplo.com',
                  'joao.gabriel@exemplo.com', 'samuel.fialho@exemplo.com');

COMMIT;
