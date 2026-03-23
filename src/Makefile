all: build

build: Makefile Dockerfile
	docker build --progress=plain -t emulator/docker-nginx-lego:local .

run:
	docker run -it --rm \
	-e CERTBOT_EMAIL=user@example.com \
	-e DEBUG=1 \
	emulator/docker-nginx-lego:local

build-alpine: Makefile Dockerfile
	docker build --progress=plain -t emulator/docker-nginx-lego:local-alpine -f ./Dockerfile-alpine .

run-alpine:
	docker run -it --rm \
	-e CERTBOT_EMAIL=user@example.com \
	-e DEBUG=1 \
	emulator/docker-nginx-lego:local-alpine

# These commands are primarily used for development, see link for more info:
# https://github.com/JonasAlfredsson/docker-nginx-certbot/issues/28
dev:
	docker buildx build --platform linux/amd64,linux/386,linux/arm64,linux/arm/v7 --tag emulator/docker-nginx-lego:dev -f ./Dockerfile ./

dev-alpine:
	docker buildx build --platform linux/amd64,linux/arm64 --tag emulator/docker-nginx-lego:dev-alpine -f ./Dockerfile-alpine ./

push:
	docker buildx build --platform linux/amd64,linux/386,linux/arm64,linux/arm/v7 --tag emulator/docker-nginx-lego:latest --pull --no-cache --push .
	docker buildx build --platform linux/amd64,linux/arm64 --tag emulator/docker-nginx-lego:latest-alpine --pull --no-cache --push -f ./Dockerfile-alpine .
