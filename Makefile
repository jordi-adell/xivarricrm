build: 
	docker build -t crm .

up:
	mkdir -p data/db data/app data/caddy
	docker compose up -d --build

down:
	docker compose down
