CXX := clang++
CXXFLAGS := -std=c++17 -Wall -Wextra -Wpedantic -Icore/include -O2
BUILD_DIR := build
CORE_OBJ := $(BUILD_DIR)/gaze_sdk.o
LIB := $(BUILD_DIR)/libgaze_sdk.a
TEST_BIN := $(BUILD_DIR)/core_tests

.PHONY: all test clean

all: $(LIB)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(CORE_OBJ): core/src/gaze_sdk.cpp | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(LIB): $(CORE_OBJ)
	ar rcs $@ $^

$(TEST_BIN): tests/core_tests.cpp $(LIB)
	$(CXX) $(CXXFLAGS) tests/core_tests.cpp $(LIB) -o $@

test: $(TEST_BIN)
	$(TEST_BIN)

clean:
	rm -rf $(BUILD_DIR)
