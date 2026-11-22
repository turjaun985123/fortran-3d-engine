FC = gfortran
FFLAGS = -O3 -Wall -Wextra -Jinclude
DEBUG_FFLAGS = -O3 -Wall -Wextra -fcheck=all -Jinclude

SRC_DIR = src
OBJ_DIR = obj
BIN_DIR = bin
MOD_DIR = include

# All src modules, in dependency order:
# math_3d -> material_3d -> material_pbr_3d (Wave A) -> mesh_3d ->
# camera_3d -> texture_3d (A) -> lighting_3d (A) -> shadow_3d (A) ->
# obj_loader -> animation_3d -> scene_3d -> renderer_3d ->
# fog_3d (A) -> tonemapping_3d (A) -> main
MODULE_OBJS = $(OBJ_DIR)/math_3d.o \
              $(OBJ_DIR)/material_3d.o \
              $(OBJ_DIR)/material_pbr_3d.o \
              $(OBJ_DIR)/mesh_3d.o \
              $(OBJ_DIR)/camera_3d.o \
              $(OBJ_DIR)/texture_3d.o \
              $(OBJ_DIR)/lighting_3d.o \
              $(OBJ_DIR)/shadow_3d.o \
              $(OBJ_DIR)/obj_loader.o \
              $(OBJ_DIR)/animation_3d.o \
              $(OBJ_DIR)/scene_3d.o \
              $(OBJ_DIR)/renderer_3d.o \
              $(OBJ_DIR)/fog_3d.o \
              $(OBJ_DIR)/tonemapping_3d.o
MAIN_OBJ = $(OBJ_DIR)/main.o

TARGET = $(BIN_DIR)/engine3d

all: $(TARGET)

$(TARGET): $(MODULE_OBJS) $(MAIN_OBJ)
	@mkdir -p $(BIN_DIR)
	$(FC) $(FFLAGS) -o $@ $^

$(OBJ_DIR)/math_3d.o: $(SRC_DIR)/math_3d.f90
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/material_3d.o: $(SRC_DIR)/material.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/material_pbr_3d.o: $(SRC_DIR)/material_pbr.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/material_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/mesh_3d.o: $(SRC_DIR)/mesh.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/texture_3d.o: $(SRC_DIR)/texture.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/lighting_3d.o: $(SRC_DIR)/lighting.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/material_pbr_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/shadow_3d.o: $(SRC_DIR)/shadow.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/mesh_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/camera_3d.o: $(SRC_DIR)/camera.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/obj_loader.o: $(SRC_DIR)/obj_loader.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/mesh_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/animation_3d.o: $(SRC_DIR)/animation.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/scene_3d.o: $(SRC_DIR)/scene.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/material_3d.o $(OBJ_DIR)/material_pbr_3d.o $(OBJ_DIR)/mesh_3d.o $(OBJ_DIR)/camera_3d.o $(OBJ_DIR)/texture_3d.o $(OBJ_DIR)/lighting_3d.o $(OBJ_DIR)/obj_loader.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/renderer_3d.o: $(SRC_DIR)/renderer.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/material_3d.o $(OBJ_DIR)/material_pbr_3d.o $(OBJ_DIR)/mesh_3d.o $(OBJ_DIR)/camera_3d.o $(OBJ_DIR)/texture_3d.o $(OBJ_DIR)/lighting_3d.o $(OBJ_DIR)/shadow_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/fog_3d.o: $(SRC_DIR)/fog.f90 $(OBJ_DIR)/renderer_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/tonemapping_3d.o: $(SRC_DIR)/tonemapping.f90 $(OBJ_DIR)/renderer_3d.o
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

$(MAIN_OBJ): $(SRC_DIR)/main.f90 $(MODULE_OBJS)
	@mkdir -p $(OBJ_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

# Release build is the default (FFLAGS above, no -fcheck=all per
# MASTER-PLAN G1); 'make debug' rebuilds everything WITH -fcheck=all.
debug:
	$(MAKE) clean
	$(MAKE) all FFLAGS="$(DEBUG_FFLAGS)"

run: $(TARGET)
	@./$(TARGET)
	@which convert >/dev/null 2>&1 && convert output_render.ppm output_render.png && echo "[+] Converted to output_render.png" || true

test:
	python3 tests/run_tests.py

minjs:
	@if command -v npx >/dev/null 2>&1 && npx --no-install terser --version >/dev/null 2>&1; then \
		echo "[+] Minifying runtime/f3d.js with terser (via npx)"; \
		npx --no-install terser runtime/f3d.js -o runtime/f3d.min.js; \
	else \
		echo "[+] terser not available; using python fallback (strip full-line comments and blank lines)"; \
		python3 -c "import pathlib; lines = pathlib.Path('runtime/f3d.js').read_text().splitlines(); out = [l for l in lines if l.strip() and not l.lstrip().startswith('//')]; pathlib.Path('runtime/f3d.min.js').write_text('\n'.join(out) + '\n')"; \
	fi
	@size=$$(wc -c < runtime/f3d.min.js); echo "runtime/f3d.min.js: $$size bytes (budget 15360)"; \
	if [ $$size -gt 15360 ]; then echo "[-] minjs OVER BUDGET: $$size > 15360" >&2; exit 1; fi

clean:
	rm -rf $(OBJ_DIR)/*.o $(MOD_DIR)/*.mod $(BIN_DIR)/* output_render.ppm output_render.png

.PHONY: all debug run test minjs clean
