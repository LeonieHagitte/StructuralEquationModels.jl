############################################################################################
### Types
############################################################################################

struct ParameterTable{C} <: AbstractParameterTable
    columns::C
    observed_vars::Vector{Symbol}
    latent_vars::Vector{Symbol}
    sorted_vars::Vector{Symbol}
    param_labels::Vector{Symbol}
end

############################################################################################
### Constructors
############################################################################################

# construct a dictionary with the default partable columns
# optionally pre-allocate data for nrows
empty_partable_columns(nrows::Integer = 0) = Dict{Symbol, Vector}(
    :from => fill(Symbol(), nrows),
    :relation => fill(Symbol(), nrows),
    :to => fill(Symbol(), nrows),
    :free => fill(true, nrows),
    :value_fixed => fill(NaN, nrows),
    :start => fill(NaN, nrows),
    :estimate => fill(NaN, nrows),
    :label => fill(Symbol(), nrows),
)

# construct using the provided columns data or create an empty table
function ParameterTable(
    columns::Dict{Symbol, Vector};
    observed_vars::Union{AbstractVector{Symbol}, Nothing} = nothing,
    latent_vars::Union{AbstractVector{Symbol}, Nothing} = nothing,
    param_labels::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    param_labels = isnothing(param_labels) ? unique!(filter(!=(:const), columns[:label])) : copy(param_labels)
    check_param_labels(param_labels, columns[:label])
    return ParameterTable(
        columns,
        !isnothing(observed_vars) ? copy(observed_vars) : Vector{Symbol}(),
        !isnothing(latent_vars) ? copy(latent_vars) : Vector{Symbol}(),
        Vector{Symbol}(),
        param_labels,
    )
end

# new parameter table with different parameters order
function ParameterTable(
    partable::ParameterTable;
    param_labels::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    isnothing(param_labels) || check_param_labels(param_labels, partable.columns[:label])

    return ParameterTable(
        Dict(col => copy(values) for (col, values) in pairs(partable.columns)),
        observed_vars = copy(observed_vars(partable)),
        latent_vars = copy(latent_vars(partable)),
        param_labels = param_labels,
    )
end

vars(partable::ParameterTable) =
    !isempty(partable.sorted_vars) ? partable.sorted_vars :
    vcat(partable.latent_vars, partable.observed_vars)
observed_vars(partable::ParameterTable) = partable.observed_vars
latent_vars(partable::ParameterTable) = partable.latent_vars

nvars(partable::ParameterTable) =
    length(partable.latent_vars) + length(partable.observed_vars)

############################################################################################
### Convert to other types
############################################################################################

function Base.convert(::Type{Dict}, partable::ParameterTable)
    return partable.columns
end

function Base.convert(
    ::Type{ParameterTable},
    partable::ParameterTable;
    param_labels::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    return isnothing(param_labels) || partable.param_labels == param_labels ? partable :
           ParameterTable(partable; param_labels)
end

function DataFrames.DataFrame(
    partable::ParameterTable;
    columns::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    if isnothing(columns)
        columns = keys(partable.columns)
    end
    return DataFrame([col => partable.columns[col] for col in columns])
end

############################################################################################
### Pretty Printing
############################################################################################

function Base.show(io::IO, partable::ParameterTable)
    relevant_columns =
        [:from, :relation, :to, :free, :value_fixed, :start, :estimate, :se, :label]
    shown_columns = filter!(
        col -> haskey(partable.columns, col) && length(partable.columns[col]) > 0,
        relevant_columns,
    )

    as_matrix = mapreduce(col -> partable.columns[col], hcat, shown_columns)
    pretty_table(
        io,
        as_matrix,
        header = (shown_columns, [eltype(partable.columns[col]) for col in shown_columns]),
        tf = PrettyTables.tf_compact,
        # TODO switch to `missing` as non-specified values and suppress printing of `missing` instead
        formatters = (v, i, j) -> isa(v, Number) && isnan(v) ? "" : v,
    )

    print(io, "Latent Variables:    $(partable.latent_vars) \n")
    print(io, "Observed Variables:  $(partable.observed_vars) \n")
end

############################################################################################
### Additional Methods
############################################################################################

# Equality --------------------------------------------------------------------------------
function Base.:(==)(p1::ParameterTable, p2::ParameterTable)
    out =
        (p1.columns == p2.columns) &&
        (p1.observed_vars == p2.observed_vars) &&
        (p1.latent_vars == p2.latent_vars) &&
        (p1.sorted_vars == p2.sorted_vars) &&
        (p1.param_labels == p2.param_labels)
    return out
end

# Iteration --------------------------------------------------------------------------------
ParameterTableRow = @NamedTuple begin
    from::Symbol
    relation::Symbol
    to::Symbol
    free::Bool
    value_fixed::Any
    param::Symbol
end

Base.getindex(partable::ParameterTable, i::Integer) = (
    from = partable.columns[:from][i],
    relation = partable.columns[:relation][i],
    to = partable.columns[:to][i],
    free = partable.columns[:free][i],
    value_fixed = partable.columns[:value_fixed][i],
    param = partable.columns[:label][i],
)

Base.length(partable::ParameterTable) = length(partable.columns[:label])
Base.eachindex(partable::ParameterTable) = Base.OneTo(length(partable))

Base.eltype(::Type{<:ParameterTable}) = ParameterTableRow
Base.iterate(partable::ParameterTable, i::Integer = 1) =
    i > length(partable) ? nothing : (partable[i], i + 1)

nparams(partable::ParameterTable) = length(param_labels(partable))

# Sorting ----------------------------------------------------------------------------------

struct CyclicModelError <: Exception
    msg::AbstractString
end

Base.showerror(io::IO, e::CyclicModelError) = print(io, e.msg)

"""
    sort_vars!(partable::ParameterTable)
    sort_vars!(partables::EnsembleParameterTable)

Sort variables in `partable` so that all independent variables are
before the dependent variables and store it in `partable.sorted_vars`.

If the relations between the variables are acyclic, sorting will
make the resulting `A` matrix in the *RAM* model lower triangular
and allow faster calculations.
"""
function sort_vars!(partable::ParameterTable)
    vars = [
        partable.latent_vars
        partable.observed_vars
    ]

    # regression edges (excluding intercept)
    edges = [
        (from, to) for (rel, from, to) in zip(
            partable.columns[:relation],
            partable.columns[:from],
            partable.columns[:to],
        ) if (rel == :→) && (from != Symbol(1))
    ]
    sort!(edges, by = last) # sort edges by target

    sorted_vars = Vector{Symbol}()

    while !isempty(vars)
        acyclic = false

        for (i, var) in enumerate(vars)
            # check if var has any incoming edge
            eix = searchsortedfirst(edges, (var, var), by = last)
            if !(eix <= length(edges) && last(edges[eix]) == var)
                # var is source, no edges to it
                push!(sorted_vars, var)
                deleteat!(vars, i)
                # remove var outgoing edges
                filter!(e -> e[1] != var, edges)
                acyclic = true
                break
            end
        end

        # if acyclic is false, all vars have incoming edge
        acyclic ||
            throw(CyclicModelError("your model is cyclic and therefore can not be ordered"))
    end

    copyto!(resize!(partable.sorted_vars, length(sorted_vars)), sorted_vars)
    @assert length(partable.sorted_vars) == nvars(partable)

    return partable
end

"""
    sort_vars(partable::ParameterTable)
    sort_vars(partables::EnsembleParameterTable)

Sort variables in `partable` so that all independent variables are
before the dependent variables, and return a copy of `partable`
where the sorted variables are in `partable.sorted_vars`.

See [sort_vars!](@ref) for in-place version.
"""
sort_vars(partable::ParameterTable) = sort_vars!(deepcopy(partable))

# add a row --------------------------------------------------------------------------------

function Base.push!(partable::ParameterTable, d::Union{AbstractDict{Symbol}, NamedTuple})
    issetequal(keys(partable.columns), keys(d)) || throw(
        ArgumentError(
            "The new row needs to have the same keys as the columns of the parameter table.",
        ),
    )
    for (key, val) in pairs(d)
        push!(partable.columns[key], val)
    end
end

############################################################################################
### Update Partable from Fitted Model
############################################################################################

# update generic ---------------------------------------------------------------------------
function update_partable!(
    partable::ParameterTable,
    column::Symbol,
    params::AbstractDict{Symbol, T},
    default::Any = nothing,
) where {T}
    coldata = get!(() -> Vector{T}(undef, length(partable)), partable.columns, column)

    isvec_def = (default isa AbstractVector) && (length(default) == length(partable))

    for (i, par) in enumerate(partable.columns[:label])
        if par == :const
            coldata[i] = !isnothing(default) ? (isvec_def ? default[i] : default) : zero(T)
        elseif haskey(params, par)
            coldata[i] = params[par]
        else
            if isnothing(default)
                throw(KeyError(par))
            else
                coldata[i] = isvec_def ? default[i] : default
            end
        end
    end

    return partable
end

"""
    update_partable!(partable::AbstractParameterTable, param_labels::Vector{Symbol}, params, column)

Write parameter `values` into `column` of `partable`.

The `param_labels` and `params` vectors define the pairs of 
parameters, which are being matched to the `:param` column
of the `partable`.
"""
function update_partable!(
    partable::ParameterTable,
    column::Symbol,
    param_labels::AbstractVector{Symbol},
    params::AbstractVector,
    default::Any = nothing,
)
    length(param_labels) == length(params) || throw(
        ArgumentError(
            "The length of `param_labels` ($(length(param_labels))) and their `params` ($(length(param_labels))) must be the same",
        ),
    )
    check_param_labels(param_labels, nothing)
    params = Dict(zip(param_labels, params))
    update_partable!(partable, column, params, default)
end

# update estimates -------------------------------------------------------------------------
"""
    update_estimate!(
        partable::AbstractParameterTable,
        fit::SemFit)

Write parameter estimates from `fit` to the `:estimate` column of `partable`
"""
update_estimate!(partable::ParameterTable, fit::SemFit) = update_partable!(
    partable,
    :estimate,
    param_labels(fit),
    fit.solution,
    partable.columns[:value_fixed],
)

# fallback method for ensemble
update_estimate!(partable::AbstractParameterTable, fit::SemFit) =
    update_partable!(partable, :estimate, param_labels(fit), fit.solution)

# update starting values -------------------------------------------------------------------
"""
    update_start!(partable::AbstractParameterTable, fit::SemFit)
    update_start!(partable::AbstractParameterTable, model::AbstractSem, start_val; kwargs...)

Write starting values from `fit` or `start_val` to the `:start` column of `partable`.

# Arguments
- `start_val`: either a vector of starting values or a function to compute starting values
    from `model`
- `kwargs...`: are passed to `start_val`
"""
update_start!(partable::AbstractParameterTable, fit::SemFit) = update_partable!(
    partable,
    :start,
    param_labels(fit),
    fit.start_val,
    partable.columns[:value_fixed],
)

function update_start!(
    partable::AbstractParameterTable,
    model::AbstractSem,
    start_val;
    kwargs...,
)
    if !(start_val isa Vector)
        start_val = start_val(model; kwargs...)
    end
    return update_partable!(partable, :start, param_labels(model), start_val)
end

# update partable standard errors ----------------------------------------------------------
"""
    update_se_hessian!(
        partable::AbstractParameterTable,
        fit::SemFit;
        method = :finitediff)

Write hessian standard errors computed for `fit` to the `:se` column of `partable`

# Arguments
- `method::Symbol`: how to compute the hessian, see [se_hessian](@ref) for more information.

# Examples

"""
function update_se_hessian!(
    partable::AbstractParameterTable,
    fit::SemFit;
    method = :finitediff,
)
    se = se_hessian(fit; method)
    return update_partable!(partable, :se, param_labels(fit), se)
end


"""
    lavaan_params!(out::AbstractVector, partable_lav,
                         partable::ParameterTable,
                         lav_col::Symbol = :est, lav_group = nothing)

Extract parameter values from the `partable_lav` lavaan model that
match the parameters of `partable` into the `out` vector.

The method sets the *i*-th element of the `out` vector to
the value of *i*-th parameter from `param_labels(partable)`.

Note that the lavaan and `partable` models are matched by the
the names of variables in the tables (`from` and `to` columns)
as well as the type of their relationship (`relation` column),
and not by the names of the model parameters.
"""
function lavaan_params!(
    out::AbstractVector,
    partable_lav,
    partable::ParameterTable,
    lav_col::Symbol = :est,
    lav_group = nothing,
)

    # find indices of all df row where f is true
    findallrows(f::Function, df) = findall(f(r) for r in eachrow(df))

    (length(out) == nparams(partable)) || throw(
        DimensionMismatch(
            "The length of parameter values vector ($(length(out))) does not match the number of parameters ($(nparams(partable)))",
        ),
    )
    partable_mask = findall(partable.columns[:free])
    param_index = param_indices(partable)

    lav_values = partable_lav[:, lav_col]
    for (from, to, type, id) in zip(
        [
            view(partable.columns[k], partable_mask) for
            k in [:from, :to, :relation, :label]
        ]...,
    )
        lav_ind = nothing

        if from == Symbol(1)
            lav_ind = findallrows(
                r ->
                    r[:lhs] == String(to) &&
                        r[:op] == "~1" &&
                        (isnothing(lav_group) || r[:group] == lav_group),
                partable_lav,
            )
        else
            if type == :↔
                lav_type = "~~"
            elseif type == :→
                if (from ∈ partable.latent_vars) && (to ∈ partable.observed_vars)
                    lav_type = "=~"
                else
                    lav_type = "~"
                    from, to = to, from
                end
            end

            if lav_type == "~~"
                lav_ind = findallrows(
                    r ->
                        (
                                (r[:lhs] == String(from) && r[:rhs] == String(to)) ||
                                (r[:lhs] == String(to) && r[:rhs] == String(from))
                            ) &&
                            r[:op] == lav_type &&
                            (isnothing(lav_group) || r[:group] == lav_group),
                    partable_lav,
                )
            else
                lav_ind = findallrows(
                    r ->
                        r[:lhs] == String(from) &&
                            r[:rhs] == String(to) &&
                            r[:op] == lav_type &&
                            (isnothing(lav_group) || r[:group] == lav_group),
                    partable_lav,
                )
            end
        end

        if length(lav_ind) == 0
            throw(
                ErrorException(
                    "Parameter $id ($from $type $to) could not be found in the lavaan solution",
                ),
            )
        elseif length(lav_ind) > 1
            throw(
                ErrorException(
                    "At least one parameter was found twice in the lavaan solution",
                ),
            )
        end

        param_ind = param_index[id]
        param_val = lav_values[lav_ind[1]]
        if isnan(out[param_ind])
            out[param_ind] = param_val
        else
            @assert out[param_ind] ≈ param_val atol = 1E-10 "Parameter :$id value at row #$lav_ind ($param_val) differs from the earlier encountered value ($(out[param_ind]))"
        end
    end

    return out
end

"""
    lavaan_params(partable_lav, partable::ParameterTable,
                        lav_col::Symbol = :est, lav_group = nothing)

Extract parameter values from the `partable_lav` lavaan model that
match the parameters of `partable`.

The `out` vector should be of `nparams(partable)` length.
The *i*-th element of the `out` vector will contain the
value of the *i*-th parameter from `param_labels(partable)`.

Note that the lavaan and `partable` models are matched by the
the names of variables in the tables (`from` and `to` columns),
and the type of their relationship (`relation` column),
but not by the ids of the model parameters.
"""
lavaan_params(
    partable_lav,
    partable::ParameterTable,
    lav_col::Symbol = :est,
    lav_group = nothing,
) = lavaan_params!(
    fill(NaN, nparams(partable)),
    partable_lav,
    partable,
    lav_col,
    lav_group,
)
