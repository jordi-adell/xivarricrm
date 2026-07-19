build: 
	docker build -t crm .

up:
	docker compose up -d --build

down:
	docker compose down
