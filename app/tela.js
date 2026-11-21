// Entrada e saida no terminal. So exibicao, nenhuma regra do jogo aqui.

const readline = require('readline');
const db = require('./db');

// fila de linhas digitadas (funciona tambem com entrada redirecionada)
const rl = readline.createInterface({ input: process.stdin });
const linhas = [];
let esperando = null;
let fechou = false;

rl.on('line', (linha) => {
  if (esperando) {
    const r = esperando;
    esperando = null;
    r(linha);
  } else {
    linhas.push(linha);
  }
});
rl.on('close', () => {
  fechou = true;
  if (esperando) esperando(null);
});

async function pergunta(texto) {
  process.stdout.write(texto);
  let resp;
  if (linhas.length > 0) resp = linhas.shift();
  else if (fechou) resp = null;
  else resp = await new Promise((r) => { esperando = r; });
  if (resp === null) {
    console.log('\nAté mais!');
    await db.desconectar();
    process.exit(0);
  }
  if (!process.stdin.isTTY) console.log(resp); // mostra o que foi lido de arquivo
  return resp.trim();
}

// devolve null se a pessoa so apertar Enter
async function perguntaOpcional(texto) {
  const r = await pergunta(texto);
  return r === '' ? null : r;
}

async function perguntaNumero(texto, padrao = null) {
  const r = await pergunta(padrao !== null ? `${texto} [${padrao}]: ` : `${texto}: `);
  if (r === '' && padrao !== null) return padrao;
  const n = Number(r);
  return Number.isInteger(n) ? n : null;
}

async function menu(titulo, opcoes) {
  console.log(`\n== ${titulo} ==`);
  for (const [tecla, texto] of opcoes) console.log(`  ${tecla} - ${texto}`);
  return pergunta('Escolha: ');
}

function cartoleta(v) {
  if (v === null || v === undefined) return '-';
  return 'C$ ' + Number(v).toFixed(2).replace('.', ',');
}

function numero(v) {
  if (v === null || v === undefined) return '-';
  return Number(v).toFixed(2).replace('.', ',');
}

// colunas: [[titulo, funcao que pega o valor da linha, 'dir' para alinhar a direita]]
function tabela(linhasTabela, colunas) {
  if (linhasTabela.length === 0) {
    console.log('  (nada para mostrar)');
    return;
  }
  const textos = linhasTabela.map((l) => colunas.map(([, f]) => String(f(l) ?? '-')));
  const larg = colunas.map(([t], i) => Math.max(t.length, ...textos.map((l) => l[i].length)));
  const alinhar = (s, i) => (colunas[i][2] === 'dir' ? s.padStart(larg[i]) : s.padEnd(larg[i]));
  console.log('  ' + colunas.map(([t], i) => alinhar(t, i)).join('  '));
  console.log('  ' + larg.map((n) => '-'.repeat(n)).join('  '));
  for (const l of textos) console.log('  ' + l.map(alinhar).join('  '));
}

// Executa uma operacao no banco e mostra o resultado.
// Se o banco recusar, mostra a mensagem dele e devolve null.
async function executar(msgOk, operacao) {
  try {
    const r = await operacao();
    for (const a of db.pegarAvisos()) console.log('  > ' + a);
    if (msgOk) console.log('  OK: ' + msgOk);
    return r === undefined ? true : r;
  } catch (erro) {
    for (const a of db.pegarAvisos()) console.log('  > ' + a);
    console.log('  RECUSADO: ' + await db.mensagemErro(erro));
    return null;
  }
}

module.exports = { pergunta, perguntaOpcional, perguntaNumero, menu, cartoleta, numero, tabela, executar };
