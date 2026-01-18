#include "cpplib/cpplib.hpp"
#include <iostream>

namespace cpplib
{

void libraryFunction(int value)
{
  std::cout << "Hello from libraryFunction! The answer is " << value << "\n";
}

}