"""
    se_hessian(semfit::SemFit; hessian = :finitediff)

Return hessian based standard errors.

# Arguments
- `hessian`: how to compute the hessian. Options are 
    - `:analytic`: (only if an analytic hessian for the model can be computed)
    - `:finitediff`: for finite difference approximation 
"""
function se_hessian(sem_fit::SemFit; hessian = :finitediff)

    c = H_scaling(sem_fit.model)

    if hessian == :analytic
        par = solution(sem_fit)
        H = zeros(eltype(par), length(par), length(par))
        hessian!(H, sem_fit.model, sem_fit.solution)
    elseif hessian == :finitediff
        H = FiniteDiff.finite_difference_hessian(
                x -> objective!(sem_fit.model, x), 
                sem_fit.solution
                )
    elseif hessian == :optimizer
        throw(ArgumentError("standard errors from the optimizer hessian are not implemented yet"))
    elseif hessian == :expected
        throw(ArgumentError("standard errors based on the expected hessian are not implemented yet"))
    else
        throw(ArgumentError("I dont know how to compute `$how` standard-errors"))
    end

    invH = c*inv(H)
    se = sqrt.(diag(invH))

    return se
end

# Addition functions -------------------------------------------------------------
H_scaling(model::AbstractSemSingle) = 
    H_scaling(
        model,
        model.observed,
        model.imply,
        model.optimizer,
        model.loss.functions...)

H_scaling(model, obs, imp, optimizer, lossfun::Union{SemML, SemWLS}) =
    2/(n_obs(model)-1)

H_scaling(model, obs, imp, optimizer, lossfun::SemFIML) =
    2/n_obs(model)

H_scaling(model::SemEnsemble) =
    2/n_obs(model)