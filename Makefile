build: 
	docker build -t crm .

up:
	mkdir -p data/db data/app
	docker compose up -d --build

down:
	docker compose down
