# Custom loss functions

As an example, we will implement ridge regularization. Maximum likelihood estimation with ridge regularization consists of optimizing the objective
```math
F_{ML}(\theta) + \alpha \lVert \theta_I \rVert^2_2
```
Since we allow for the optimization of sums of loss functions, and the maximum likelihood loss function already exists, we only need to implement the ridge part (and additionally get ridge regularization for WLS and FIML estimation for free).

## Minimal
```@setup loss
using StructuralEquationModels
```

To define a new loss function, you have to define a new type that is a subtype of `SemLossFunction`:
```@example loss
struct Ridge <: SemLossFunction
    α
    I
end
```
We store the hyperparameter α and the indices I of the parameters we want to regularize.

Additionaly, we need to define a *method* of the function `evaluate!` to compute the objective:

```@example loss
import StructuralEquationModels: evaluate!

evaluate!(objective::Number, gradient::Nothing, hessian::Nothing, ridge::Ridge, model::AbstractSem, par) = 
  ridge.α * sum(i -> par[i]^2, ridge.I)
```

The function `evaluate!` recognizes by the types of the arguments `objective`, `gradient` and `hessian` whether it should compute the objective value, gradient or hessian of the model w.r.t. the parameters.
In this case, `gradient` and `hessian` are of type `Nothing`, signifying that they should not be computed, but only the objective value.

That's all we need to make it work! For example, we can now fit [A first model](@ref) with ridge regularization:

We first give some parameters labels to be able to identify them as targets for the regularization:

```@example loss
observed_vars = [:x1, :x2, :x3, :y1, :y2, :y3, :y4, :y5, :y6, :y7, :y8]
latent_vars = [:ind60, :dem60, :dem65]

graph = @StenoGraph begin

    # loadings
    ind60 → fixed(1)*x1 + x2 + x3
    dem60 → fixed(1)*y1 + y2 + y3 + y4
    dem65 → fixed(1)*y5 + y6 + y7 + y8

    # latent regressions
    ind60 → label(:a)*dem60
    dem60 → label(:b)*dem65
    ind60 → label(:c)*dem65

    # variances
    _(observed_vars) ↔ _(observed_vars)
    _(latent_vars) ↔ _(latent_vars)

    # covariances
    y1 ↔ y5
    y2 ↔ y4 + y6
    y3 ↔ y7
    y8 ↔ y4 + y6

end

partable = ParameterTable(
    graph,
    latent_vars = latent_vars,
    observed_vars = observed_vars
)

parameter_indices = getindex.([param_indices(partable)], [:a, :b, :c])
myridge = Ridge(0.01, parameter_indices)

model = SemFiniteDiff(
    specification = partable,
    data = example_data("political_democracy"),
    loss = (SemML, myridge)
)

model_fit = fit(model)
```

This is one way of specifying the model - we now have **one model** with **multiple loss functions**. Because we did not provide a gradient for `Ridge`, we have to specify a `SemFiniteDiff` model that computes numerical gradients with finite difference approximation.

Note that the last argument to the `objective!` method is the whole model. Therefore, we can access everything that is stored inside our model everytime we compute the objective value for our loss function. Since ridge regularization is a very easy case, we do not need to do this. But maximum likelihood estimation for example depends on both the observed and the model implied covariance matrix. See [Second example - maximum likelihood](@ref) for information on how to do that.

### Improve performance

By far the biggest improvements in performance will result from specifying analytical gradients. We can do this for our example:

```@example loss
function evaluate!(objective, gradient, hessian::Nothing, ridge::Ridge, model::AbstractSem, par)
    # compute gradient
    if !isnothing(gradient)
        fill!(gradient, 0)
        gradient[ridge.I] .= 2 * ridge.α * par[ridge.I]
    end
    # compute objective
    if !isnothing(objective) 
        return ridge.α * sum(i -> par[i]^2, ridge.I)
    end
end
```

As you can see, in this method definition, both `objective` and `gradient` can be different from `nothing`.
We then check whether to compute the objective value and/or the gradient with `isnothing(objective)`/`isnothing(gradient)`.
This syntax makes it possible to compute objective value and gradient at the same time, which is beneficial when the the objective and gradient share common computations.

Now, instead of specifying a `SemFiniteDiff`, we can use the normal `Sem` constructor:

```@example loss
model_new = Sem(
    specification = partable,
    data = example_data("political_democracy"),
    loss = (SemML, myridge)
)

model_fit = fit(model_new)
```

The results are the same, but we can verify that the computational costs are way lower (for this, the julia package `BenchmarkTools` has to be installed):

```julia
using BenchmarkTools

@benchmark fit(model)

@benchmark fit(model_new)
```

The exact results of those benchmarks are of course highly depended an your system (processor, RAM, etc.), but you should see that the median computation time with analytical gradients drops to about 5% of the computation without analytical gradients.

Additionally, you may provide analytic hessians by writing a respective method for `evaluate!`. However, this will only matter if you use an optimization algorithm that makes use of the hessians. Our default algorithmn `LBFGS` from the package `Optim.jl` does not use hessians (for example, the `Newton` algorithmn from the same package does).

## Convenient

To be able to build the model with the [Outer Constructor](@ref), you need to add a constructor for your loss function that only takes keyword arguments and allows for passing optional additional kewyword arguments. A constructor is just a function that creates a new instance of your type:

```julia
function MyLoss(;arg1 = ..., arg2, kwargs...)
    ...
    return MyLoss(...)
end
```

All keyword arguments that a user passes to the Sem constructor are passed to your loss function. In addition, all previously constructed parts of the model (implied and observed part) are passed as keyword arguments as well as the number of parameters `n_par = ...`, so your constructor may depend on those. For example, the constructor for `SemML` in our package depends on the additional argument `meanstructure` as well as the observed part of the model to pre-allocate arrays of the same size as the observed covariance matrix and the observed mean vector:

```julia
function SemML(;observed, meanstructure = false, approx_H = false, kwargs...)

    isnothing(obs_mean(observed)) ?
        meandiff = nothing :
        meandiff = copy(obs_mean(observed))

    return SemML(
        similar(obs_cov(observed)),
        similar(obs_cov(observed)),
        meandiff,
        approx_H,
        Val(meanstructure)
        )
end
```

## Additional functionality

### Update observed data

If you are planing a simulation study where you have to fit the **same model** to many **different datasets**, it is computationally beneficial to not build the whole model completely new everytime you change your data.
Therefore, we provide a function to update the data of your model, `replace_observed(model(semfit); data = new_data)`. However, we can not know beforehand in what way your loss function depends on the specific datasets. The solution is to provide a method for `update_observed`. Since `Ridge` does not depend on the data at all, this is quite easy:

```julia
import StructuralEquationModels: update_observed

update_observed(ridge::Ridge, observed::SemObserved; kwargs...) = ridge
```

### Access additional information

If you want to provide a way to query information about loss functions of your type, you can provide functions for that:

```julia
hyperparameter(ridge::Ridge) = ridge.α
regularization_indices(ridge::Ridge) = ridge.I
```

# Second example - maximum likelihood
Let's make a sligtly more complicated example: we will reimplement maximum likelihood estimation.

To keep it simple, we only cover models without a meanstructure. The maximum likelihood objective is defined as

```math
F_{ML} = \log \det \Sigma_i + \mathrm{tr}\left(\Sigma_{i}^{-1} \Sigma_o \right)
```

where ``\Sigma_i`` is the model implied covariance matrix and ``\Sigma_o`` is the observed covariance matrix. We can query the model implied covariance matrix from the `implied` par of our model, and the observed covariance matrix from the `observed` path of our model.

To get information on what we can access from a certain `implied` or `observed` type, we can check it`s documentation an the pages [API - model parts](@ref) or via the help mode of the REPL:

```julia
julia>?

help?> RAM

help?> SemObservedData
```

We see that the model implied covariance matrix can be assessed as `Σ(implied)` and the observed covariance matrix as `obs_cov(observed)`.

With this information, we write can implement maximum likelihood optimization as

```@example loss
struct MaximumLikelihood <: SemLossFunction end

using LinearAlgebra
import StructuralEquationModels: obs_cov, evaluate!

function evaluate!(objective::Number, gradient::Nothing, hessian::Nothing, semml::MaximumLikelihood, model::AbstractSem, par)
    # access the model implied and observed covariance matrices
    Σᵢ = implied(model).Σ
    Σₒ = obs_cov(observed(model))
    # compute the objective
    if isposdef(Symmetric(Σᵢ)) # is the model implied covariance matrix positive definite?
        return logdet(Σᵢ) + tr(inv(Σᵢ)*Σₒ)
    else
        return Inf
    end
end
```

to deal with eventual non-positive definiteness of the model implied covariance matrix, we chose the pragmatic way of returning infinity whenever this is the case.

Let's specify and fit a model:

```@example loss
model_ml = SemFiniteDiff(
    specification = partable,
    data = example_data("political_democracy"),
    loss = MaximumLikelihood()
)

model_fit = fit(model_ml)
```

If you want to differentiate your own loss functions via automatic differentiation, check out the [AutoDiffSEM](https://github.com/StructuralEquationModels/AutoDiffSEM) package.
