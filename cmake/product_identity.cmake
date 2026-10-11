# Product identity: who ships this product, and how installed copies of it are
# recognized by later versions.
#
# The values are written once by tools/create_new_product.cmake when a new product
# is created from this template. Name, version, description and homepage live in
# the project() call of the root CMakeLists.txt.

set(PRODUCT_VENDOR "timow-gh")
set(PRODUCT_CONTACT "timow-gh <39085531+timow-gh@users.noreply.github.com>")

# MSI upgrade code. Windows Installer uses it to recognize a new MSI as an upgrade
# of an installed earlier version of this product. It is not a secret: it is part
# of every MSI and of the registry of every machine the product is installed on.
#
# NEVER CHANGE IT after the first release. A different value turns the next MSI
# into a separate product that installs side by side with the old version instead
# of upgrading it. The release workflow (.github/workflows/release.yml) compares it
# with the last release and refuses to publish a release in which it changed.
set(PRODUCT_WIX_UPGRADE_GUID "6E7C3F4B-9A21-4D8E-B5C6-2F0A1D3E4B7C")
