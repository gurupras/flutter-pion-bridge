// Command shared builds libpionbridge: the bridge as an in-process shared
// library for desktop "shared mode". The exported C functions are defined in
// package cshared; see its documentation for the ABI.
//
// Build: go build -buildmode=c-shared -o libpionbridge.so ./shared
package main

import _ "github.com/gurupras/flutter-pion-bridge/go/cshared"

func main() {}
