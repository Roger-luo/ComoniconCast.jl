using ComoniconCast
using Documenter

DocMeta.setdocmeta!(ComoniconCast, :DocTestSetup, :(using ComoniconCast); recursive=true)

makedocs(;
    modules=[ComoniconCast],
    authors="Roger-Luo <rogerluo.rl18@gmail.com> and contributors",
    repo="https://github.com/Roger-luo/ComoniconCast.jl/blob/{commit}{path}#{line}",
    sitename="ComoniconCast.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://Roger-luo.github.io/ComoniconCast.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/Roger-luo/ComoniconCast.jl",
)
