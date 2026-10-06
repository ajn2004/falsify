using Pkg

# The test suite is the deterministic, network-free V0 apparatus smoke. Keep
# artifacts in temporary directories as each integration test requires them.
Pkg.test()
