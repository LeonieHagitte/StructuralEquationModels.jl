############################################################################
### Types
############################################################################

struct RAM{A1, A2, A3, A4, A5, A6, V, I1, I2, I3, M1, M2, M3, S1, S2, S3} <: SemImply
    Σ::A1
    A::A2
    S::A3
    F::A4
    μ::A5
    M::A6

    start_val::V

    A_indices::I1
    S_indices::I2
    M_indices::I3

    F⨉I_A⁻¹::M1
    F⨉I_A⁻¹S::M2
    I_A::M3

    ∇Aᵀ::S1
    ∇S::S2
    ∇Σ::S3
end

############################################################################
### Constructors
############################################################################

function RAM(
        A::Spa1,
        S::Spa2,
        F::Spa3,
        parameters,
        start_val;
        M::Spa4 = nothing,
        vech = false,
        gradient = true
            ) where {
            Spa1 <: SparseMatrixCSC,
            Spa2 <: SparseMatrixCSC,
            Spa3 <: SparseMatrixCSC,
            Spa4 <: Union{Nothing, AbstractArray}
            }

    n_var = size(F, 1)
    n_nod = size(F, 2)
        
    A = Matrix(A)
    S = Matrix(S)
    F = Matrix(F)

    A_indices = get_parameter_indices(parameters, A)
    S_indices = get_parameter_indices(parameters, S)

    A_indices = [convert(Vector{Int}, indices) for indices in A_indices]
    S_indices = [convert(Vector{Int}, indices) for indices in S_indices]

    A_pre = zeros(size(A)...)
    S_pre = zeros(size(S)...)

    set_constants!(S, S_pre)

    # A matrix
    set_constants!(A, A_pre)

    A_rand = copy(A_pre)
    randpar = rand(length(start_val))

    fill_matrix(
        A_rand,
        A_indices_linear,
        randpar)

    acyclic = isone(det(I-A_rand))

    # check if A is lower or upper triangular
    if iszero(A_rand[.!tril(ones(Bool, size(A)...))])
        A_pre = LowerTriangular(A_pre)
    elseif iszero(A_rand[.!tril(ones(Bool, size(A)...))'])
        A_pre = UpperTriangular(A_pre)
    elseif acyclic
        @info "Your model is acyclic, specifying the A Matrix as either Upper or Lower Triangular can have great performance benefits."
    end

    F = convert(Matrix{Float64}, F)

    Σ = zeros(n_var, n_var)
    F⨉I_A⁻¹ = zeros(n_nod, n_var)
    F⨉I_A⁻¹S = zeros(n_nod, n_var)
    I_A = zeros(n_nod, n_nod)

    if gradient
        ∇A = get_matrix_derivative(A_indices, parameters, n_nod^2)
        ∇S = get_matrix_derivative(S_indices, parameters, n_nod^2)
    else
        ∇A = nothing
        ∇S = nothing
    end

    # μ
    if !isnothing(M)
    
        M_indices = get_parameter_indices(parameters, M)
        M_indices = [convert(Vector{Int}, indices) for indices in M_indices]
    
        M_pre = zeros(size(M)...)
    
        set_constants!(M, M_pre)
    
        if gradient
            
        else
           
        end

    else
        M_indices = nothing
        M_pre = nothing
    end

    return RAM(
        Σ,
        A_pre,
        S_pre,
        F,
        μ,
        M_pre,

        start_val,

        A_indices,
        S_indices,
        M_indices,

        F⨉I_A⁻¹,
        F⨉I_A⁻¹S,
        I_A,

        ∇A,
        ∇S
    )
end

############################################################################
### functors
############################################################################

function (imply::RAMSymbolic)(parameters, F, G, H, model)

    fill_A_S_M(
        imply.A, 
        imply.S,
        imply.M,
        imply.A_indices, 
        imply.S_indices,
        imply.M_indices,
        parameters)
    
    imply.I_A .= I - imply.A
    rdiv!(imply.F⨉I_A⁻¹, F, I_A)

    Σ_RAM!(
        imply.Σ, 
        F⨉I_A⁻¹, 
        imply.S, 
        F⨉I_A⁻¹S)
    
    if !isnothing(G)
        
    end

    if !isnothing(imply.μ)
        μ_RAM!(imply.μ, imply.F⨉I_A⁻¹, imply.M)
        if !isnothing(G)
            
        end
    end
    
end

############################################################################
### additional functions
############################################################################

function Σ_RAM!(Σ, F⨉I_A⁻¹, S, pre2)
    mul!(pre2, F⨉I_A⁻¹, S)
    mul!(Σ, pre2, F⨉I_A⁻¹')
end

function μ_RAM!(μ, F⨉I_A⁻¹, M)
    mul!(μ, F⨉I_A⁻¹, M)
end