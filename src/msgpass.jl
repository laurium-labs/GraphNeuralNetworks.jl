"""
    propagate(f, g, aggr; xi, xj, e)  ->  m̄

Performs message passing on graph `g`. Takes care of materializing the node features on each edge, 
applying the message function, and returning an aggregated message ``\\bar{\\mathbf{m}}`` 
(depending on the return value of `f`, an array or a named tuple of 
arrays with last dimension's size `g.num_nodes`).

It can be decomposed in two steps:

```julia
m = apply_edges(f, g, xi, xj, e)
m̄ = aggregate_neighbors(g, aggr, m)
```

GNN layers typically call `propagate` in their forward pass,
providing as input `f` a closure.  

# Arguments

- `g`: A `GNNGraph`.
- `xi`: An array or a named tuple containing arrays whose last dimension's size 
        is `g.num_nodes`. It will be appropriately materialized on the
        target node of each edge (see also [`edge_index`](@ref)).
- `xj`: As `xj`, but to be materialized on edges' sources. 
- `e`: An array or a named tuple containing arrays whose last dimension's size is `g.num_edges`.
- `f`: A generic function that will be passed over to [`apply_edges`](@ref). 
      Has to take as inputs the edge-materialized `xi`, `xj`, and `e` 
      (arrays or named tuples of arrays whose last dimension' size is the size of 
      a batch of edges). Its output has to be an array or a named tuple of arrays
      with the same batch size.
- `aggr`: Neighborhood aggregation operator. Use `+`, `mean`, `max`, or `min`. 

# Examples

```julia
using GraphNeuralNetworks, Flux

struct GNNConv <: GNNLayer
    W
    b
    σ
end

Flux.@functor GNNConv

function GNNConv(ch::Pair{Int,Int}, σ=identity)
    in, out = ch
    W = Flux.glorot_uniform(out, in)
    b = zeros(Float32, out)
    GNNConv(W, b, σ)
end

function (l::GNNConv)(g::GNNGraph, x::AbstractMatrix)
    message(xi, xj, e) = l.W * xj
    m̄ = propagate(message, g, +, xj=x)
    return l.σ.(m̄ .+ l.bias)
end

l = GNNConv(10 => 20)
l(g, x)
```

See also [`apply_edges`](@ref) and [`aggregate_neighbors`](@ref).
"""
function propagate end 

propagate(l, g::GNNGraph, aggr; xi=nothing, xj=nothing, e=nothing) = 
    propagate(l, g, aggr, xi, xj, e)

function propagate(l, g::GNNGraph, aggr, xi, xj, e)
    m = apply_edges(l, g, xi, xj, e) 
    m̄ = aggregate_neighbors(g, aggr, m)
    return m̄
end

## APPLY EDGES

"""
    apply_edges(f, g, xi, xj, e)
    apply_edges(f, g; [xi, xj, e])

Returns the message from node `j` to node `i` .
In the message-passing scheme, the incoming messages 
from the neighborhood of `i` will later be aggregated
in order to update the features of node `i`.

The function operates on batches of edges, therefore
`xi`, `xj`, and `e` are tensors whose last dimension
is the batch size, or can be named tuples of 
such tensors.
    
# Arguments

- `g`: A `GNNGraph`.
- `xi`: An array or a named tuple containing arrays whose last dimension's size 
        is `g.num_nodes`. It will be appropriately materialized on the
        target node of each edge (see also [`edge_index`](@ref)).
- `xj`: As `xj`, but to be materialized on edges' sources. 
- `e`: An array or a named tuple containing arrays whose last dimension's size is `g.num_edges`.
- `f`: A function that takes as inputs the edge-materialized `xi`, `xj`, and `e`.
       These are arrays (or named tuples of arrays) whose last dimension' size is the size of
       a batch of edges. The output of `f` has to be an array (or a named tuple of arrays)
       with the same batch size. 

See also [`propagate`](@ref) and [`aggregate_neighbors`](@ref).
"""
function apply_edges end 

apply_edges(l, g::GNNGraph; xi=nothing, xj=nothing, e=nothing) = 
    apply_edges(l, g, xi, xj, e)

function apply_edges(f, g::GNNGraph, xi, xj, e)
    s, t = edge_index(g)
    xi = _gather(xi, t)   # size: (D, num_nodes) -> (D, num_edges)
    xj = _gather(xj, s)
    m = f(xi, xj, e)
    return m
end

_gather(x::NamedTuple, i) = map(x -> _gather(x, i), x)
_gather(x::Tuple, i) = map(x -> _gather(x, i), x)
_gather(x::AbstractArray, i) = NNlib.gather(x, i)
_gather(x::Nothing, i) = nothing


##  AGGREGATE NEIGHBORS
@doc raw"""
    aggregate_neighbors(g::GNNGraph, aggr, m)

Given a graph `g`, edge features `m`, and an aggregation
operator `aggr` (e.g `+, min, max, mean`), returns the new node
features 
```math
\mathbf{x}_i = \square_{j \in \mathcal{N}(i)} \mathbf{m}_{j\to i}
```

Neighborhood aggregation is the second step of [`propagate`](@ref), 
where it comes after [`apply_edges`](@ref).
"""
function aggregate_neighbors(g::GNNGraph, aggr, m)
    s, t = edge_index(g)
    return _scatter(aggr, m, t)
end

_scatter(aggr, m::NamedTuple, t) = map(m -> _scatter(aggr, m, t), m)
_scatter(aggr, m::Tuple, t) = map(m -> _scatter(aggr, m, t), m)
_scatter(aggr, m::AbstractArray, t) = NNlib.scatter(aggr, m, t)



### SPECIALIZATIONS OF PROPAGATE ###
"""
    copy_xj(xi, xj, e) = xj
"""
copy_xj(xi, xj, e) = xj

"""
    copy_xi(xi, xj, e) = xi
"""
copy_xi(xi, xj, e) = xi

"""
    xi_dot_xj(xi, xj, e) = sum(xi .* xj, dims=1)
"""
xi_dot_xj(xi, xj, e) = sum(xi .* xj, dims=1)

"""
    e_mul_xj(xi, xj, e) = reshape(e, (...)) .* xj

Reshape `e` into broadcast compatible shape with `xj`
(by prepending singleton dimensions) then perform
broadcasted multiplication.
"""
function e_mul_xj(xi, xj::AbstractArray{Tj,Nj}, e::AbstractArray{Te,Ne}) where {Tj,Te, Nj, Ne}
    @assert Ne <= Nj
    e = reshape(e, ntuple(_ -> 1, Nj-Ne)..., size(e)...)
    return e .* xj
end

function propagate(::typeof(copy_xj), g::GNNGraph, ::typeof(+), xi, xj::AbstractMatrix, e)
    A = adjacency_matrix(g, weighted=false)
    return xj * A
end

# for weighted convolution
function propagate(::typeof(e_mul_xj), g::GNNGraph, ::typeof(+), xi, xj::AbstractMatrix, e::AbstractVector)
    s, t = edge_index(g)
    g = GNNGraph((s, t, e); g.num_nodes)
    A = adjacency_matrix(g, weighted=true)
    return xj * A
end



## avoid the fast path on gpu until we have better cuda support
function propagate(::typeof(copy_xj), g::GNNGraph{<:Union{COO_T,SPARSE_T}}, ::typeof(+), xi, xj::AnyCuMatrix, e)
    propagate((xi,xj,e)->copy_xj(xi,xj,e), g, +, xi, xj, e)
end

# function propagate(::typeof(copy_xj), g::GNNGraph, ::typeof(mean), xi, xj::AbstractMatrix, e)
#     A = adjacency_matrix(g, weigthed=false)
#     D = compute_degree(A)
#     return xj * A * D
# end

# # Zygote bug. Error with sparse matrix without nograd
# compute_degree(A) = Diagonal(1f0 ./ vec(sum(A; dims=2)))

# Flux.Zygote.@nograd compute_degree

