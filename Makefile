FC = gfortran
FFLAGS = -O3 -Wall -Wextra -fcheck=all -Jinclude

SRC_DIR = src
OBJ_DIR = obj
BIN_DIR = bin

MODULE_SRCS = $(SRC_DIR)/math_3d.f90 \
              $(SRC_DIR)/mesh.f90 \
              $(SRC_DIR)/camera.f90 \
              $(SRC_DIR)/renderer.f90
MAIN_SRC = $(SRC_DIR)/main.f90

MODULE_OBJS = $(OBJ_DIR)/math_3d.o \
              $(OBJ_DIR)/mesh.o \
              $(OBJ_DIR)/camera.o \
              $(OBJ_DIR)/renderer.o
MAIN_OBJ = $(OBJ_DIR)/main.o

TARGET = $(BIN_DIR)/engine3d

all: $(TARGET)

$(TARGET): $(MODULE_OBJS) $(MAIN_OBJ)
	@mkdir -p $(BIN_DIR)
	$(FC) $(FFLAGS) -o $@ $^

$(OBJ_DIR)/math_3d.o: $(SRC_DIR)/math_3d.f90
	@mkdir -p $(OBJ_DIR) include
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/mesh.o: $(SRC_DIR)/mesh.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) include
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/camera.o: $(SRC_DIR)/camera.f90 $(OBJ_DIR)/math_3d.o
	@mkdir -p $(OBJ_DIR) include
	$(FC) $(FFLAGS) -c $< -o $@

$(OBJ_DIR)/renderer.o: $(SRC_DIR)/renderer.f90 $(OBJ_DIR)/math_3d.o $(OBJ_DIR)/mesh.o $(OBJ_DIR)/camera.o
	@mkdir -p $(OBJ_DIR) include
	$(FC) $(FFLAGS) -c $< -o $@

$(MAIN_OBJ): $(MAIN_SRC) $(MODULE_OBJS)
	@mkdir -p $(OBJ_DIR) include
	$(FC) $(FFLAGS) -c $< -o $@

run: $(TARGET)
	@./$(TARGET)
	@which convert >/dev/null 2>&1 && convert output_render.ppm output_render.png && echo "[+] Converted to output_render.png" || true

clean:
	rm -rf $(OBJ_DIR)/*.o include/*.mod $(BIN_DIR)/* output_render.ppm output_render.png

.PHONY: all run clean
