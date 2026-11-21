// Ligas: criar, entrar e ranking.
// o codigo de convite so o dono ve, pela fn_codigo_convite

const db = require('./db');
const tela = require('./tela');

async function minhasLigas(tecnicoId) {
  const ls = await db.consultar(
    `SELECT l.id, l.nome, l.publica, l.limite_participantes, (l.dono_id = $1) AS dono,
            (SELECT count(*) FROM participacao x WHERE x.liga_id = l.id) AS participantes
       FROM liga l
       JOIN participacao p ON p.liga_id = l.id AND p.tecnico_id = $1
      ORDER BY l.id`, [tecnicoId]);
  console.log('\nSuas ligas:');
  tela.tabela(ls, [
    ['ID', (l) => l.id, 'dir'],
    ['Liga', (l) => l.nome],
    ['Tipo', (l) => (l.publica ? 'pública' : 'privada')],
    ['Vagas', (l) => `${l.participantes}/${l.limite_participantes}`, 'dir'],
    ['', (l) => (l.dono ? 'você é o dono' : '')],
  ]);
}

async function ranking() {
  const ligaId = await tela.perguntaNumero('ID da liga');
  const tipo = await tela.pergunta('1 - acumulado, 2 - por rodada [1]: ');

  if (tipo === '2') {
    const rodada = await tela.perguntaNumero('Rodada');
    const linhas = await tela.executar(null, () => db.consultar(
      `SELECT posicao, tecnico, time, pontuacao
         FROM vw_ranking_rodada
        WHERE liga_id = $1 AND rodada = $2
        ORDER BY posicao, tecnico`, [ligaId, rodada]));
    if (!linhas) return;
    console.log(`\nRanking da rodada ${rodada}`);
    tela.tabela(linhas, [
      ['Pos', (l) => l.posicao + 'º', 'dir'],
      ['Técnico', (l) => l.tecnico],
      ['Time', (l) => l.time],
      ['Pontos', (l) => tela.numero(l.pontuacao), 'dir'],
    ]);
    if (linhas.length === 0) console.log('  (rodada ainda não consolidada ou liga não existe)');
  } else {
    const linhas = await tela.executar(null, () => db.consultar(
      `SELECT posicao, tecnico, time, pontuacao, rodadas_pontuadas
         FROM vw_ranking_liga
        WHERE liga_id = $1
        ORDER BY posicao, tecnico`, [ligaId]));
    if (!linhas) return;
    console.log('\nRanking acumulado');
    tela.tabela(linhas, [
      ['Pos', (l) => l.posicao + 'º', 'dir'],
      ['Técnico', (l) => l.tecnico],
      ['Time', (l) => l.time],
      ['Pontos', (l) => tela.numero(l.pontuacao), 'dir'],
      ['Rodadas', (l) => l.rodadas_pontuadas, 'dir'],
    ]);
  }
}

async function criarLiga(tecnicoId) {
  const nome = await tela.pergunta('Nome da liga: ');
  const descricao = await tela.perguntaOpcional('Descrição (opcional): ');
  const publica = (await tela.pergunta('Pública? (s/n): ')).toLowerCase() !== 'n';
  const limite = await tela.perguntaNumero('Limite de participantes', 20);
  await tela.executar(null, () => db.consultar(
    'CALL sp_criar_liga($1, $2, $3, $4, $5, NULL, NULL)',
    [tecnicoId, nome, descricao, publica, limite]));
}

async function entrarPublica(tecnicoId) {
  const ls = await db.consultar(
    `SELECT l.id, l.nome, l.limite_participantes,
            (SELECT count(*) FROM participacao x WHERE x.liga_id = l.id) AS participantes
       FROM liga l
      WHERE l.publica
      ORDER BY l.id`);
  console.log('\nLigas públicas:');
  tela.tabela(ls, [
    ['ID', (l) => l.id, 'dir'],
    ['Liga', (l) => l.nome],
    ['Vagas', (l) => `${l.participantes}/${l.limite_participantes}`, 'dir'],
  ]);
  const ligaId = await tela.perguntaNumero('ID da liga');
  await tela.executar(null, () => db.consultar(
    'CALL sp_entrar_liga($1::integer, $2::integer, NULL)', [tecnicoId, ligaId]));
}

async function entrarPrivada(tecnicoId) {
  const codigo = await tela.pergunta('Código de convite: ');
  await tela.executar(null, () => db.consultar(
    'CALL sp_entrar_liga($1::integer, NULL, $2::varchar)', [tecnicoId, codigo]));
}

async function verCodigo(tecnicoId) {
  const ligaId = await tela.perguntaNumero('ID da liga');
  const r = await tela.executar(null, () => db.umaLinha(
    'SELECT fn_codigo_convite($1, $2) AS codigo', [ligaId, tecnicoId]));
  if (r) console.log(`  Código de convite: ${r.codigo}`);
}

async function menu(t) {
  while (true) {
    await minhasLigas(t.id);
    const op = await tela.menu('Ligas', [
      ['1', 'Ranking de uma liga'],
      ['2', 'Criar liga'],
      ['3', 'Entrar em liga pública'],
      ['4', 'Entrar em liga privada (com código)'],
      ['5', 'Ver código de convite (só o dono)'],
      ['0', 'Voltar'],
    ]);
    if (op === '1') await ranking();
    else if (op === '2') await criarLiga(t.id);
    else if (op === '3') await entrarPublica(t.id);
    else if (op === '4') await entrarPrivada(t.id);
    else if (op === '5') await verCodigo(t.id);
    else if (op === '0') return;
  }
}

module.exports = { menu };
