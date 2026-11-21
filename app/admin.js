// Menu do administrador: abrir rodada, fechar mercado e consolidar.
// quem confere a ordem dos estados sao as procedures do 03

const db = require('./db');
const tela = require('./tela');

async function situacao() {
  const r = await db.umaLinha(
    `SELECT (SELECT numero FROM rodada WHERE estado = 'aberta')           AS aberta,
            (SELECT numero FROM rodada WHERE estado = 'fechada')          AS fechada,
            (SELECT max(numero) FROM rodada WHERE estado = 'consolidada') AS ultima_consolidada,
            (SELECT min(numero) FROM rodada WHERE estado = 'futura')      AS proxima`);

  const partes = [];
  if (r.aberta) partes.push(`rodada ${r.aberta} aberta`);
  if (r.fechada) partes.push(`rodada ${r.fechada} fechada (falta consolidar)`);
  partes.push(r.ultima_consolidada ? `última consolidada: ${r.ultima_consolidada}` : 'nenhuma consolidada');
  if (r.proxima) partes.push(`próxima: ${r.proxima}`);
  console.log('\nRodadas: ' + partes.join(' · '));
  return r;
}

// o que a consolidacao altera, pra comparar antes e depois da falha
async function retrato(rodada) {
  return db.umaLinha(
    `SELECT (SELECT estado FROM rodada WHERE numero = $1)           AS estado,
            (SELECT count(*) FROM historico_preco WHERE rodada = $1) AS historico,
            (SELECT count(*) FROM escalacao
              WHERE rodada = $1 AND pontuacao IS NOT NULL)          AS pontuadas,
            (SELECT sum(preco_atual) FROM atleta)                    AS precos,
            (SELECT sum(patrimonio) FROM tecnico)                    AS patrimonios`, [rodada]);
}

async function resultado(rodada) {
  const linhas = await db.consultar(
    `SELECT t.apelido, t.nome_time, e.pontuacao, c.apelido AS capitao,
            e.variacao_patrimonio, t.patrimonio
       FROM escalacao e
       JOIN tecnico t ON t.id = e.tecnico_id
       LEFT JOIN atleta c ON c.id = e.capitao_id
      WHERE e.rodada = $1 AND e.status = 'confirmada'
      ORDER BY e.pontuacao DESC NULLS LAST, e.confirmada_em`, [rodada]);
  console.log(`\nResultado da rodada ${rodada}`);
  tela.tabela(linhas, [
    ['Técnico', (l) => l.apelido],
    ['Time', (l) => l.nome_time],
    ['Pontos', (l) => tela.numero(l.pontuacao), 'dir'],
    ['Capitão', (l) => l.capitao],
    ['Valorização', (l) => tela.cartoleta(l.variacao_patrimonio), 'dir'],
    ['Patrimônio', (l) => tela.cartoleta(l.patrimonio), 'dir'],
  ]);
}

async function consolidar(padrao, simularFalha) {
  const rodada = await tela.perguntaNumero('Rodada para consolidar', padrao);

  if (!simularFalha) {
    const ok = await tela.executar(null, () => db.consultar(
      'CALL sp_consolidar_rodada($1, false)', [rodada]));
    if (ok) await resultado(rodada);
    return;
  }

  const antes = await retrato(rodada);
  await tela.executar(null, () => db.consultar('CALL sp_consolidar_rodada($1, true)', [rodada]));
  const depois = await retrato(rodada);

  console.log(`\nAntes e depois da tentativa (rodada ${rodada}):`);
  tela.tabela([
    ['estado da rodada', antes.estado, depois.estado],
    ['linhas no histórico de preços', antes.historico, depois.historico],
    ['escalações com pontuação', antes.pontuadas, depois.pontuadas],
    ['soma dos preços dos atletas', tela.cartoleta(antes.precos), tela.cartoleta(depois.precos)],
    ['soma dos patrimônios', tela.cartoleta(antes.patrimonios), tela.cartoleta(depois.patrimonios)],
  ], [
    ['', (l) => l[0]],
    ['Antes', (l) => l[1], 'dir'],
    ['Depois', (l) => l[2], 'dir'],
  ]);
}

async function menu() {
  while (true) {
    const s = await situacao();
    const op = await tela.menu('Administrador', [
      ['1', 'Abrir rodada'],
      ['2', 'Fechar mercado'],
      ['3', 'Consolidar rodada'],
      ['4', 'Consolidar com falha simulada'],
      ['5', 'Ver resultado de uma rodada'],
      ['0', 'Voltar'],
    ]);

    if (op === '1') {
      const rodada = await tela.perguntaNumero('Rodada para abrir', s.proxima);
      await tela.executar(null, () => db.consultar('CALL sp_abrir_rodada($1)', [rodada]));
    } else if (op === '2') {
      const rodada = await tela.perguntaNumero('Rodada para fechar', s.aberta);
      await tela.executar(null, () => db.consultar('CALL sp_fechar_mercado($1)', [rodada]));
    } else if (op === '3') {
      await consolidar(s.fechada, false);
    } else if (op === '4') {
      await consolidar(s.fechada, true);
    } else if (op === '5') {
      const rodada = await tela.perguntaNumero('Rodada', s.ultima_consolidada);
      await resultado(rodada);
    } else if (op === '0') {
      return;
    }
  }
}

module.exports = { menu };
