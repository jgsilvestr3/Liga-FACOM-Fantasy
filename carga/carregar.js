// =====================================================================
// Liga FACOM Fantasy - CARGA dos dados da API no PostgreSQL
// ---------------------------------------------------------------------
// Lê os arquivos .json salvos por coletar.js (carga/dados/) e grava no
// banco: posições, situações, clubes, esquemas, rodadas, partidas,
// atletas, o clube de cada atleta em cada rodada, as atuações e os scouts.
//
// Uso:  node carga/carregar.js        (depois dos scripts 01 a 05)
//
// Garantias pedidas no item 4a:
//   - pode rodar duas vezes seguidas sem duplicar e sem erro: todo INSERT
//     usa ON CONFLICT pela chave (os números da própria fonte) e só
//     atualiza quando algum valor mudou;
//   - só consultas parametrizadas: os valores vão em $1, $2... (aqui,
//     vetores inteiros por parâmetro, desmontados com unnest), nunca
//     concatenados no texto do SQL;
//   - tudo numa transação: se algo falhar, nada fica gravado pela metade.
// Rodadas já consolidadas na liga não são recarregadas (o banco recusaria,
// com razão: o gatilho do item 6d congela os dados delas).
// =====================================================================

const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

const PASTA_DADOS = path.join(__dirname, 'dados');
const TOTAL_RODADAS = 38;

const conexao = {
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'liga_fantasy',
  user: process.env.PGUSER || 'liga_carga',
  password: process.env.PGPASSWORD || 'liga_carga_2026',
  options: '-c search_path=fantasy,public',
};

const doisDigitos = (n) => String(n).padStart(2, '0');

function lerJson(nomeArquivo, obrigatorio = true) {
  const caminho = path.join(PASTA_DADOS, nomeArquivo);
  if (!fs.existsSync(caminho)) {
    if (obrigatorio) {
      throw new Error(`Arquivo ${nomeArquivo} não encontrado em ${PASTA_DADOS}. Rode antes: node carga/coletar.js`);
    }
    return null;
  }
  return JSON.parse(fs.readFileSync(caminho, 'utf8'));
}

// A API de 2026 devolve no campo "nome" do clube a própria sigla ("FLA").
// O slug ("sao-paulo", "atletico-mg") permite montar um nome legível; o
// dicionário só repõe os acentos que o slug perde.
const ACENTOS = { sao: 'São', atletico: 'Atlético', gremio: 'Grêmio', vitoria: 'Vitória' };
function nomeDoClube(clube) {
  if (clube.nome && clube.nome !== clube.abreviacao && clube.nome.length > 3) {
    return clube.nome;
  }
  return clube.slug
    .split('-')
    .map((parte) => ACENTOS[parte] || (parte.length <= 2 ? parte.toUpperCase()
                                                      : parte[0].toUpperCase() + parte.slice(1)))
    .join(' ');
}

async function main() {
  // ------------------------------------------------------------------
  // Leitura dos arquivos
  // ------------------------------------------------------------------
  const status = lerJson('mercado_status.json');
  const mercado = lerJson('atletas_mercado.json');
  const esquemas = lerJson('esquemas.json');
  const partidasPorRodada = new Map();
  const pontuadosPorRodada = new Map();
  for (let r = 1; r <= TOTAL_RODADAS; r++) {
    const partidas = lerJson(`partidas_${doisDigitos(r)}.json`, false);
    if (partidas) partidasPorRodada.set(r, partidas);
    const pontuados = lerJson(`pontuados_${doisDigitos(r)}.json`, false);
    if (pontuados && pontuados.atletas) pontuadosPorRodada.set(r, pontuados);
  }
  console.log(`Arquivos lidos: ${mercado.atletas.length} atletas no mercado, ` +
              `partidas de ${partidasPorRodada.size} rodadas, scouts de ${pontuadosPorRodada.size} rodadas.`);

  const cliente = new Client(conexao);
  await cliente.connect();
  const resumo = {};

  try {
    await cliente.query('BEGIN');

    // ----------------------------------------------------------------
    // 1) Posições e situações
    // ----------------------------------------------------------------
    const posicoes = Object.values(mercado.posicoes);
    await cliente.query(
      `INSERT INTO posicao (id, nome, abreviacao)
       SELECT * FROM unnest($1::int[], $2::text[], $3::text[])
       ON CONFLICT (id) DO UPDATE
          SET nome = EXCLUDED.nome, abreviacao = EXCLUDED.abreviacao
        WHERE (posicao.nome, posicao.abreviacao) IS DISTINCT FROM (EXCLUDED.nome, EXCLUDED.abreviacao)`,
      [posicoes.map((p) => p.id), posicoes.map((p) => p.nome), posicoes.map((p) => p.abreviacao)]);
    resumo.posicoes = posicoes.length;

    const situacoes = Object.values(mercado.status);
    await cliente.query(
      `INSERT INTO situacao (id, nome)
       SELECT * FROM unnest($1::int[], $2::text[])
       ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome
        WHERE situacao.nome IS DISTINCT FROM EXCLUDED.nome`,
      [situacoes.map((s) => s.id), situacoes.map((s) => s.nome)]);
    resumo.situacoes = situacoes.length;
    const { rows: [nulo] } = await cliente.query(`SELECT id FROM situacao WHERE nome = $1`, ['Nulo']);

    // ----------------------------------------------------------------
    // 2) Clubes: os do mercado e os que aparecem nas partidas
    // ----------------------------------------------------------------
    const clubes = new Map();
    const juntarClubes = (objeto) => {
      for (const c of Object.values(objeto || {})) if (c && c.id) clubes.set(c.id, c);
    };
    juntarClubes(mercado.clubes);
    for (const partidas of partidasPorRodada.values()) juntarClubes(partidas.clubes);
    const listaClubes = [...clubes.values()];
    await cliente.query(
      `INSERT INTO clube (id, nome, abreviacao, escudo_url)
       SELECT * FROM unnest($1::int[], $2::text[], $3::text[], $4::text[])
       ON CONFLICT (id) DO UPDATE
          SET nome = EXCLUDED.nome, abreviacao = EXCLUDED.abreviacao, escudo_url = EXCLUDED.escudo_url
        WHERE (clube.nome, clube.abreviacao, clube.escudo_url)
              IS DISTINCT FROM (EXCLUDED.nome, EXCLUDED.abreviacao, EXCLUDED.escudo_url)`,
      [listaClubes.map((c) => c.id),
       listaClubes.map(nomeDoClube),
       listaClubes.map((c) => c.abreviacao),
       listaClubes.map((c) => (c.escudos && c.escudos['60x60']) || null)]);
    resumo.clubes = listaClubes.length;

    // ----------------------------------------------------------------
    // 3) Esquemas táticos
    // ----------------------------------------------------------------
    const qtd = (e, pos) => e.posicoes[pos] || 0;
    await cliente.query(
      `INSERT INTO esquema (id, nome, qtd_gol, qtd_lat, qtd_zag, qtd_mei, qtd_ata, qtd_tec)
       SELECT * FROM unnest($1::int[], $2::text[], $3::int[], $4::int[], $5::int[], $6::int[], $7::int[], $8::int[])
       ON CONFLICT (id) DO UPDATE
          SET nome = EXCLUDED.nome, qtd_gol = EXCLUDED.qtd_gol, qtd_lat = EXCLUDED.qtd_lat,
              qtd_zag = EXCLUDED.qtd_zag, qtd_mei = EXCLUDED.qtd_mei, qtd_ata = EXCLUDED.qtd_ata,
              qtd_tec = EXCLUDED.qtd_tec
        WHERE (esquema.nome, esquema.qtd_gol, esquema.qtd_lat, esquema.qtd_zag, esquema.qtd_mei,
               esquema.qtd_ata, esquema.qtd_tec)
              IS DISTINCT FROM (EXCLUDED.nome, EXCLUDED.qtd_gol, EXCLUDED.qtd_lat, EXCLUDED.qtd_zag,
                                EXCLUDED.qtd_mei, EXCLUDED.qtd_ata, EXCLUDED.qtd_tec)`,
      [esquemas.map((e) => e.esquema_id), esquemas.map((e) => e.nome),
       esquemas.map((e) => qtd(e, 'gol')), esquemas.map((e) => qtd(e, 'lat')),
       esquemas.map((e) => qtd(e, 'zag')), esquemas.map((e) => qtd(e, 'mei')),
       esquemas.map((e) => qtd(e, 'ata')), esquemas.map((e) => qtd(e, 'tec'))]);
    resumo.esquemas = esquemas.length;

    // ----------------------------------------------------------------
    // 4) As 38 rodadas (nascem "futura"; o estado é do administrador)
    // ----------------------------------------------------------------
    await cliente.query(
      `INSERT INTO rodada (numero)
       SELECT generate_series(1, $1::int)
       ON CONFLICT (numero) DO NOTHING`, [TOTAL_RODADAS]);
    const { rows: consolidadas } = await cliente.query(
      `SELECT numero FROM rodada WHERE estado = $1`, ['consolidada']);
    const rodadaConsolidada = new Set(consolidadas.map((r) => r.numero));
    const rodadasAbertasParaCarga = [];
    for (let r = 1; r <= TOTAL_RODADAS; r++) if (!rodadaConsolidada.has(r)) rodadasAbertasParaCarga.push(r);
    if (rodadaConsolidada.size > 0) {
      console.log(`Rodadas já consolidadas na liga (não são recarregadas): ${[...rodadaConsolidada].join(', ')}`);
    }

    // ----------------------------------------------------------------
    // 5) Partidas
    // ----------------------------------------------------------------
    const partidas = [];
    for (const [r, arquivo] of partidasPorRodada) {
      if (rodadaConsolidada.has(r)) continue;
      for (const p of arquivo.partidas) partidas.push({ ...p, rodada: r });
    }
    await cliente.query(
      `INSERT INTO partida (id, rodada, mandante_id, visitante_id, local, data_hora,
                            placar_mandante, placar_visitante, valida)
       SELECT * FROM unnest($1::int[], $2::int[], $3::int[], $4::int[], $5::text[],
                            $6::timestamp[], $7::smallint[], $8::smallint[], $9::boolean[])
       ON CONFLICT (id) DO UPDATE
          SET rodada = EXCLUDED.rodada, mandante_id = EXCLUDED.mandante_id,
              visitante_id = EXCLUDED.visitante_id, local = EXCLUDED.local,
              data_hora = EXCLUDED.data_hora, placar_mandante = EXCLUDED.placar_mandante,
              placar_visitante = EXCLUDED.placar_visitante, valida = EXCLUDED.valida
        WHERE (partida.rodada, partida.mandante_id, partida.visitante_id, partida.local,
               partida.data_hora, partida.placar_mandante, partida.placar_visitante, partida.valida)
              IS DISTINCT FROM
              (EXCLUDED.rodada, EXCLUDED.mandante_id, EXCLUDED.visitante_id, EXCLUDED.local,
               EXCLUDED.data_hora, EXCLUDED.placar_mandante, EXCLUDED.placar_visitante, EXCLUDED.valida)`,
      [partidas.map((p) => p.partida_id), partidas.map((p) => p.rodada),
       partidas.map((p) => p.clube_casa_id), partidas.map((p) => p.clube_visitante_id),
       partidas.map((p) => p.local), partidas.map((p) => p.partida_data),
       partidas.map((p) => p.placar_oficial_mandante), partidas.map((p) => p.placar_oficial_visitante),
       partidas.map((p) => p.valida !== false)]);
    resumo.partidas = partidas.length;

    // ----------------------------------------------------------------
    // 6) Atletas do mercado. O preço só é gravado na INSERÇÃO: é o preço
    //    inicial da liga (seção 4.3). Numa recarga, nome, posição e
    //    situação são atualizados, o preço não (quem muda preço é a
    //    valorização). A liga tem piso de C$ 1,00 (seção 2.8); a API traz
    //    alguns atletas mais baratos, que entram com C$ 1,00.
    // ----------------------------------------------------------------
    const atletasMercado = mercado.atletas;
    await cliente.query(
      `INSERT INTO atleta (id, nome, apelido, posicao_id, situacao_id, preco_atual)
       SELECT m.id, m.nome, m.apelido, m.posicao_id, m.situacao_id, greatest(m.preco, 1.00)
         FROM unnest($1::int[], $2::text[], $3::text[], $4::int[], $5::int[], $6::numeric[])
              AS m(id, nome, apelido, posicao_id, situacao_id, preco)
       ON CONFLICT (id) DO UPDATE
          SET nome = EXCLUDED.nome, apelido = EXCLUDED.apelido,
              posicao_id = EXCLUDED.posicao_id, situacao_id = EXCLUDED.situacao_id
        WHERE (atleta.nome, atleta.apelido, atleta.posicao_id, atleta.situacao_id)
              IS DISTINCT FROM (EXCLUDED.nome, EXCLUDED.apelido, EXCLUDED.posicao_id, EXCLUDED.situacao_id)`,
      [atletasMercado.map((a) => a.atleta_id),
       atletasMercado.map((a) => (a.nome && a.nome.trim()) || a.apelido),
       atletasMercado.map((a) => a.apelido),
       atletasMercado.map((a) => a.posicao_id),
       atletasMercado.map((a) => a.status_id),
       atletasMercado.map((a) => a.preco_num)]);
    resumo.atletas_mercado = atletasMercado.length;
    resumo.precos_com_piso = atletasMercado.filter((a) => a.preco_num < 1).length;

    // Atletas que pontuaram em rodadas antigas e não estão mais no mercado
    // (transferidos para fora, técnicos demitidos): a carga não pode falhar
    // por causa deles (seção 4.3). Entram com situação Nulo (não podem ser
    // escalados), preço mínimo e a posição da rodada mais recente.
    const idsMercado = new Set(atletasMercado.map((a) => a.atleta_id));
    const foraDoMercado = new Map();
    const rodadasPontuadas = [...pontuadosPorRodada.keys()].sort((a, b) => b - a); // mais recente primeiro
    for (const r of rodadasPontuadas) {
      for (const [id, a] of Object.entries(pontuadosPorRodada.get(r).atletas)) {
        const atletaId = Number(id);
        if (!idsMercado.has(atletaId) && !foraDoMercado.has(atletaId)) {
          foraDoMercado.set(atletaId, { id: atletaId, apelido: a.apelido, posicao_id: a.posicao_id });
        }
      }
    }
    const listaFora = [...foraDoMercado.values()];
    await cliente.query(
      `INSERT INTO atleta (id, nome, apelido, posicao_id, situacao_id, preco_atual)
       SELECT f.id, f.apelido, f.apelido, f.posicao_id, $4::int, 1.00
         FROM unnest($1::int[], $2::text[], $3::int[]) AS f(id, apelido, posicao_id)
       ON CONFLICT (id) DO NOTHING`,
      [listaFora.map((a) => a.id), listaFora.map((a) => a.apelido), listaFora.map((a) => a.posicao_id), nulo.id]);
    resumo.atletas_fora_do_mercado = listaFora.length;

    // Quem estava no banco e saiu do mercado nesta nova coleta fica Nulo.
    const { rowCount: viraramNulo } = await cliente.query(
      `UPDATE atleta SET situacao_id = $2
        WHERE id <> ALL ($1::int[]) AND situacao_id <> $2`,
      [atletasMercado.map((a) => a.atleta_id), nulo.id]);
    resumo.atletas_que_sairam_do_mercado = viraramNulo;

    // ----------------------------------------------------------------
    // 7) Clube de cada atleta em cada rodada (seção 2.2).
    //    Observações exatas: o clube informado em /atletas/pontuados de
    //    cada rodada jogada e o clube atual do mercado (rodada atual).
    //    Rodadas sem observação: vale o último clube observado antes dela;
    //    antes da primeira observação, vale o primeiro clube observado.
    //    Assim todo atleta tem exatamente um clube em cada uma das 38
    //    rodadas, e quem foi transferido muda de clube na rodada em que
    //    aparece jogando pelo novo.
    // ----------------------------------------------------------------
    const observacoes = new Map(); // atleta -> Map(rodada -> clube)
    const observar = (atletaId, rodada, clubeId) => {
      if (!clubeId) return;
      if (!observacoes.has(atletaId)) observacoes.set(atletaId, new Map());
      observacoes.get(atletaId).set(rodada, clubeId);
    };
    for (const [r, arquivo] of pontuadosPorRodada) {
      for (const [id, a] of Object.entries(arquivo.atletas)) observar(Number(id), r, a.clube_id);
    }
    for (const a of atletasMercado) {
      // o mercado vale para a rodada atual; não sobrescreve uma rodada já jogada
      if (!observacoes.has(a.atleta_id) || !observacoes.get(a.atleta_id).has(status.rodada_atual)) {
        observar(a.atleta_id, status.rodada_atual, a.clube_id);
      }
    }
    const vinculo = { atleta: [], rodada: [], clube: [] };
    for (const [atletaId, porRodada] of observacoes) {
      const rodadasObservadas = [...porRodada.keys()].sort((a, b) => a - b);
      let indice = 0;
      let clubeVigente = porRodada.get(rodadasObservadas[0]); // antes da 1ª observação
      for (let r = 1; r <= TOTAL_RODADAS; r++) {
        while (indice < rodadasObservadas.length && rodadasObservadas[indice] <= r) {
          clubeVigente = porRodada.get(rodadasObservadas[indice]);
          indice++;
        }
        if (rodadaConsolidada.has(r)) continue;
        vinculo.atleta.push(atletaId);
        vinculo.rodada.push(r);
        vinculo.clube.push(clubeVigente);
      }
    }
    await cliente.query(
      `INSERT INTO atleta_clube_rodada (atleta_id, rodada, clube_id)
       SELECT * FROM unnest($1::int[], $2::int[], $3::int[])
       ON CONFLICT (atleta_id, rodada) DO UPDATE SET clube_id = EXCLUDED.clube_id
        WHERE atleta_clube_rodada.clube_id <> EXCLUDED.clube_id`,
      [vinculo.atleta, vinculo.rodada, vinculo.clube]);
    resumo.vinculos_atleta_rodada = vinculo.atleta.length;

    // ----------------------------------------------------------------
    // 8) Atuações e scouts de cada rodada jogada.
    //    A API não diz em que partida o atleta jogou: a carga descobre
    //    cruzando o clube dele com /partidas da mesma rodada e só registra a
    //    atuação se o clube tiver partida na rodada. A partida não é
    //    gravada na atuação porque é determinada pelo clube + rodada.
    //    Siglas fora da tabela da seção 2.7 (o "V" dos técnicos) não
    //    pontuam na liga e são ignoradas.
    // ----------------------------------------------------------------
    const { rows: tipos } = await cliente.query('SELECT sigla FROM tipo_scout');
    const siglasConhecidas = new Set(tipos.map((t) => t.sigla));
    const ignoradas = {};
    let totalAtuacoes = 0;
    let totalScouts = 0;
    let semPartida = 0;

    for (const [r, arquivo] of [...pontuadosPorRodada].sort((a, b) => a[0] - b[0])) {
      if (rodadaConsolidada.has(r)) continue;
      const clubesComPartida = new Set();
      for (const p of (partidasPorRodada.get(r) || { partidas: [] }).partidas) {
        clubesComPartida.add(p.clube_casa_id);
        clubesComPartida.add(p.clube_visitante_id);
      }

      const at = { atleta: [], posicao: [], entrou: [], pontuacao: [] };
      const sc = { atleta: [], sigla: [], quantidade: [] };
      for (const [id, a] of Object.entries(arquivo.atletas)) {
        if (!clubesComPartida.has(a.clube_id)) { semPartida++; continue; }
        const atletaId = Number(id);
        at.atleta.push(atletaId);
        at.posicao.push(a.posicao_id);
        at.entrou.push(a.entrou_em_campo === true);
        at.pontuacao.push(a.pontuacao ?? null);
        for (const [sigla, quantidade] of Object.entries(a.scout || {})) {
          if (!siglasConhecidas.has(sigla)) {
            ignoradas[sigla] = (ignoradas[sigla] || 0) + 1;
            continue;
          }
          if (quantidade > 0) {
            sc.atleta.push(atletaId);
            sc.sigla.push(sigla);
            sc.quantidade.push(quantidade);
          }
        }
      }

      await cliente.query(
        `INSERT INTO atuacao (atleta_id, rodada, posicao_id, entrou_em_campo, pontuacao_cartola)
         SELECT a.atleta_id, $2::int, a.posicao_id, a.entrou, a.pontuacao
           FROM unnest($1::int[], $3::int[], $4::boolean[], $5::numeric[])
                AS a(atleta_id, posicao_id, entrou, pontuacao)
         ON CONFLICT (atleta_id, rodada) DO UPDATE
            SET posicao_id = EXCLUDED.posicao_id, entrou_em_campo = EXCLUDED.entrou_em_campo,
                pontuacao_cartola = EXCLUDED.pontuacao_cartola
          WHERE (atuacao.posicao_id, atuacao.entrou_em_campo, atuacao.pontuacao_cartola)
                IS DISTINCT FROM (EXCLUDED.posicao_id, EXCLUDED.entrou_em_campo, EXCLUDED.pontuacao_cartola)`,
        [at.atleta, r, at.posicao, at.entrou, at.pontuacao]);

      await cliente.query(
        `INSERT INTO scout (atleta_id, rodada, sigla, quantidade)
         SELECT s.atleta_id, $2::int, s.sigla, s.quantidade
           FROM unnest($1::int[], $3::text[], $4::smallint[]) AS s(atleta_id, sigla, quantidade)
         ON CONFLICT (atleta_id, rodada, sigla) DO UPDATE SET quantidade = EXCLUDED.quantidade
          WHERE scout.quantidade <> EXCLUDED.quantidade`,
        [sc.atleta, r, sc.sigla, sc.quantidade]);

      // scouts que sumiram da fonte numa nova coleta (correção da API)
      await cliente.query(
        `DELETE FROM scout s
          WHERE s.rodada = $1
            AND (s.atleta_id, s.sigla) NOT IN (SELECT * FROM unnest($2::int[], $3::text[]))`,
        [r, sc.atleta, sc.sigla]);

      totalAtuacoes += at.atleta.length;
      totalScouts += sc.atleta.length;
    }
    resumo.atuacoes = totalAtuacoes;
    resumo.scouts = totalScouts;
    resumo.atuacoes_sem_partida_ignoradas = semPartida;
    resumo.siglas_ignoradas = Object.keys(ignoradas).length
      ? Object.entries(ignoradas).map(([s, n]) => `${s} (${n})`).join(', ')
      : 'nenhuma';

    await cliente.query('COMMIT');
  } catch (erro) {
    await cliente.query('ROLLBACK');
    throw erro;
  } finally {
    await cliente.end();
  }

  console.log('Carga concluída (uma transação só):');
  for (const [item, valor] of Object.entries(resumo)) {
    console.log(`  ${item.padEnd(32, '.')} ${valor}`);
  }
}

main().catch((erro) => {
  console.error('Carga interrompida, nada foi gravado:', erro.message);
  if (erro.detail) console.error('  detalhe:', erro.detail);
  process.exit(1);
});
