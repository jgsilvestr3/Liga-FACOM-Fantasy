// =====================================================================
// Liga FACOM Fantasy - simulador de rodadas (ferramenta de teste)
// ---------------------------------------------------------------------
// Joga N rodadas seguidas com todos os técnicos cadastrados, usando os
// MESMOS caminhos da aplicação (usuário liga_app, INSERT nas tabelas de
// escalação, CALL nos procedimentos). Serve para:
//   - encher o banco com escalações reais e ver as consultas do 04
//     funcionando com várias rodadas consolidadas;
//   - testar as regras em volume (o banco recusa o que for inválido e o
//     simulador simplesmente tenta outro atleta).
//
// Uso:  node testes/simular-rodadas.js [quantidade de rodadas]   (padrão 5)
// As escolhas são aleatórias, mas com semente fixa: a mesma base gera
// sempre o mesmo resultado.
// =====================================================================

const { Client } = require('pg');

const cliente = new Client({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'liga_fantasy',
  user: process.env.PGUSER || 'liga_app',
  password: process.env.PGPASSWORD || 'liga_app_2026',
  options: '-c search_path=fantasy,public',
});

// gerador pseudoaleatório com semente (mulberry32)
let semente = 2026;
function aleatorio() {
  semente |= 0; semente = (semente + 0x6d2b79f5) | 0;
  let t = Math.imul(semente ^ (semente >>> 15), 1 | semente);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const sortear = (lista) => lista[Math.floor(aleatorio() * lista.length)];

const q = async (sql, parametros = []) => (await cliente.query(sql, parametros)).rows;

async function tentar(sql, parametros) {
  try {
    await cliente.query(sql, parametros);
    return null;
  } catch (erro) {
    return erro.message;
  }
}

async function escalar(tecnico, rodada, esquemas) {
  const esquema = sortear(esquemas);
  const erroCriacao = await tentar(
    'INSERT INTO escalacao (tecnico_id, rodada, esquema_id) VALUES ($1, $2, $3)', [tecnico.id, rodada, esquema.id]);
  if (erroCriacao) return `não criou: ${erroCriacao}`;

  // candidatos por posição: os melhores pela média (ou preço, se ainda não
  // há média), com um pouco de sorte misturada
  const mercado = await q(
    `SELECT atleta_id, posicao, preco::float AS preco, coalesce(media, 0)::float AS media
       FROM vw_mercado`);
  const vagas = { gol: esquema.qtd_gol, lat: esquema.qtd_lat, zag: esquema.qtd_zag,
                  mei: esquema.qtd_mei, ata: esquema.qtd_ata, tec: esquema.qtd_tec };
  const [{ patrimonio }] = await q('SELECT patrimonio::float AS patrimonio FROM tecnico WHERE id = $1', [tecnico.id]);

  // O simulador planeja o orçamento só para não desperdiçar tentativas:
  // reserva, para as vagas ainda vazias, o preço dos atletas mais baratos
  // ainda disponíveis em cada posição. Quem GARANTE a regra continua sendo
  // o banco (gatilho 6c).
  const slots = [];
  for (const [posicao, n] of Object.entries(vagas)) for (let i = 0; i < n; i++) slots.push(posicao);
  slots.sort(() => aleatorio() - 0.5);  // ordem aleatória das vagas

  const escolhidos = [];
  const reservaPara = (restantes) => {
    let soma = 0;
    const porPosicao = {};
    for (const p of restantes) porPosicao[p] = (porPosicao[p] || 0) + 1;
    for (const [p, n] of Object.entries(porPosicao)) {
      const precos = mercado.filter((a) => a.posicao === p && !escolhidos.includes(a))
        .map((a) => a.preco).sort((x, y) => x - y).slice(0, n);
      soma += precos.reduce((s, v) => s + v, 0);
    }
    return soma;
  };
  let gasto = 0;
  let recusas = 0;
  for (let i = 0; i < slots.length; i++) {
    const posicao = slots[i];
    // a reserva desconta o próprio candidato: cada um é testado com o
    // teto calculado sem ele
    const restantes = slots.slice(i + 1);
    const teto = patrimonio - gasto - reservaPara(restantes) - 0.05;
    const candidatos = mercado
      .filter((a) => a.posicao === posicao && a.preco <= teto && !escolhidos.includes(a))
      .map((a) => ({ atleta: a, nota: a.media + a.preco * 0.4 + aleatorio() * 5 }))
      .sort((a, b) => b.nota - a.nota)
      .slice(0, 8);
    for (const { atleta } of candidatos) {
      const erro = await tentar(
        'INSERT INTO escalacao_atleta (tecnico_id, rodada, atleta_id) VALUES ($1, $2, $3)',
        [tecnico.id, rodada, atleta.atleta_id]);
      if (erro) { recusas++; continue; }
      escolhidos.push(atleta);
      gasto += atleta.preco;
      break;
    }
  }

  const capitao = escolhidos.filter((a) => a.posicao !== 'tec').sort((a, b) => b.media - a.media)[0];
  if (capitao) {
    await tentar('UPDATE escalacao SET capitao_id = $3 WHERE tecnico_id = $1 AND rodada = $2',
      [tecnico.id, rodada, capitao.atleta_id]);
  }
  // de vez em quando alguém esquece de confirmar (não pontua)
  if (aleatorio() < 0.1) return `deixou em edição (${escolhidos.length} atletas, ${recusas} recusas do banco)`;
  const erroConfirmacao = await tentar('CALL sp_confirmar_escalacao($1, $2)', [tecnico.id, rodada]);
  return erroConfirmacao
    ? `não confirmou: ${erroConfirmacao}`
    : `confirmada (${esquema.nome}, ${recusas} recusas do banco no caminho)`;
}

async function main() {
  const quantidade = Number(process.argv[2] || 5);
  await cliente.connect();
  const esquemas = await q('SELECT * FROM esquema ORDER BY id');
  const tecnicos = await q('SELECT id, apelido FROM tecnico ORDER BY id');

  for (let i = 0; i < quantidade; i++) {
    const [{ proxima }] = await q(
      `SELECT min(numero) AS proxima FROM rodada
        WHERE estado = 'futura'
          AND numero > coalesce((SELECT max(numero) FROM rodada WHERE estado = 'consolidada'), 0)
          AND EXISTS (SELECT 1 FROM atuacao a WHERE a.rodada = rodada.numero)`);
    if (!proxima) {
      console.log('Não há mais rodadas com scouts para simular.');
      break;
    }
    console.log(`\n=== Rodada ${proxima} ===`);
    await cliente.query('CALL sp_abrir_rodada($1)', [proxima]);
    for (const tecnico of tecnicos) {
      if (aleatorio() < 0.08) { console.log(`  ${tecnico.apelido.padEnd(10)} não escalou`); continue; }
      console.log(`  ${tecnico.apelido.padEnd(10)} ${await escalar(tecnico, proxima, esquemas)}`);
    }
    await cliente.query('CALL sp_fechar_mercado($1)', [proxima]);
    await cliente.query('CALL sp_consolidar_rodada($1)', [proxima]);
    const top = await q(
      `SELECT t.apelido, e.pontuacao, e.variacao_patrimonio, t.patrimonio
         FROM escalacao e JOIN tecnico t ON t.id = e.tecnico_id
        WHERE e.rodada = $1 AND e.pontuacao IS NOT NULL
        ORDER BY e.pontuacao DESC, e.confirmada_em LIMIT 3`, [proxima]);
    console.log('  top 3: ' + top.map((x) => `${x.apelido} ${x.pontuacao} pts (patrimônio ${x.patrimonio})`).join(' | '));
  }
  await cliente.end();
}

main().catch(async (erro) => {
  console.error('Simulação interrompida:', erro.message);
  try { await cliente.end(); } catch (_) { /* nada */ }
  process.exit(1);
});
