docker exec -it postgres17 pg_dumpall -U postgres > export/dump.sql
docker exec -i postgres18 psql -U postgres < export/dump.sql
