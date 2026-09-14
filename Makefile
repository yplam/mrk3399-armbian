# Build an Armbian image for the MRK3399 board. See README.md.
.PHONY: all setup build uboot kernel clean

ARMBIAN_BUILD_REPO   ?= https://github.com/armbian/build.git
# The armbian/build commit these userpatches are tested against.
# Read "Upgrading armbian/build" in docs/design.md before changing it.
ARMBIAN_BUILD_COMMIT ?= 2a53f15877bb694663ba04035a848cea08535d2f
ARMBIAN_DIR          := build
BRANCH               := current

# DEBUG=yes: bring-up boot environment (earlycon, verbosity=7), see docs/troubleshooting.md
DEBUG ?= no

# REVISION=<version>: version in image and package names, must start with a digit.
# Empty: Armbian takes it from build/VERSION at the pinned commit.
REVISION ?=
ARMBIAN_ARGS := $(if $(REVISION),REVISION=$(REVISION))

# Armbian relaunches itself in Docker and passes http_proxy/https_proxy through.
# A proxy bound to 127.0.0.1 on the host is unreachable from the container, so
# PROXY_HOST=<ip> rewrites 127.0.0.1 to an address the container can reach: the
# build host's LAN IP or the Docker bridge gateway (usually 172.17.0.1).
PROXY_HOST ?=
ARMBIAN_ENV := $(if $(PROXY_HOST),$(foreach v,http_proxy https_proxy HTTP_PROXY HTTPS_PROXY,$(if $($(v)),$(v)=$(subst 127.0.0.1,$(PROXY_HOST),$($(v))))))

all: build

# Clone armbian/build at the pinned commit next to our userpatches and link them in.
setup:
	test -d $(ARMBIAN_DIR)/.git || git clone --single-branch --branch main $(ARMBIAN_BUILD_REPO) $(ARMBIAN_DIR)
	cd $(ARMBIAN_DIR) && { git cat-file -e $(ARMBIAN_BUILD_COMMIT)^{commit} 2>/dev/null || git fetch -q origin; } && git checkout -q $(ARMBIAN_BUILD_COMMIT)
	test -L $(ARMBIAN_DIR)/userpatches || ln -s ../userpatches $(ARMBIAN_DIR)/userpatches

# Full image build; output lands in $(ARMBIAN_DIR)/output/images
build: setup
	cd $(ARMBIAN_DIR) && $(ARMBIAN_ENV) ./compile.sh mrk3399 MRK3399_DEBUG=$(DEBUG) $(ARMBIAN_ARGS)

# Rebuild only the U-Boot or kernel packages (faster iteration); output in $(ARMBIAN_DIR)/output/debs
uboot: setup
	cd $(ARMBIAN_DIR) && $(ARMBIAN_ENV) ./compile.sh uboot BOARD=mrk3399 BRANCH=$(BRANCH) $(ARMBIAN_ARGS)

kernel: setup
	cd $(ARMBIAN_DIR) && $(ARMBIAN_ENV) ./compile.sh kernel BOARD=mrk3399 BRANCH=$(BRANCH) $(ARMBIAN_ARGS)

# Remove built images and packages; download and compile caches in $(ARMBIAN_DIR)/cache are kept
clean:
	rm -rf $(ARMBIAN_DIR)/output/images $(ARMBIAN_DIR)/output/debs
