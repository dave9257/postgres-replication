CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';
SELECT pg_create_physical_replication_slot('replication_2');
