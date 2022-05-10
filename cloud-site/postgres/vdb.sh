#! /bin/bash
exec kubectl exec -it $1 -- psql -h localhost -U admin --password -p 5432 volttron
