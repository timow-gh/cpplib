$files = git ls-files -- '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hh' '*.hpp' '*.hxx'
foreach ($file in $files) {
    & clang-format -i -- $file
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
