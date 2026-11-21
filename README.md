# Instalador — Rotina de Vacuum/Analyze PostgreSQL MigraTI

Este repositório só distribui o instalador e o pacote **cifrado** da rotina.
O pacote muda todo dia às 00:00 UTC (21:00 em Brasília) e só abre com a chave do dia,
que a equipe MigraTI consulta no repositório privado da rotina.

```bash
curl -fsSLO https://raw.githubusercontent.com/MigraTI/vacuum-postgres-instalador/main/install.sh && sudo bash install.sh
```

## Origem

| | |
|---|---|
| Código-fonte (privado) | [MigraTI/Postgres---Vacuum-Analye](https://github.com/MigraTI/Postgres---Vacuum-Analye) |
| Publicado por | workflow `rotate-dist-key.yml` do repositório privado |
| Chave do dia | Variable `DIST_KEY_TODAY` do repositório privado |

Arquivos atualizados automaticamente pelo GitHub Actions. Não edite aqui: alterações vão no
repositório privado e são publicadas no próximo ciclo.

Última publicação: 21/11/2026, a partir de `MigraTI/Postgres---Vacuum-Analye@8f38a6f`.
