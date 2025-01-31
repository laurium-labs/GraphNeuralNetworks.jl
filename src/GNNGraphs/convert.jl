### CONVERT_TO_COO REPRESENTATION ########

function to_coo(coo::COO_T; dir=:out, num_nodes=nothing, weighted=true)
    s, t, val = coo   
    num_nodes = isnothing(num_nodes) ? max(maximum(s), maximum(t)) : num_nodes 
    @assert isnothing(val) || length(val) == length(s)
    @assert length(s) == length(t)
    if !isempty(s)
        @assert min(minimum(s), minimum(t)) >= 1 
        @assert max(maximum(s), maximum(t)) <= num_nodes 
    end
    num_edges = length(s)
    if !weighted
        coo = (s, t, nothing)
    end
    return coo, num_nodes, num_edges
end

function to_coo(A::SPARSE_T; dir=:out, num_nodes=nothing, weighted=true)
    s, t, v = findnz(A)
    if dir == :in
        s, t = t, s
    end
    num_nodes = isnothing(num_nodes) ? size(A, 1) : num_nodes 
    num_edges = length(s)
    if !weighted
        v = nothing
    end
    return (s, t, v), num_nodes, num_edges
end

function to_coo(A::ADJMAT_T; dir=:out, num_nodes=nothing, weighted=true)
    nz = findall(!=(0), A) # vec of cartesian indexes
    s, t = ntuple(i -> map(t->t[i], nz), 2)
    v = A[nz] 
    if dir == :in
        s, t = t, s
    end
    num_nodes = isnothing(num_nodes) ? size(A, 1) : num_nodes 
    num_edges = length(s)
    if !weighted
        v = nothing
    end
    return (s, t, v), num_nodes, num_edges
end

function to_coo(adj_list::ADJLIST_T; dir=:out, num_nodes=nothing, weighted=true)
    @assert dir ∈ [:out, :in]
    num_nodes = length(adj_list)
    num_edges = sum(length.(adj_list))
    @assert num_nodes > 0
    s = similar(adj_list[1], eltype(adj_list[1]), num_edges)
    t = similar(adj_list[1], eltype(adj_list[1]), num_edges)
    e = 0
    for i in 1:num_nodes
        for j in adj_list[i]
            e += 1
            s[e] = i
            t[e] = j 
        end
    end
    @assert e == num_edges
    if dir == :in
        s, t = t, s
    end
    (s, t, nothing), num_nodes, num_edges
end

### CONVERT TO ADJACENCY MATRIX ################

### DENSE ####################

to_dense(A::AbstractSparseMatrix, x...; kws...) = to_dense(collect(A), x...; kws...)

function to_dense(A::ADJMAT_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    @assert dir ∈ [:out, :in]
    T = T === nothing ? eltype(A) : T
    num_nodes = size(A, 1)
    @assert num_nodes == size(A, 2)
    # @assert all(x -> (x == 1) || (x == 0), A)
    num_edges = numnonzeros(A)
    if dir == :in
        A = A'
    end
    if T != eltype(A)
        A = T.(A)
    end
    if !weighted
        A = map(x -> x > 0 ? T(1) : T(0), A)
    end
    return A, num_nodes, num_edges
end

function to_dense(adj_list::ADJLIST_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    @assert dir ∈ [:out, :in]
    num_nodes = length(adj_list)
    num_edges = sum(length.(adj_list))
    @assert num_nodes > 0
    T = T === nothing ? eltype(adj_list[1]) : T
    A = fill!(similar(adj_list[1], T, (num_nodes, num_nodes)), 0)
    if dir == :out
        for (i, neigs) in enumerate(adj_list)
            A[i, neigs] .= 1
        end
    else 
        for (i, neigs) in enumerate(adj_list)
            A[neigs, i] .= 1
        end
    end
    A, num_nodes, num_edges
end

function to_dense(coo::COO_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    # `dir` will be ignored since the input `coo` is always in source -> target format.
    # The output will always be a adjmat in :out format (e.g. A[i,j] denotes from i to j)
    s, t, val = coo
    n = isnothing(num_nodes) ? max(maximum(s), maximum(t)) : num_nodes
    val = isnothing(val) ? eltype(s)(1) : val
    T = T === nothing ? eltype(val) : T
    if !weighted
        val = T(1)
    end
    A = fill!(similar(s, T, (n, n)), 0)
    v = vec(A)
    idxs = s .+ n .* (t .- 1) 
    NNlib.scatter!(+, v, val, idxs)
    # A[s .+ n .* (t .- 1)] .= val # exploiting linear indexing
    return A, n, length(s)
end

### SPARSE #############

function to_sparse(A::ADJMAT_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    @assert dir ∈ [:out, :in]
    num_nodes = size(A, 1)
    @assert num_nodes == size(A, 2)
    T = T === nothing ? eltype(A) : T
    num_edges = A isa AbstractSparseMatrix ? nnz(A) : count(!=(0), A)
    if dir == :in
        A = A'
    end
    if T != eltype(A)
        A = T.(A)
    end
    if !(A isa AbstractSparseMatrix)
        A = sparse(A)
    end
    if !weighted
        A = map(x -> x > 0 ? T(1) : T(0), A)
    end
    return A, num_nodes, num_edges
end

function to_sparse(adj_list::ADJLIST_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    coo, num_nodes, num_edges = to_coo(adj_list; dir, num_nodes)
    return to_sparse(coo; num_nodes)
end

function to_sparse(coo::COO_T, T=nothing; dir=:out, num_nodes=nothing, weighted=true)
    s, t, eweight  = coo
    T = T === nothing ? (eweight === nothing ? eltype(s) : eltype(eweight)) : T
    
    if eweight === nothing || !weighted
        eweight = fill!(similar(s, T), 1)
    end

    num_nodes = isnothing(num_nodes) ? max(maximum(s), maximum(t)) : num_nodes 
    A = sparse(s, t, eweight, num_nodes, num_nodes)
    num_edges = nnz(A)
    if eltype(A) != T
        A = T.(A)
    end
    return A, num_nodes, num_edges
end

@non_differentiable to_coo(x...)
@non_differentiable to_dense(x...)
@non_differentiable to_sparse(x...)
