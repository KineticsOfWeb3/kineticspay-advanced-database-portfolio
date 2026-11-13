-- Runs once on first start of the primary container.
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'replication_password';
SELECT pg_create_physical_replication_slot('standby_abuja');
