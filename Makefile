.PHONY: all clean build packer upload

VERSION = $(shell git describe --tags --candidates=1)
SHELL = /bin/bash -o pipefail

PACKER_VERSION ?= 1.6.2
PACKER_LINUX_FILES = $(exec find packer/linux)
PACKER_WINDOWS_FILES = $(exec find packer/windows)

AWS_REGION ?= us-east-1

ARM64_INSTANCE_TYPE = m6g.xlarge
AMD64_INSTANCE_TYPE = c5.xlarge

all: packer build

# Remove any built cloudformation templates and packer output
clean:
	-rm -rf build/*
	-rm packer*.output

# Check for specific environment variables
env-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

# -----------------------------------------

build: packer build/mappings.yml build/aws-stack.yml

# Build a mapping file for a single region and image id pair
mappings-for-linux-amd64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: %s, linuxarm64: '', windows: '' }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Build a mapping file for a single region and image id pair
mappings-for-linux-arm64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: '', linuxarm64: %s, windows: '' }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Build a windows mapping file for a single region and image id pair
mappings-for-windows-amd64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: '', linuxarm64: '', windows: %s }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Takes the mappings files and copies them into a generated stack template
.PHONY: build/aws-stack.yml
build/aws-stack.yml:
	test -f build/mappings.yml
	awk '{ \
		if ($$0 ~ /AWSRegion2AMI:/ && system("test -f build/mappings.yml") == 0) { \
			system("grep -v Mappings: build/mappings.yml") \
		} else { \
			print \
		}\
	}' templates/aws-stack.yml | sed "s/%v/$(VERSION)/" > $@

# -----------------------------------------
# AMI creation with Packer

packer: packer-linux-amd64.output packer-linux-arm64.output packer-windows-amd64.output

build/mappings.yml: build/linux-amd64-ami.txt build/linux-arm64-ami.txt build/windows-amd64-ami.txt
	mkdir -p build
	printf "Mappings:\n  AWSRegion2AMI:\n    %q : { linuxamd64: %q, linuxarm64: %q, windows: %q }\n" \
		"$(AWS_REGION)" $$(cat build/linux-amd64-ami.txt) $$(cat build/linux-arm64-ami.txt) $$(cat build/windows-amd64-ami.txt) > $@

build/linux-amd64-ami.txt: packer-linux-amd64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

# Build linux packer image
packer-linux-amd64.output: $(PACKER_LINUX_FILES) build/s3secrets-helper-linux-amd64
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/linux \
		hashicorp/packer:$(PACKER_VERSION) build -timestamp-ui -var 'region=$(AWS_REGION)' \
			-var 'arch=x86_64' -var 'goarch=amd64' -var 'instance_type=$(AMD64_INSTANCE_TYPE)' \
			buildkite-ami.json | tee $@

build/linux-arm64-ami.txt: packer-linux-arm64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

# Build linuxarm64 packer image
packer-linux-arm64.output: $(PACKER_LINUX_FILES) build/s3secrets-helper-linux-arm64
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/linux \
		hashicorp/packer:$(PACKER_VERSION) build -timestamp-ui -var 'region=$(AWS_REGION)' \
			-var 'arch=arm64' -var 'goarch=arm64' -var 'instance_type=$(ARM64_INSTANCE_TYPE)' \
			buildkite-ami.json | tee $@

build/windows-amd64-ami.txt: packer-windows-amd64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

# Build windows packer image
packer-windows-amd64.output: $(PACKER_WINDOWS_FILES) build/s3secrets-helper-windows-amd64.exe
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/windows \
		hashicorp/packer:$(PACKER_VERSION) build -timestamp-ui -var 'region=$(AWS_REGION)' \
			buildkite-ami.json | tee $@

# -----------------------------------------
# Cloudformation helpers

TEMPLATE = aws-stack.yml

config.json:
	cp config.json.example config.json

create-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation create-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--disable-rollback \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
		--parameters "$$(cat config.json)"

update-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation update-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
		--parameters "$$(cat config.json)"


# -----------------------------------------
# Other

AGENT_VERSION ?= $(shell curl -Lfs "https://buildkite.com/agent/releases/latest?platform=linux&arch=amd64" | grep version | cut -d= -f2)

bump-agent-version:
	sed -i.bak -E "s/\[Buildkite Agent v.*\]/[Buildkite Agent v$(AGENT_VERSION)]/g" README.md
	sed -i.bak -E "s/AGENT_VERSION=.+/AGENT_VERSION=$(AGENT_VERSION)/g" packer/linux/scripts/install-buildkite-agent.sh
	sed -i.bak -E "s/\\\$$AGENT_VERSION = \".+\"/\$$AGENT_VERSION = \"$(AGENT_VERSION)\"/g" packer/windows/scripts/install-buildkite-agent.ps1
	rm README.md.bak packer/linux/scripts/install-buildkite-agent.sh.bak packer/windows/scripts/install-buildkite-agent.ps1.bak
	git add README.md packer/linux/scripts/install-buildkite-agent.sh packer/windows/scripts/install-buildkite-agent.ps1
	git commit -m "Bump buildkite-agent to v$(AGENT_VERSION)"

validate: build/aws-stack.yml
	aws cloudformation validate-template \
		--output text \
		--template-body "file://$(PWD)/build/aws-stack.yml"

generate-toc:
	docker run -it --rm -v "$(PWD):/app" node:slim bash \
		-c "npm install -g markdown-toc && cd /app && markdown-toc -i README.md"

build/s3secrets-helper-linux-amd64:
	cd plugins/secrets/s3secrets-helper && GOOS=linux GOARCH=amd64 go build -o ../../../$@

build/s3secrets-helper-linux-arm64:
	cd plugins/secrets/s3secrets-helper && GOOS=linux GOARCH=arm64 go build -o ../../../$@

build/s3secrets-helper-windows-amd64.exe:
	cd plugins/secrets/s3secrets-helper && GOOS=windows GOARCH=amd64 go build -o ../../../$@
