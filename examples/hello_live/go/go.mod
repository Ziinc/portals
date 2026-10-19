module example.com/greeter

go 1.21

require github.com/Ziinc/portals/sdk/go v0.0.0

// This example uses the SDK in this repository. In your own application,
// point at the copy Hex installs: ../deps/portals_go/priv/go
replace github.com/Ziinc/portals/sdk/go => ../../../packages/portals_go/priv/go
