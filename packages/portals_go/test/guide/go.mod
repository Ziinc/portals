module example.com/text_worker

go 1.21

require github.com/Ziinc/portals/sdk/go v0.0.0

// In an application this is ../deps/portals_go/priv/go (see the Go guide).
replace github.com/Ziinc/portals/sdk/go => ../../priv/go
