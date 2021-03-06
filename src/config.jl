module config

export Config

using YAML

struct Config
    input_datadir::String
    output_datadir::String
    input_datafiles::Dict{String, String}  # tablename => filename
    params::Dict{Symbol, Float64}  # name => value

    function Config(input_datadir, output_datadir, input_datafiles, params)
        !isdir(input_datadir)  && error("Input data directory does not exist: $(input_datadir)")
        !isdir(dirname(output_datadir)) && error("The directory containing the output data directory does not exist: $(dirname(output_datadir))")
        filenames = readdir(input_datadir; join=true)
        for filename in filenames
            !isfile(filename) && error("Input data file does not exist: $(basename(filename))")
        end
        new(input_datadir, output_datadir, input_datafiles, params)
    end
end

Config(configfile::String) = Config(YAML.load_file(configfile))

function Config(d::Dict)
    indir_attempt  = constructpath(d["input_datadir"], '/')
    indir   = isdir(indir_attempt) ? indir_attempt : constructpath(joinpath(pwd(), d["input_datadir"]), '/')
    outdir_attempt = constructpath(d["output_datadir"], '/')
    outdir  = isdir(outdir_attempt) ? outdir_attempt : constructpath(joinpath(pwd(), d["output_datadir"]), '/')
    infiles = d["input_datafiles"]
    params  = Dict{Symbol, Float64}(Symbol(d2["name"]) => Float64(d2["value"]) for d2 in d["params"])
    Config(indir, outdir, infiles, params)
end

"Constructs a valid file or directory path by ensuring the correct separator for the operating system."
function constructpath(s::String, sep::Char)
    parts = split(s, sep)
    normpath(joinpath(parts...))
end

end