#include "cpplib/cpplib.hpp"

#include <fmt/core.h>

namespace cpplib {

void libraryFunction(int value) {
    fmt::print("Hello from libraryFunction! The answer is {}\n", value);
}

} // namespace cpplib
