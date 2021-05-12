module ComoniconCast

using Pkg
using Markdown
using ExproniconLite
using ComoniconOptions
using ComoniconTypes

export JLArgument, JLOption, JLFlag, JLMD, JLMDFlag, JLMDOption,
    @cast, @main, cast, cast_args, cast_flags, cast_options, default_name,
    get_version, split_leaf_command, split_docstring, read_arguments, read_description,
    read_options, read_flags, split_hint, split_option

include("types.jl")
include("cast.jl")
include("markdown.jl")
include("utils.jl")

end
