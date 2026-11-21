// Conexao com o banco. A aplicacao usa o usuario liga_app (criado no 05).
// Todas as consultas sao parametrizadas ($1, $2...).

const { Client } = require('pg');

const config = {
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'liga_fantasy',
  user: process.env.PGUSER || 'liga_app',
  password: process.env.PGPASSWORD || 'liga_app_2026',
  options: '-c search_path=fantasy,public',
};

let cliente = null;
let avisos = [];

async function conectar() {
  cliente = new Client(config);
  // RAISE NOTICE das procedures (ex.: "Liga criada. Codigo de convite: ...")
  cliente.on('notice', (n) => avisos.push(n.message));
  await cliente.connect();
}

async function desconectar() {
  if (cliente) await cliente.end();
}

async function consultar(sql, params = []) {
  const r = await cliente.query(sql, params);
  return r.rows;
}

async function umaLinha(sql, params = []) {
  const linhas = await consultar(sql, params);
  return linhas[0] || null;
}

function pegarAvisos() {
  const a = avisos;
  avisos = [];
  return a;
}

// Transforma o erro do banco numa mensagem para o tecnico.
// RAISE EXCEPTION ja vem em portugues. Para CHECK/UNIQUE/FK a mensagem
// fica no COMMENT da restricao (fn_mensagem_restricao, do 03).
async function mensagemErro(erro) {
  if (erro.code === 'P0001') {
    return erro.message + (erro.hint ? ` (${erro.hint})` : '');
  }
  if (erro.code && erro.code.startsWith('23') && erro.constraint) {
    try {
      const r = await umaLinha('SELECT fn_mensagem_restricao($1, $2) AS msg',
                               [erro.table || '', erro.constraint]);
      if (r && r.msg) return r.msg;
    } catch (_) {
      // sem mensagem amigavel, usa a original
    }
  }
  if (erro.code === '42501') return 'Sem permissão: ' + erro.message;
  if (erro.code === '22P02' || erro.code === '22003') return 'Valor inválido: ' + erro.message;
  if (erro.code === 'ECONNREFUSED') {
    return 'Não foi possível conectar no PostgreSQL. Confira se o banco está no ar e as variáveis PGHOST/PGPORT.';
  }
  return erro.message;
}

module.exports = { conectar, desconectar, consultar, umaLinha, pegarAvisos, mensagemErro };
