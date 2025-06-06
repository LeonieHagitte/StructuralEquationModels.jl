"""
Type alias for [`SemObservedData`](@ref) that has mean and covariance, but no actual data.

For instances of `SemObservedCovariance` [`samples`](@ref) returns `nothing`.
"""
const SemObservedCovariance{S} = SemObservedData{Nothing, S}

"""
    SemObservedCovariance(;
        specification,
        obs_cov,
        nsamples,
        obs_mean = nothing,
        observed_vars = nothing,
        kwargs...)

Construct [`SemObserved`](@ref) without providing the observations data,
but with the covariations (`obs_cov`) and the means (`obs_means`) of the observed variables.

Returns [`SemObservedCovariance`](@ref) object.

# Arguments
- `obs_cov`: pre-computed covariance matrix of the observed variables
- `nsamples::Integer`: number of samples (observed data points) used to compute `obs_cov` and `obs_means`,
   used for calculating fit statistics
- `obs_mean`: optional pre-computed means of the observed variables
- `observed_vars::AbstractVector`: IDs of the observed variables (rows and columns of the `obs_cov` matrix)
- `specification`: optional SEM specification ([`SemSpecification`](@ref))

"""
function SemObservedCovariance(;
    obs_cov::AbstractMatrix,
    obs_mean::Union{AbstractVector, Nothing} = nothing,
    observed_vars::Union{AbstractVector, Nothing} = nothing,
    specification::Union{SemSpecification, Nothing} = nothing,
    nsamples::Integer,
    observed_var_prefix::Union{Symbol, AbstractString} = :obs,
    kwargs...,
)
    nvars = size(obs_cov, 1)
    size(obs_cov, 2) == nvars || throw(
        DimensionMismatch(
            "The covariance matrix should be square, $(size(obs_cov)) was found.",
        ),
    )
    S = eltype(obs_cov)

    if isnothing(obs_mean)
        obs_mean = zeros(S, nvars)
    else
        length(obs_mean) == nvars || throw(
            DimensionMismatch(
                "The length of the mean vector $(length(obs_mean)) does not match the size of the covariance matrix $(size(obs_cov))",
            ),
        )
        S = promote_type(S, eltype(obs_mean))
    end

    obs_cov = convert(Matrix{S}, obs_cov)
    obs_mean = convert(Vector{S}, obs_mean)

    if !isnothing(observed_vars)
        length(observed_vars) == nvars || throw(
            DimensionMismatch(
                "The length of the observed_vars $(length(observed_vars)) does not match the size of the covariance matrix $(size(obs_cov))",
            ),
        )
    end

    _, obs_vars, obs_vars_perm =
        prepare_data((nsamples, nvars), observed_vars, specification; observed_var_prefix)

    # reorder to match the specification
    if !isnothing(obs_vars_perm)
        obs_cov = obs_cov[obs_vars_perm, obs_vars_perm]
        obs_mean = obs_mean[obs_vars_perm]
    end

    return SemObservedData(nothing, obs_vars, obs_cov, obs_mean, nsamples)
end
