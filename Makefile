DSN ?= postgresql://postgres:postgres@localhost:5432/postgres
PSQL = psql "$(DSN)" -v ON_ERROR_STOP=1

.PHONY: up schema load test q1 q2 q3 q4 q5 dq all

up:        ## start PostgreSQL in Docker
	docker compose up -d

schema:    ## (re)create schema, views and the materialised view
	for f in sql/0*.sql; do $(PSQL) -q -f $$f; done

load:      ## download SEC data and load it (needs SEC_USER_AGENT)
	DATABASE_URL="$(DSN)" python etl/load_sec.py --save-dir cache

test:      ## run the test-suite (needs TEST_DSN, see README)
	python -m pytest tests -q

q1 q2 q3 q4 q5:
	$(PSQL) -f sql/queries/0$(subst q,,$@)_*.sql

dq:        ## show data-quality problems
	$(PSQL) -c "SELECT * FROM fw.v_data_quality ORDER BY 1,2"

all: up schema load
