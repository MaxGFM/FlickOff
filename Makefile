# Credentials come from .env (copy .env.example). No password default here.
-include .env
PGUSER ?= gameapp
PGDATABASE ?= aim
DB_URL ?= postgres://$(PGUSER):$(PGPASSWORD)@localhost:5432/$(PGDATABASE)?sslmode=disable
MIGRATIONS_DIR = server/migrations
CONTAINER = aim-db

.PHONY: check-env up down version kill redo

# Stops DB targets with a clear message instead of a failed login.
check-env:
ifeq ($(wildcard .env),)
	@echo "error: .env not found. Copy .env.example to .env and set PGPASSWORD." >&2; exit 1
endif
ifeq ($(strip $(PGPASSWORD)),)
	@echo "error: PGPASSWORD is not set in .env." >&2; exit 1
endif

up: check-env
	@migrate -path $(MIGRATIONS_DIR) -database "$(DB_URL)" up

down: check-env
	@migrate -path $(MIGRATIONS_DIR) -database "$(DB_URL)" down 1

version: check-env
	@migrate -path $(MIGRATIONS_DIR) -database "$(DB_URL)" version

kill:
	docker rm -f $(CONTAINER) 2>/dev/null || true
	docker volume rm $(CONTAINER)-data 2>/dev/null || true

redo: check-env
	# run ./dev.sh first then interrupt it
	make up
	make version
