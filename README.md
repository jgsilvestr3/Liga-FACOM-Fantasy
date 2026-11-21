# Liga FACOM Fantasy

Trabalho prático de Laboratório de Banco de Dados (FACOM/UFMS, 2026/2).
Banco de dados e aplicação de terminal de uma liga de fantasy no estilo do Cartola FC, com dados reais do Brasileirão 2026.

## Integrantes

| Nome | RGA |
|---|---|
| Bruno Rodrigues |202519070487 |
| João Gabriel | |
| Pedro Affonso Medalha | |

## Vídeo

Link: 

## Estrutura

```
docs/     diagrama ER (der.png, der.drawio), mapeamento.md, decisoes.md e regras fora do ER
sql/      scripts do banco, rodar na ordem abaixo
carga/    coletar.js (API -> json), carregar.js (json -> banco) e dados/ com os json coletados
app/      aplicação de terminal
```

## Requisitos

- Docker (ou PostgreSQL 16 ou superior instalado)
- Node.js 18 ou superior

## 1. Subir o banco

```
docker run -d --name liga-postgres -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=liga_fantasy -p 5432:5432 postgres:16
```

Se já tiver outro PostgreSQL usando a porta 5432 na máquina, troque para `-p 5433:5432` e use `PGPORT=5433` nos passos 3 e 4 (no PowerShell: `$env:PGPORT = "5433"`).

## 2. Rodar os scripts SQL

A ordem é obrigatória:

1. `01-ddl.sql` cria o esquema `fantasy` e as tabelas (apaga e recria se já existir)
2. `02-dados.sql` tipos de scout, técnicos, ligas e participações
3. `03-programacao.sql` funções, gatilhos e procedimentos
4. `04-consultas.sql` visões e consultas
5. `05-seguranca-indices.sql` usuários `liga_app` e `liga_carga` e índices

Copiando a pasta para o container e rodando com o psql de lá:

```
docker cp sql liga-postgres:/
docker exec liga-postgres psql -U postgres -d liga_fantasy -v ON_ERROR_STOP=1 -f /sql/01-ddl.sql
docker exec liga-postgres psql -U postgres -d liga_fantasy -v ON_ERROR_STOP=1 -f /sql/02-dados.sql
docker exec liga-postgres psql -U postgres -d liga_fantasy -v ON_ERROR_STOP=1 -f /sql/03-programacao.sql
docker exec liga-postgres psql -U postgres -d liga_fantasy -v ON_ERROR_STOP=1 -f /sql/04-consultas.sql
docker exec liga-postgres psql -U postgres -d liga_fantasy -v ON_ERROR_STOP=1 -f /sql/05-seguranca-indices.sql
```

Com o psql instalado na máquina dá para rodar direto: `psql -h localhost -U postgres -d liga_fantasy -f sql/01-ddl.sql` e assim por diante.

## 3. Carga dos dados da API

Instalar a dependência (biblioteca `pg`) uma vez, na raiz do projeto:

```
npm install
```

Carregar os dados no banco (depois do 05, que cria o usuário `liga_carga`):

```
npm run carga
```

A carga lê os arquivos de `carga/dados/`, que já estão no repositório (rodadas 1 a 35, coletadas em 21/11/2026). Ela pode ser rodada mais de uma vez sem duplicar nada e roda numa transação só: se der erro, nada fica gravado.

Por padrão ela conecta em `localhost:5432`, banco `liga_fantasy`, usuário `liga_carga`. Para mudar, use as variáveis `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` e `PGPASSWORD`. No PowerShell, por exemplo:

```
$env:PGPORT = "5433"; npm run carga
```

Para coletar os dados de novo da API do Cartola (não é preciso para rodar o trabalho):

```
npm run coleta                    # baixa só o que ainda não existe
node carga/coletar.js --forcar    # baixa tudo de novo
```

## 4. Aplicação

```
npm run app
```

A aplicação conecta com o usuário `liga_app` (criado no 05) e usa as mesmas variáveis `PG*` da carga. Se o banco estiver na porta 5433:

```
$env:PGPORT = "5433"; npm run app
```

Menu principal:

- **Entrar como técnico**: escolhe o técnico pelo ID (sem senha). Dentro dele: mercado com filtros por posição, clube e preço máximo; montar a escalação (esquema, incluir e remover atletas, capitão, confirmar); ligas (criar, entrar em pública ou privada com código, ranking acumulado e por rodada).
- **Cadastrar técnico**
- **Administrador**: abrir rodada, fechar mercado, consolidar, e consolidar com falha simulada (mostra que nada muda).

Para trocar de técnico ou ir para o administrador, use `0` para voltar ao menu principal.

As regras ficam no banco: a aplicação só envia o pedido e mostra a mensagem de erro do banco quando ele recusa (orçamento, esquema, capitão, situação do atleta, estado da rodada).

## Rodada completa

As rodadas começam no estado `futura`. Pela aplicação:

1. Administrador → abrir rodada (o mercado abre)
2. Cada técnico → minha escalação → escolher esquema, incluir atletas (ou "completar com sugestões"), escolher capitão e confirmar
3. Administrador → fechar mercado
4. Administrador → consolidar rodada (calcula pontuações, preços, patrimônio e ranking)

Para voltar ao banco vazio, rode de novo os scripts 01 a 05 e a carga.
