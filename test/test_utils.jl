using ChainRulesTestUtils, FiniteDifferences, Zygote, Adapt, CUDA
CUDA.allowscalar(false)

# global GRAPH_T = :coo
# global TEST_GPU = true

const rule_config = Zygote.ZygoteRuleConfig()

# Using this until https://github.com/JuliaDiff/FiniteDifferences.jl/issues/188 is fixed
function FiniteDifferences.to_vec(x::Integer)
    Integer_from_vec(v) = x
    return Int[x], Integer_from_vec
end

function test_layer(l, g::GNNGraph; atol = 1e-6, rtol = 1e-5,
                                 exclude_grad_fields = [],
                                 broken_grad_fields =[],
                                 verbose = false,
                                 test_gpu = TEST_GPU,
                                 outsize = nothing,
                                 outtype = :node,
                                )

    # TODO these give errors, probably some bugs in ChainRulesTestUtils
    # test_rrule(rule_config, x -> l(g, x), x; rrule_f=rrule_via_ad, check_inferred=false)
    # test_rrule(rule_config, l -> l(g, x), l; rrule_f=rrule_via_ad, check_inferred=false)

    isnothing(node_features(g)) && error("Plese add node data to the input graph")
    fdm = central_fdm(5, 1)
    
    x = node_features(g)
    e = edge_features(g)
    use_edge_feat = !isnothing(e)

    x64, e64, l64, g64 = to64.([x, e, l, g]) # needed for accurate FiniteDifferences' grad
    xgpu, egpu, lgpu, ggpu = gpu.([x, e, l, g]) 

    f(l, g::GNNGraph) = l(g)
    f(l, g::GNNGraph, x, e) = use_edge_feat ? l(g, x, e) : l(g, x)
    
    loss(l, g::GNNGraph) = if outtype == :node
                                sum(node_features(f(l, g))) 
                            elseif outtype == :edge
                                sum(edge_features(f(l, g)))         
                            elseif outtype == :graph
                                sum(graph_features(f(l, g))) 
                            elseif outtype == :node_edge
                                gnew = f(l, g)
                                sum(node_features(gnew)) + sum(edge_features(gnew))
                            end

    function loss(l, g::GNNGraph, x, e) 
        y = f(l, g, x, e)
        if outtype == :node_edge
            return sum(y[1]) + sum(y[2])
        else 
            return sum(y)
        end
    end
    
    
    # TEST OUTPUT
    y = f(l, g, x, e)
    if outtype == :node_edge
        @assert y isa Tuple
        @test eltype(y[1]) == eltype(x)
        @test eltype(y[2]) == eltype(e)
        @test all(isfinite, y[1])
        @test all(isfinite, y[2])
        if !isnothing(outsize)
            @test size(y[1]) == outsize[1]
            @test size(y[2]) == outsize[2]
        end
    else
        @test eltype(y) == eltype(x)
        @test all(isfinite, y)
        if !isnothing(outsize)
            @test size(y) == outsize
        end
    end

    # test same output on different graph formats
    gcoo = GNNGraph(g, graph_type=:coo)
    ycoo = f(l, gcoo, x, e)
    if outtype == :node_edge
        @test ycoo[1] ≈ y[1]
        @test ycoo[2] ≈ y[2]
    else
        @test ycoo ≈ y
    end

    g′ = f(l, g)
    if outtype == :node
        @test g′.ndata.x ≈ y
    elseif outtype == :edge
        @test g′.edata.e ≈ y    
    elseif outtype == :graph
        @test g′.gdata.u ≈ y
    elseif outtype == :node_edge
        @test g′.ndata.x ≈ y[1]
        @test g′.edata.e ≈ y[2]
    else
        @error "wrong outtype $outtype"
    end
    if test_gpu
        ygpu = f(lgpu, ggpu, xgpu, egpu)
        if outtype == :node_edge
            @test ygpu[1] isa CuArray 
            @test eltype(ygpu[1]) == eltype(xgpu)
            @test Array(ygpu[1]) ≈ y[1]
            @test ygpu[2] isa CuArray 
            @test eltype(ygpu[2]) == eltype(xgpu)
            @test Array(ygpu[2]) ≈ y[2]
        else
            @test ygpu isa CuArray 
            @test eltype(ygpu) == eltype(xgpu)
            @test Array(ygpu) ≈ y
        end
    end


    # TEST x INPUT GRADIENT
    x̄  = gradient(x -> loss(l, g, x, e), x)[1]
    x̄_fd = FiniteDifferences.grad(fdm, x64 -> loss(l64, g64, x64, e64), x64)[1]
    @test eltype(x̄) == eltype(x)
    @test x̄ ≈ x̄_fd    atol=atol rtol=rtol

    if test_gpu
        x̄gpu  = gradient(xgpu -> loss(lgpu, ggpu, xgpu, egpu), xgpu)[1]
        @test x̄gpu isa CuArray 
        @test eltype(x̄gpu) == eltype(x)
        @test Array(x̄gpu) ≈ x̄   atol=atol rtol=rtol
    end


    # TEST e INPUT GRADIENT
    if e !== nothing
        ē  = gradient(e -> loss(l, g, x, e), e)[1]
        ē_fd = FiniteDifferences.grad(fdm, e64 -> loss(l64, g64, x64, e64), e64)[1]
        @test eltype(ē) == eltype(e)
        @test ē ≈ ē_fd    atol=atol rtol=rtol

        if test_gpu
            ēgpu  = gradient(egpu -> loss(lgpu, ggpu, xgpu, egpu), egpu)[1]
            @test ēgpu isa CuArray 
            @test eltype(ēgpu) == eltype(ē)
            @test Array(ēgpu) ≈ ē   atol=atol rtol=rtol
        end
    end


    # TEST LAYER GRADIENT - l(g, x, e) 
    l̄ = gradient(l -> loss(l, g, x, e), l)[1]
    l̄_fd = FiniteDifferences.grad(fdm, l64 -> loss(l64, g64, x64, e64), l64)[1]
    test_approx_structs(l, l̄, l̄_fd; atol, rtol, broken_grad_fields, exclude_grad_fields, verbose)

    if test_gpu
        l̄gpu = gradient(lgpu -> loss(lgpu, ggpu, xgpu, egpu), lgpu)[1]
        test_approx_structs(lgpu, l̄gpu, l̄; atol, rtol, broken_grad_fields, exclude_grad_fields, verbose)
    end

    # TEST LAYER GRADIENT - l(g)
    l̄ = gradient(l -> loss(l, g), l)[1]
    test_approx_structs(l, l̄, l̄_fd; atol, rtol, broken_grad_fields, exclude_grad_fields, verbose)

    return true
end

function test_approx_structs(l, l̄, l̄2; atol=1e-5, rtol=1e-5, 
            broken_grad_fields=[],
            exclude_grad_fields=[],
            verbose=false)

    l̄ = l̄ isa Base.RefValue ? l̄[] : l̄           # Zygote wraps gradient of mutables in RefValue 
    l̄2 = l̄2 isa Base.RefValue ? l̄2[] : l̄2           # Zygote wraps gradient of mutables in RefValue 

    for f in fieldnames(typeof(l))
        f ∈ exclude_grad_fields && continue
        f̄, f̄2 = getfield(l̄, f), getfield(l̄2, f)
        x = getfield(l, f)
        if verbose
            println()
            @show f x f̄ f̄2
        end
        if isnothing(f̄)
            verbose && println("A")
            @test !(f̄2 isa AbstractArray) || isapprox(f̄2, fill!(similar(f̄2), 0); atol=atol, rtol=rtol)
        elseif f̄ isa Union{AbstractArray, Number}
            verbose && println("B")
            @test eltype(f̄) == eltype(x)
            if x isa CuArray
                @test f̄ isa CuArray
                f̄ = Array(f̄)
            end
            if f ∈ broken_grad_fields
                @test_broken f̄ ≈ f̄2   atol=atol rtol=rtol
            else
                @test f̄ ≈ f̄2   atol=atol rtol=rtol
            end
        else
            verbose && println("C")
            test_approx_structs(x, f̄, f̄2; exclude_grad_fields, broken_grad_fields, verbose)
        end
    end
    return true
end


"""
    to32(m)

Convert the `eltype` of model's parameters to `Float32` or `Int32`.
"""
function to32(m)
    f(x::AbstractArray) = eltype(x) <: Integer ? adapt(Int32, x) : adapt(Float32, x)
    f(x::Number) = typeof(x) <: Integer ? adapt(Int32, x) : adapt(Float32, x)
    f(x) = adapt(Float32, x)
    return fmap(f, m)
end

"""
    to64(m)

Convert the `eltype` of model's parameters to `Float64` or `Int64`.
"""
function to64(m)
    f(x::AbstractArray) = eltype(x) <: Integer ? adapt(Int64, x) : adapt(Float64, x)
    f(x::Number) = typeof(x) <: Integer ? adapt(Int64, x) : adapt(Float64, x)
    f(x) = adapt(Float64, x)
    return fmap(f, m)
end
