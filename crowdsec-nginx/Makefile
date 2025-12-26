BASENAME=$(shell basename `pwd`)
VERSION=1.1.5-alpine3.23.2

all: build

build: Dockerfile
	docker build -t $(BASENAME):$(VERSION) .

.PHONY: build clean