// =====================================================================
// Liga FACOM Fantasy - COLETA dos dados da API do Cartola
// ---------------------------------------------------------------------
// Baixa as respostas da API pública do Cartola e salva cada uma como
// arquivo .json em carga/dados/. A carga no banco (carregar.js) lê só
// esses arquivos, como pede a seção 4.3 do enunciado: se a API mudar ou
// sair do ar, o trabalho continua reproduzível.
//
// Uso:
//   node carga/coletar.js              baixa só o que ainda não existe
//   node carga/coletar.js --forcar     baixa tudo de novo
//
// Cuidados da seção 4.3 que este programa segue:
//   - envia um User-Agent de navegador (alguns servidores recusam sem);
//   - faz no máximo uma requisição por segundo (pausa entre as chamadas);
//   - tenta de novo, com espera crescente, se a requisição falhar.
// =====================================================================

const fs = require('fs');
const path = require('path');

const API = 'https://api.cartola.globo.com';
const PASTA_DADOS = path.join(__dirname, 'dados');
const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/130.0 Safari/537.36';
const PAUSA_MS = 1100;          // um pouco mais de 1 s entre requisições
const TENTATIVAS = 3;
const TOTAL_RODADAS = 38;

const forcar = process.argv.includes('--forcar');

const dormir = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Faz o GET com User-Agent e devolve o JSON já convertido em objeto.
async function buscarJson(endpoint) {
  for (let tentativa = 1; tentativa <= TENTATIVAS; tentativa++) {
    try {
      const resposta = await fetch(API + endpoint, {
        headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' },
      });
      if (!resposta.ok) {
        throw new Error(`HTTP ${resposta.status}`);
      }
      return await resposta.json();
    } catch (erro) {
      console.warn(`  falha em ${endpoint} (tentativa ${tentativa}): ${erro.message}`);
      if (tentativa === TENTATIVAS) throw erro;
      await dormir(PAUSA_MS * tentativa * 2); // espera crescente
    }
  }
}

// Salva o objeto como JSON legível (indentado), para facilitar a leitura
// e o histórico no Git.
function salvar(nomeArquivo, dados) {
  fs.writeFileSync(path.join(PASTA_DADOS, nomeArquivo), JSON.stringify(dados, null, 2), 'utf8');
}

// Baixa um endpoint, a menos que o arquivo já exista (e não haja --forcar).
// Devolve true quando fez requisição, para o laço saber se precisa pausar.
async function coletar(endpoint, nomeArquivo) {
  const destino = path.join(PASTA_DADOS, nomeArquivo);
  if (!forcar && fs.existsSync(destino)) {
    console.log(`  ${nomeArquivo} já existe, mantido`);
    return false;
  }
  const dados = await buscarJson(endpoint);
  salvar(nomeArquivo, dados);
  console.log(`  ${endpoint} -> ${nomeArquivo}`);
  return true;
}

async function main() {
  fs.mkdirSync(PASTA_DADOS, { recursive: true });
  console.log(`Coletando da API do Cartola em ${PASTA_DADOS}`);

  // O status do mercado é sempre baixado de novo: é ele que diz qual é a
  // rodada atual e, portanto, quais rodadas já foram jogadas.
  const status = await buscarJson('/mercado/status');
  salvar('mercado_status.json', status);
  console.log(`  /mercado/status -> rodada atual ${status.rodada_atual}, ` +
              `status do mercado ${status.status_mercado}`);
  await dormir(PAUSA_MS);

  // Rodadas já jogadas: todas antes da rodada atual. A rodada atual ainda
  // não terminou (mercado aberto) ou está em andamento (mercado fechado).
  const ultimaJogada = status.rodada_atual - 1;

  const tarefas = [
    ['/atletas/mercado', 'atletas_mercado.json'],
    ['/esquemas', 'esquemas.json'],
  ];
  // Partidas das 38 rodadas: as futuras vêm sem placar, mas servem para
  // cadastrar a tabela do campeonato inteiro.
  for (let r = 1; r <= TOTAL_RODADAS; r++) {
    tarefas.push([`/partidas/${r}`, `partidas_${String(r).padStart(2, '0')}.json`]);
  }
  // Scouts só existem para rodadas já jogadas.
  for (let r = 1; r <= ultimaJogada; r++) {
    tarefas.push([`/atletas/pontuados/${r}`, `pontuados_${String(r).padStart(2, '0')}.json`]);
  }

  for (const [endpoint, arquivo] of tarefas) {
    const fezRequisicao = await coletar(endpoint, arquivo);
    if (fezRequisicao) await dormir(PAUSA_MS); // no máximo 1 requisição/s
  }

  salvar('coleta.json', {
    coletado_em: new Date().toISOString(),
    rodada_atual: status.rodada_atual,
    rodadas_com_scouts: ultimaJogada,
  });
  console.log(`Coleta concluída: partidas de 1 a ${TOTAL_RODADAS}, scouts de 1 a ${ultimaJogada}.`);
}

main().catch((erro) => {
  console.error('Coleta interrompida:', erro.message);
  process.exit(1);
});
