// Liga FACOM Fantasy - npm run app

const db = require('./db');
const tela = require('./tela');
const tecnico = require('./tecnico');
const admin = require('./admin');

async function escolherTecnico() {
  const tecnicos = await db.consultar(
    'SELECT id, apelido, nome, nome_time, patrimonio FROM tecnico ORDER BY id');
  console.log('\nTécnicos cadastrados:');
  tela.tabela(tecnicos, [
    ['ID', (t) => t.id, 'dir'],
    ['Apelido', (t) => t.apelido],
    ['Nome', (t) => t.nome],
    ['Time', (t) => t.nome_time],
    ['Patrimônio', (t) => tela.cartoleta(t.patrimonio), 'dir'],
  ]);

  const id = await tela.perguntaNumero('ID do técnico');
  const t = await db.umaLinha('SELECT id FROM tecnico WHERE id = $1', [id]);
  if (!t) {
    console.log('  Técnico não encontrado.');
    return;
  }
  await tecnico.menu(t.id);
}

async function cadastrarTecnico() {
  console.log('\nCadastro de técnico');
  const nome = await tela.pergunta('Nome completo: ');
  const email = await tela.pergunta('E-mail: ');
  const apelido = await tela.pergunta('Apelido: ');
  const time = await tela.pergunta('Nome do time: ');

  const r = await tela.executar(null, () => db.umaLinha(
    `INSERT INTO tecnico (nome, email, apelido, nome_time)
     VALUES ($1, $2, $3, $4)
     RETURNING id, apelido, patrimonio`,
    [nome, email, apelido, time]));
  if (r) {
    console.log(`  OK: ${r.apelido} cadastrado com id ${r.id} e patrimônio de ${tela.cartoleta(r.patrimonio)}.`);
  }
}

async function main() {
  try {
    await db.conectar();
  } catch (erro) {
    console.log('Erro ao conectar: ' + await db.mensagemErro(erro));
    process.exit(1);
  }

  while (true) {
    const op = await tela.menu('Liga FACOM Fantasy', [
      ['1', 'Entrar como técnico'],
      ['2', 'Cadastrar técnico'],
      ['3', 'Administrador'],
      ['0', 'Sair'],
    ]);
    if (op === '1') await escolherTecnico();
    else if (op === '2') await cadastrarTecnico();
    else if (op === '3') await admin.menu();
    else if (op === '0') break;
  }

  await db.desconectar();
  console.log('Até mais!');
}

main();
