// SPDX-License-Identifier: Apache-2.0
// Verify that the isolated official LLVM15 bottle headers/static libraries link natively.
#include <llvm/Config/llvm-config.h>
#include <llvm/Support/raw_ostream.h>
int main() { llvm::outs() << "LLVM static link " LLVM_VERSION_STRING "\n"; }
