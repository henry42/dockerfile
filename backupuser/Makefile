BASENAME=$(shell basename `pwd`)
VERSION=3.23.2

all: build

build: Dockerfile
	docker build -t $(BASENAME):$(VERSION) .

.PHONY: build clean