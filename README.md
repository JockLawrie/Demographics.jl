# NOTE: This repo has been archived. The project is continued at https://github.com/NathanHarding/Demographics.jl

# Demographics.jl

```julia
using Demographics

# Construct population according to the config.
configfile = joinpath(pwd(), "config", "config.yml")
people = construct_population(configfile)

# Save the population and contacts to the specified directory.
outdir = "/path/to/output/directory"
save(people, outdir)

# Load the population and contacts from disk.
# The contacts are stored in containers as variables within the Demographics module.
people = load(outdir)
```