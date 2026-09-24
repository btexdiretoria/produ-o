# Esquema restrito do novo Supabase de Produção

Em 24/09/2026, `production_schema.sql` foi aplicado ao novo projeto Supabase
de Produção como uma única migração de nome
`btex_production_restricted_baseline`. Em seguida, `production_storage.sql`
criou o bucket privado `product-files`.

O esquema reproduz a estrutura final das migrações históricas em
`../migrations/`, com 21 tabelas e RLS ativo. As permissões antigas para
`anon` e `authenticated` foram excluídas: somente o servidor com `service_role`
tem acesso às tabelas. As rotinas de produção passaram a executar com
`SECURITY INVOKER`. A limpeza pontual de registros de 20/08/2026 foi omitida,
pois o projeto novo não continha esses registros.

O projeto foi criado vazio: há apenas os dados de configuração (cinco setores,
sete dias de horário e a configuração geral). **Nenhum dado do banco antigo
foi migrado.** O código e a prévia do sistema B ainda usam o projeto
anterior; não troque suas variáveis de ambiente até revisar a
migração dos dados e testar todas as operações.

A tabela `marcadores` começa vazia na linha de base. O fluxo do aplicativo
exige que a primeira conta seja administradora. Gerencie credenciais apenas
no banco e no aplicativo; não registre dados de acesso no repositório.

O Supabase registra a estrutura nova como **uma** migração. As 32 migrações
históricas não devem ser reaplicadas nesse projeto. Antes de usar `supabase db
push` nele, concilie o histórico de migrações do repositório com esta linha
de base.
