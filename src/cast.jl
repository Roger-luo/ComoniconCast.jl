macro cast(ex)
    esc(codegen_ast_cast(__module__, QuoteNode(__source__), ex))
end

macro main(ex)
    esc(codegen_project_entry(__module__, QuoteNode(__source__), ex))
end

macro main()
    esc(codegen_project_entry(__module__, QuoteNode(__source__)))
end

function codegen_ast_cast(m::Module, line, ex)
    if ex isa Symbol
        casted = codegen_ast_cast_module(m, line, ex)
    elseif Meta.isexpr(ex, :module)
        casted = codegen_ast_cast_module(m, line, ex)
    elseif is_function(ex)
        casted = codegen_ast_cast_function(m, line, ex)
    else
        error("unkown expression: $ex, expect module name or function definition")
    end

    return quote
        $(codegen_casted_commands(m))
        $casted
    end
end

function is_argument_with_type(ex)
    ex isa Expr || return false
    return Meta.isexpr(ex, :(::))
end

function is_vararg_with_type(ex)
    ex isa Expr || return false
    Meta.isexpr(ex, :(...)) || return false
    return is_argument_with_type(ex.args[1])
end

function is_optional_argument_with_type(ex)
    ex isa Expr || return false
    Meta.isexpr(ex, :kw) || return false
    return is_argument_with_type(ex.args[1])
end

function split_leaf_command(fn::JLFunction)
    # use ::<type> as hint if there is no docstring
    hint(value) = :("::" * $(xcall(Base, :repr, xcall(Base, :typeof, value))))

    args = map(fn.args) do each
        if each isa Symbol
            xcall(ComoniconCast, :JLArgument; name=QuoteNode(each))
        elseif is_argument_with_type(each) # :($name::$type)
            xcall(ComoniconCast, :JLArgument;
                name=QuoteNode(each.args[1]),
                type=wrap_type(fn, each.args[2])
            )
        elseif is_vararg_with_type(each) # :($name::$type...)
            name = each.args[1].args[1]
            type = each.args[1].args[2]
            xcall(ComoniconCast, :JLArgument;
                name=QuoteNode(name),
                type=wrap_type(fn, type),
                require=false,
                vararg=true
            )
        elseif is_optional_argument_with_type(each) # Expr(:kw, :($name::$type), value)
            name = each.args[1].args[1]
            type = each.args[1].args[2]
            value = each.args[2]
            xcall(ComoniconCast, :JLArgument;
                name=QuoteNode(name),
                type=wrap_type(fn, type),
                require=false,
                default=hint(value),
            )
        elseif Meta.isexpr(each, :...) # :($name...)
            xcall(ComoniconCast, :JLArgument;
                name=QuoteNode(each.args[1]),
                require=false,
                vararg=true
            )
        elseif Meta.isexpr(each, :kw) && each.args[1] isa Symbol # Expr(:kw, name::Symbol, value)
            xcall(ComoniconCast, :JLArgument;
                name=QuoteNode(each.args[1]),
                require=false,
                default=hint(each.args[2]),
            )
        else
            throw(Meta.ParseError("invalid syntax: $each"))
        end
    end

    flags, options = [], []
    if !isnothing(fn.kwargs)
        for each in fn.kwargs
            Meta.isexpr(each, :kw) || error("options should have default values or make it a positional argument")
            expr = each.args[1]
            value = each.args[2]
            if expr isa Symbol # Expr(:kw, name::Symbol, value)
                push!(options, xcall(ComoniconCast, :JLOption, QuoteNode(expr), Any, hint(value)))
            elseif Meta.isexpr(expr, :(::))
                name = expr.args[1]
                type = expr.args[2]

                if type === :Bool || type === Bool
                    value == false || error("Boolean options must use false as " *
                        "default value, and will be parsed as flags. got $name")
                    push!(flags, xcall(ComoniconCast, :JLFlag, QuoteNode(name)))
                else
                    push!(options, xcall(ComoniconCast, :JLOption, QuoteNode(name), type, hint(value)))
                end
            end
        end
    end
    args = Expr(:ref, :($ComoniconCast.JLArgument), args...)
    options = Expr(:ref, :($ComoniconCast.JLOption), options...)
    flags = Expr(:ref, :($ComoniconCast.JLFlag), flags...)
    return args, options, flags
end

function wrap_type(def::JLFunction, type)
    def.whereparams === nothing && return type
    return Expr(:where, type, def.whereparams...)
end

function codegen_ast_cast_function(m, line, ex)
    fn = JLFunction(ex)
    args, options, flags = split_leaf_command(fn)

    @gensym cmd
    name = default_name(fn.name)
    return quote
        $ex
        Core.@__doc__ $(fn.name)
        $cmd = $ComoniconCast.cast($(fn.name), $name,
            $args, $options, $flags, $line)
        $m.CASTED_COMMANDS[$name] = $cmd
    end
end

function codegen_ast_cast_module(m, line, ex)
    name = name_only(ex)
    @gensym cmd
    cmd_name = default_name(name)
    return quote
        $(Expr(:toplevel, ex))
        Core.@__doc__ $name
        $cmd = $ComoniconCast.cast($name, $cmd_name, $line)
        $m.CASTED_COMMANDS[$cmd_name] = $cmd
    end
end

function codegen_project_entry(m::Module, line, ex = nothing)
    if has_comonicon_toml(m)
        options = read_configs(m)
        name = options.name        
    else
        name = default_name(nameof(m))
    end

    @gensym cmd entry
    quote
        $(codegen_entry_cmd(m::Module, line, cmd, ex))
        $entry = $ComoniconTypes.CLIEntry($cmd, $(get_version(m)), $line)
        $ComoniconCast.set_cmd!($m.CASTED_COMMANDS, $entry, "main")

        # entry point for apps
        function julia_main()::Cint
            try
                return command_main()
            catch
                Base.invokelatest(Base.display_error, Base.catch_stack())
                return 1
            end
        end

        precompile(Tuple{typeof($m.command_main),Array{String,1}})
    end
end

function codegen_entry_cmd(m::Module, line, cmd, ex)
    if isnothing(ex)
        @gensym doc
        return quote
            Core.@__doc__ const COMMAND_ENTRY_DOC_STUB = nothing
            $doc = @doc(COMMAND_ENTRY_DOC_STUB)
            if $ComoniconCast.has_docstring($doc)
                $doc = $ComoniconCast.read_description($doc)
            else
                $doc = nothing
            end

            $cmd = $ComoniconTypes.NodeCommand(
                $name,
                copy($m.CASTED_COMMANDS),
                $doc,
                $line
            )
        end
    else
        fn = JLFunction(ex)
        args, options, flags = split_leaf_command(fn)
        name = default_name(fn.name)
        return quote
            $(codegen_casted_commands(m))
            $ex
            Core.@__doc__ $(fn.name)
            $cmd = $ComoniconCast.cast($(fn.name), $name,
                $args, $options, $flags, $line)
        end
    end
end

function codegen_casted_commands(m::Module)
    isdefined(m, :CASTED_COMMANDS) && return
    return :(const CASTED_COMMANDS = Dict{String,Any}())
end

function cast(m::Module, name::String = default_name(m), line = LineNumberNode(0))
    isdefined(m, :CASTED_COMMANDS) || error("module $m does not contain any @cast commands")
    NodeCommand(name, copy(m.CASTED_COMMANDS), split_docstring(m), line)
end

function cast(
        f::Function, name::String,
        args::Vector{JLArgument}=JLArgument[],
        options::Vector{JLOption}=JLOption[],
        flags::Vector{JLFlag}=JLFlag[],
        line = LineNumberNode(0)
    )
    doc = split_docstring(f)::JLMD
    args, vararg = cast_args(doc, args, line)
    flags = cast_flags(doc, flags, line)
    options = cast_options(doc, options, line)
    return LeafCommand(f, name, args, count(x->x.require, args), vararg, flags, options, doc.desc, line)
end

function cast_args(doc::JLMD, args::Vector{JLArgument}, line)
    args = map(args) do each
        Argument(
            string(each.name),
            each.type,
            each.vararg,
            each.require,
            each.default,
            Description(get(doc.arguments, string(each.name), nothing)),
            line
        )
    end

    if last(args).vararg
        return args[1:end-1], last(args)
    else
        return args, nothing
    end
end

function cast_flags(doc::JLMD, flags::Vector{JLFlag}, line)
    cmd_flags = Dict{String, Flag}()
    for each in flags
        name = replace(string(each.name), '_'=>'-')
        if haskey(doc.flags, name)
            doc_flag = doc.flags[name]::JLMDFlag
            cmd_flags[name] = flg = Flag(;
                sym=each.name,
                name=name,
                short=doc_flag.short,
                description=Description(doc_flag.desc),
                line=line,
            )

            if doc_flag.short
                cmd_flags[name[1:1]] = flg
            end
        else
            cmd_flags[name] = Flag(;
                sym=each.name,
                name=name,
                line=line
            )
        end
    end
    return cmd_flags
end

function cast_options(doc::JLMD, options::Vector{JLOption}, line)
    cmd_options = Dict{String, Option}()
    for each in options
        name = replace(string(each.name), '_'=>'-')
        if haskey(doc.options, name)
            option = doc.options[name]::JLMDOption
            cmd_options[name] = opt = Option(;
                sym=each.name,
                name=name,
                hint=option.hint, # use user defined hint
                type=each.type,
                short=option.short,
                description=option.desc,
                line=line,
            )

            if option.short
                cmd_options[name[1:1]] = opt
            end
        else
            cmd_options[name] = Option(;
                sym=each.name,
                name=name,
                hint=each.hint,
                type=each.type,
                line=line,
            )
        end
    end
    return cmd_options
end
