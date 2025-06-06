# Regularization

## Setup

For ridge regularization, you can simply use `SemRidge` as an additional loss function 
(for example, a model with the loss functions `SemML` and `SemRidge` corresponds to ridge-regularized maximum likelihood estimation).

For lasso, elastic net and (far) beyond, you can load the `ProximalAlgorithms.jl` and `ProximalOperators.jl` packages alongside `StructuralEquationModels`:

```@setup reg
using StructuralEquationModels, ProximalAlgorithms, ProximalOperators
```

```julia
using Pkg
Pkg.add("ProximalAlgorithms")
Pkg.add("ProximalOperators")

using StructuralEquationModels, ProximalAlgorithms, ProximalOperators
```

## `SemOptimizerProximal`

To estimate regularized models, we provide a "building block" for the optimizer part, called `SemOptimizerProximal`.
It connects our package to the [`ProximalAlgorithms.jl`](https://github.com/JuliaFirstOrder/ProximalAlgorithms.jl) optimization backend, providing so-called proximal optimization algorithms. 
Those can handle, amongst other things, various forms of regularization.

It can be used as

```julia
SemOptimizerProximal(
    algorithm = ProximalAlgorithms.PANOC(),
    operator_g,
    operator_h = nothing
    )
```

The proximal operator (aka the regularization function) can be passed as `operator_g`.
The available Algorithms are listed [here](https://juliafirstorder.github.io/ProximalAlgorithms.jl/stable/guide/implemented_algorithms/).

## First example - lasso

To show how it works, let's revisit [A first model](@ref):

```@example reg
observed_vars = [:x1, :x2, :x3, :y1, :y2, :y3, :y4, :y5, :y6, :y7, :y8]
latent_vars = [:ind60, :dem60, :dem65]

graph = @StenoGraph begin

    ind60 → fixed(1)*x1 + x2 + x3
    dem60 → fixed(1)*y1 + y2 + y3 + y4
    dem65 → fixed(1)*y5 + y6 + y7 + y8

    dem60 ← ind60
    dem65 ← dem60
    dem65 ← ind60

    _(observed_vars) ↔ _(observed_vars)
    _(latent_vars) ↔ _(latent_vars)

    y1 ↔ label(:cov_15)*y5
    y2 ↔ label(:cov_24)*y4 + label(:cov_26)*y6
    y3 ↔ label(:cov_37)*y7
    y4 ↔ label(:cov_48)*y8
    y6 ↔ label(:cov_68)*y8

end

partable = ParameterTable(
    graph,
    latent_vars = latent_vars, 
    observed_vars = observed_vars
)

data = example_data("political_democracy")

model = Sem(
    specification = partable,
    data = data
)
```

We labeled the covariances between the items because we want to regularize those:

```@example reg
ind = getindex.(
    [param_indices(model)], 
    [:cov_15, :cov_24, :cov_26, :cov_37, :cov_48, :cov_68])
```

In the following, we fit the same model with lasso regularization of those covariances.
The lasso penalty is defined as

```math
\sum \lambda_i \lvert \theta_i \rvert
```

From the previously linked [documentation](https://juliafirstorder.github.io/ProximalOperators.jl/stable/functions/#ProximalOperators.NormL1), we find that lasso regularization is named `NormL1` in the `ProximalOperators` package, and that we can pass an array of hyperparameters (`λ`) to control the amount of regularization for each parameter. To regularize only the observed item covariances, we define `λ` as

```@example reg
λ = zeros(31); λ[ind] .= 0.02
```

and use `SemOptimizerProximal`.

```@example reg
optimizer_lasso = SemOptimizerProximal(
    operator_g = NormL1(λ)
    )

model_lasso = Sem(
    specification = partable,
    data = data
)
```

Let's fit the regularized model

```@example reg

fit_lasso = fit(optimizer_lasso, model_lasso)
```

and compare the solution to unregularizted estimates:

```@example reg
sem_fit = fit(model)

update_estimate!(partable, sem_fit)

update_partable!(partable, :estimate_lasso, param_labels(fit_lasso), solution(fit_lasso))

details(partable)
```

Instead of explicitely defining a `SemOptimizerProximal` object, you can also pass `engine = :Proximal` and additional keyword arguments to `fit`:

```@example reg
sem_fit = fit(model; engine = :Proximal, operator_g = NormL1(λ))
```

## Second example - mixed l1 and l0 regularization

You can choose to penalize different parameters with different types of regularization functions.
Let's use the lasso again on the covariances, but additionally penalyze the error variances of the observed items via l0 regularization.

The l0 penalty is defined as
```math
\lambda \mathrm{nnz}(\theta)
```

To define a sup of separable proximal operators (i.e. no parameter is penalized twice),
we can use [`SlicedSeparableSum`](https://juliafirstorder.github.io/ProximalOperators.jl/stable/calculus/#ProximalOperators.SlicedSeparableSum) from the `ProximalOperators` package:

```@example reg
prox_operator = SlicedSeparableSum((NormL0(20.0), NormL1(0.02), NormL0(0.0)), ([ind], [9:11], [vcat(1:8, 12:25)]))

model_mixed = Sem(
    specification = partable,
    data = data,    
)

fit_mixed = fit(model_mixed; engine = :Proximal, operator_g = prox_operator)
```

Let's again compare the different results:

```@example reg
update_partable!(partable, :estimate_mixed, param_labels(fit_mixed), solution(fit_mixed))

details(partable)
```