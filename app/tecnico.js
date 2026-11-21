// Menu do tecnico: mercado, escalacao e ligas.
// As regras (orcamento, esquema, capitao, situacao, rodada) ficam no banco,
// aqui so manda o comando e mostra a resposta.

const db = require('./db');
const tela = require('./tela');
const ligas = require('./ligas');

async function rodadaAberta() {
  const r = await db.umaLinha('SELECT fn_rodada_aberta() AS numero');
  return r.numero;
}

async function menu(tecnicoId) {
  while (true) {
    const t = await db.umaLinha(
      'SELECT id, apelido, nome_time, patrimonio FROM tecnico WHERE id = $1', [tecnicoId]);
    const rodada = await rodadaAberta();
    console.log(`\n${t.apelido} (${t.nome_time}) · patrimônio ${tela.cartoleta(t.patrimonio)} · ` +
                (rodada ? `rodada ${rodada} aberta` : 'nenhuma rodada aberta'));

    const op = await tela.menu('Técnico', [
      ['1', 'Mercado'],
      ['2', 'Minha escalação'],
      ['3', 'Ligas e ranking'],
      ['0', 'Voltar'],
    ]);
    if (op === '1') await mercado(rodada);
    else if (op === '2') await escalacao(t, rodada);
    else if (op === '3') await ligas.menu(t);
    else if (op === '0') return;
  }
}

async function mercado(rodada) {
  console.log('Filtros (Enter para ignorar)');
  const posicao = await tela.perguntaOpcional('Posição (gol, lat, zag, mei, ata, tec): ');
  const clube = await tela.perguntaOpcional('Clube (sigla, ex.: FLA): ');
  const precoTxt = await tela.perguntaOpcional('Preço máximo (ex.: 10,50): ');
  const precoMax = precoTxt ? precoTxt.replace(',', '.') : null;

  const atletas = await tela.executar(null, () => db.consultar(
    `SELECT atleta_id, apelido, posicao, clube, situacao, preco, media, jogos, ultima_pontuacao
       FROM vw_mercado
      WHERE ($1::text IS NULL OR posicao = lower($1))
        AND ($2::text IS NULL OR clube = upper($2))
        AND ($3::numeric IS NULL OR preco <= $3::numeric)
      ORDER BY media DESC NULLS LAST, preco
      LIMIT 30`,
    [posicao, clube, precoMax]));
  if (!atletas) return;

  console.log(`\nMercado${rodada ? ` da rodada ${rodada}` : ' (nenhuma rodada aberta)'} (até 30 atletas, maior média primeiro)`);
  tela.tabela(atletas, [
    ['ID', (a) => a.atleta_id, 'dir'],
    ['Atleta', (a) => a.apelido],
    ['Pos', (a) => a.posicao],
    ['Clube', (a) => a.clube],
    ['Situação', (a) => a.situacao],
    ['Preço', (a) => tela.cartoleta(a.preco), 'dir'],
    ['Média', (a) => tela.numero(a.media), 'dir'],
    ['Jogos', (a) => a.jogos, 'dir'],
    ['Última', (a) => tela.numero(a.ultima_pontuacao), 'dir'],
  ]);
}

async function mostrarEscalacao(tecnicoId, rodada) {
  const e = await db.umaLinha(
    `SELECT e.status, e.capitao_id, s.nome AS esquema
       FROM escalacao e JOIN esquema s ON s.id = e.esquema_id
      WHERE e.tecnico_id = $1 AND e.rodada = $2`, [tecnicoId, rodada]);
  if (!e) {
    console.log(`\n  Você ainda não tem escalação na rodada ${rodada}. Comece escolhendo o esquema.`);
    return null;
  }

  // quantos de cada posicao ja tem x quantos o esquema pede
  const composicao = await db.consultar(
    `SELECT p.abreviacao AS pos,
            fn_qtd_exigida(e.esquema_id, p.id) AS exigida,
            count(a.id) AS escolhidos
       FROM escalacao e
       CROSS JOIN posicao p
       LEFT JOIN escalacao_atleta ea ON ea.tecnico_id = e.tecnico_id AND ea.rodada = e.rodada
       LEFT JOIN atleta a ON a.id = ea.atleta_id AND a.posicao_id = p.id
      WHERE e.tecnico_id = $1 AND e.rodada = $2
      GROUP BY p.id, p.abreviacao, e.esquema_id
      ORDER BY p.id`, [tecnicoId, rodada]);

  const atletas = await db.consultar(
    `SELECT a.id, a.apelido, p.abreviacao AS pos, c.abreviacao AS clube, s.nome AS situacao,
            ea.preco_pago, (e.capitao_id = a.id) AS capitao
       FROM escalacao_atleta ea
       JOIN escalacao e ON e.tecnico_id = ea.tecnico_id AND e.rodada = ea.rodada
       JOIN atleta a    ON a.id = ea.atleta_id
       JOIN posicao p   ON p.id = a.posicao_id
       JOIN situacao s  ON s.id = a.situacao_id
       LEFT JOIN atleta_clube_rodada v ON v.atleta_id = a.id AND v.rodada = ea.rodada
       LEFT JOIN clube c ON c.id = v.clube_id
      WHERE ea.tecnico_id = $1 AND ea.rodada = $2
      ORDER BY p.id, a.apelido`, [tecnicoId, rodada]);

  const custo = atletas.reduce((s, a) => s + Number(a.preco_pago), 0);
  console.log(`\nEscalação da rodada ${rodada} · esquema ${e.esquema} · ` +
              (e.status === 'confirmada' ? 'CONFIRMADA' : 'em edição'));
  console.log('  ' + composicao.map((c) => `${c.pos} ${c.escolhidos}/${c.exigida}`).join(' · '));
  console.log(`  Custo: ${tela.cartoleta(custo)}`);
  tela.tabela(atletas, [
    ['ID', (a) => a.id, 'dir'],
    ['Atleta', (a) => a.apelido],
    ['Pos', (a) => a.pos],
    ['Clube', (a) => a.clube],
    ['Situação', (a) => a.situacao],
    ['Preço pago', (a) => tela.cartoleta(a.preco_pago), 'dir'],
    ['Cap', (a) => (a.capitao ? 'C' : '')],
  ]);
  return e;
}

async function escolherEsquema(tecnicoId, rodada, jaTem) {
  const esquemas = await db.consultar('SELECT id, nome FROM esquema ORDER BY nome');
  console.log('  Esquemas: ' + esquemas.map((s) => `${s.id}=${s.nome}`).join('  '));
  const id = await tela.perguntaNumero('ID do esquema');

  if (jaTem) {
    await tela.executar('Esquema trocado.', () => db.consultar(
      'UPDATE escalacao SET esquema_id = $1 WHERE tecnico_id = $2 AND rodada = $3',
      [id, tecnicoId, rodada]));
  } else {
    await tela.executar('Escalação criada.', () => db.consultar(
      'INSERT INTO escalacao (tecnico_id, rodada, esquema_id) VALUES ($1, $2, $3)',
      [tecnicoId, rodada, id]));
  }
}

// completa as vagas com atletas baratos do mercado (pra agilizar no video).

async function completar(tecnicoId, rodada) {
  const r = await tela.executar(null, () => db.consultar(
    `INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id)
     SELECT $1, $2, x.atleta_id
       FROM (SELECT m.atleta_id, m.posicao_id,
                    row_number() OVER (PARTITION BY m.posicao_id
                                 ORDER BY coalesce(m.media, 0) / m.preco DESC, m.preco) AS n
               FROM vw_mercado m
              WHERE NOT EXISTS (SELECT 1 FROM escalacao_atleta ea
                                 WHERE ea.tecnico_id = $1 AND ea.rodada = $2
                                   AND ea.atleta_id = m.atleta_id)) x
       JOIN escalacao e ON e.tecnico_id = $1 AND e.rodada = $2
      WHERE x.n <= fn_qtd_exigida(e.esquema_id, x.posicao_id)
                   - (SELECT count(*) FROM escalacao_atleta ea
                        JOIN atleta a ON a.id = ea.atleta_id
                       WHERE ea.tecnico_id = $1 AND ea.rodada = $2
                         AND a.posicao_id = x.posicao_id)
     RETURNING atleta_id`,
    [tecnicoId, rodada]));
  if (r) console.log(`  OK: ${r.length} atleta(s) incluído(s).`);
}

async function escalacao(t, rodada) {
 rodada = await tela.perguntaNumero('Rodada da escalação', rodada);
  if (rodada === null) return;

  while (true) {
    const e = await mostrarEscalacao(t.id, rodada);
    const op = await tela.menu('Escalação', [
      ['1', e ? 'Trocar esquema' : 'Escolher esquema (cria a escalação)'],
      ['2', 'Incluir atleta'],
      ['3', 'Remover atleta'],
      ['4', 'Escolher capitão'],
      ['5', 'Completar com sugestões'],
      ['6', 'Confirmar escalação'],
      ['7', 'Descartar escalação'],
      ['0', 'Voltar'],
    ]);

    if (op === '1') {
      await escolherEsquema(t.id, rodada, !!e);
    } else if (op === '2') {
      const atleta = await tela.perguntaNumero('ID do atleta');
      await tela.executar('Atleta incluído.', () => db.consultar(
        'INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES ($1, $2, $3)',
        [t.id, rodada, atleta]));
    } else if (op === '3') {
      const atleta = await tela.perguntaNumero('ID do atleta');
      const r = await tela.executar(null, () => db.consultar(
        'DELETE FROM escalacao_atleta WHERE tecnico_id = $1 AND rodada = $2 AND atleta_id = $3 RETURNING atleta_id',
        [t.id, rodada, atleta]));
      if (r) console.log(r.length ? '  OK: Atleta removido.' : '  Esse atleta não está na sua escalação.');
    } else if (op === '4') {
      const atleta = await tela.perguntaNumero('ID do capitão');
      await tela.executar('Capitão escolhido.', () => db.consultar(
        'UPDATE escalacao SET capitao_id = $1 WHERE tecnico_id = $2 AND rodada = $3',
        [atleta, t.id, rodada]));
    } else if (op === '5') {
      await completar(t.id, rodada);
    } else if (op === '6') {
      await tela.executar(null, () => db.consultar(
        'CALL sp_confirmar_escalacao($1, $2)', [t.id, rodada]));
    } else if (op === '7') {
      await tela.executar('Escalação descartada.', () => db.consultar(
        'DELETE FROM escalacao WHERE tecnico_id = $1 AND rodada = $2', [t.id, rodada]));
    } else if (op === '0') {
      return;
    }
  }
}

module.exports = { menu };
