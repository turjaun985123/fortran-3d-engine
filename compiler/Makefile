# Forge3D native compiler (f3dc) -- build skeleton.
#
# Binding layout/contract: compiler/DESIGN.md.  FC = flang-new-18,
# CC = clang-18.  Builds the Fortran modules in src/ (explicit
# dependency order below) plus the program main in src/f3dc_cli.f90,
# producing ./f3dc in this directory.  Objects and .mod files go to
# build/ (nothing is written outside compiler/).
#
# INSTALL NOTE (bin/f3dc): the repo root's bin/ is where built
# binaries live (the top-level Makefile puts bin/engine3d there).
# Once the port is complete, installing this binary means copying or
# symlinking compiler/f3dc -> ../bin/f3dc so `f3dc` sits next to the
# engine it drives.  There is deliberately NO install target yet and
# this Makefile never writes outside compiler/; the top-level
# Makefile is untouched by the port.

FC       = flang-new-18
CC       = clang-18
FFLAGS   = -O2 -ffree-form
MODFLAGS = -Jbuild -Ibuild
CFLAGS   = -O2

BUILD_DIR = build
TARGET    = f3dc

# Module sources in dependency order, exactly as laid out in
# DESIGN.md.  EXTEND THIS LIST as modules land: a new module goes
# after everything it USEs and before everything that USEs it.
# Entries that do not exist yet are dropped by the $(wildcard ...)
# filter below, so this Makefile builds TODAY with whatever subset
# of src/*.f90 is present and keeps building as modules arrive.
ORDERED_SRC = src/f3dc_str.f90 \
              src/f3dc_dyn.f90 \
              src/f3dc_errors.f90 \
              src/f3dc_lexer.f90 \
              src/f3dc_parser.f90 \
              src/f3dc_desugar.f90 \
              src/f3dc_ir.f90 \
              src/f3dc_emit_common.f90 \
              src/f3dc_ext_materials.f90 \
              src/f3dc_ext_geometry.f90 \
              src/f3dc_ext_cameras.f90 \
              src/f3dc_ext_post.f90 \
              src/f3dc_ext_lights_env.f90 \
              src/f3dc_ext_particles.f90 \
              src/f3dc_ext_sprites_text.f90 \
              src/f3dc_ext_keys.f90 \
              src/f3dc_ext_skin.f90 \
              src/f3dc_ext_shader.f90 \
              src/f3dc_ext_gltf.f90 \
              src/f3dc_validate.f90 \
              src/f3dc_optimize.f90 \
              src/f3dc_compat.f90 \
              src/f3dc_emit_json.f90 \
              src/f3dc_emit_js.f90 \
              src/f3dc_emit_html.f90 \
              src/f3dc_emit_fortran.f90

DRIVER_SRC = src/f3dc_driver.f90
MAIN_SRC   = src/f3dc_cli.f90

# Only the files that exist today take part (see comment above).
CORE_SRC := $(foreach f,$(ORDERED_SRC),$(wildcard $(f)))

# Extension modules (ports of tools/f3dc/ext_*.py) slot in after the
# emitters and before the driver; alphabetical order is fine unless
# one USEs another, in which case give it an ORDERED_SRC entry.
EXT_SRC := $(filter-out $(CORE_SRC),$(sort $(wildcard src/f3dc_ext_*.f90)))

# Any other .f90 that appears in src/ without an ORDERED_SRC entry
# is still compiled (just before the driver/main) so a forgotten
# list update does not silently drop a module; fix the list anyway.
EXTRA_SRC := $(filter-out $(CORE_SRC) $(EXT_SRC) $(DRIVER_SRC) $(MAIN_SRC),\
               $(sort $(wildcard src/*.f90)))

SRC := $(CORE_SRC) $(EXT_SRC) $(EXTRA_SRC) \
       $(wildcard $(DRIVER_SRC)) $(wildcard $(MAIN_SRC))

OBJS = $(patsubst src/%.f90,$(BUILD_DIR)/%.o,$(SRC))

# preview_http.c (clang helper for `f3dc preview`) is optional:
# it is compiled and linked only when present.
ifneq ($(wildcard preview_http.c),)
C_OBJS = $(BUILD_DIR)/preview_http.o
else
C_OBJS =
endif

# The ordered SRC list is the dependency order; keep the build
# serial so a module is always compiled after the modules it USEs.
.NOTPARALLEL:

.PHONY: all clean test-smoke

all: $(TARGET)

$(TARGET): $(OBJS) $(C_OBJS)
	$(FC) $(FFLAGS) -o $@ $(OBJS) $(C_OBJS)

$(BUILD_DIR)/%.o: src/%.f90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(MODFLAGS) -c $< -o $@

$(BUILD_DIR)/preview_http.o: preview_http.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR) $(TARGET)

# Smoke test: the binary exists, reports its version, prints help,
# and rejects an unknown command with cli.py's usage exit code (2).
test-smoke: $(TARGET)
	./$(TARGET) --version
	./$(TARGET) --help > /dev/null
	@./$(TARGET) bogus > /dev/null 2>&1; rc=$$?; \
	if [ $$rc -ne 2 ]; then \
		echo "test-smoke FAIL: './$(TARGET) bogus' exited $$rc, want 2"; \
		exit 1; \
	fi
	@echo "test-smoke: OK (version, help, unknown-command exit 2)"
