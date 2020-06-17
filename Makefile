
-include Makefile.env

SHELL := /bin/bash
.DEFAULT_GOAL := all

.PHONY: all
## all: (default) runs build-image
all: build-image

AWS_PROFILE?=
ROOT_PATH=$(PWD)
APP_DIR=$(ROOT_PATH)/src
TEMP_DIR=$(ROOT_PATH)/temp

.PHONY: build-image
## build-image: builds the docker image
build-image:
	docker build -t $(APP_NAME):$(GIT_COMMIT) $(APP_DIR)
	docker tag $(APP_NAME):$(GIT_COMMIT) $(AWS_ACCOUNT_NUMBER).dkr.ecr.$(REGION).amazonaws.com/$(REPO_NAME):$(GIT_COMMIT)

.PHONY: push-image
push-image:
	@docker push $(AWS_ACCOUNT_NUMBER).dkr.ecr.$(REGION).amazonaws.com/$(REPO_NAME):$(GIT_COMMIT)

.PHONY: configured-region
configured-region:
	@echo $(REGION)

.PHONY: latest_image
latest_image:
	@echo $(AWS_ACCOUNT_NUMBER).dkr.ecr.$(REGION).amazonaws.com/$(REPO_NAME):$(GIT_COMMIT)
