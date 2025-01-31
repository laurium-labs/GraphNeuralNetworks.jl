@testset "message passing" begin 
    in_channel = 10
    out_channel = 5
    num_V = 6
    num_E = 14
    T = Float32

    adj =  [0 1 0 0 0 0
            1 0 0 1 1 1
            0 0 0 0 0 1
            0 1 0 0 1 0
            0 1 0 1 0 1
            0 1 1 0 1 0]

    
    X = rand(T, in_channel, num_V)
    E = rand(T, in_channel, num_E)

    g = GNNGraph(adj, graph_type=GRAPH_T)

    @testset "propagate" begin
        function message(xi, xj, e) 
            @test xi === nothing
            @test e === nothing
            ones(T, out_channel, size(xj, 2))
        end
        
        m = propagate(message, g, +, xj=X)

        @test size(m) == (out_channel, num_V)
    end


    @testset "apply_edges" begin
        m = apply_edges(g, e=E) do xi, xj, e
                @test xi === nothing
                @test xj === nothing
                ones(out_channel, size(e, 2))
            end 

        @test m == ones(out_channel, num_E)

        # With NamedTuple input
        m = apply_edges(g, xj=(;a=X, b=2X), e=E) do xi, xj, e
                @test xi === nothing
                @test xj.b == 2*xj.a
                @test size(xj.a, 2) == size(xj.b, 2) == size(e, 2)
                ones(out_channel, size(e, 2))
            end 
    
        # NamedTuple output
        m = apply_edges(g, e=E) do xi, xj, e
            @test xi === nothing
            @test xj === nothing
            (; a=ones(out_channel, size(e, 2)))
        end 

        @test m.a == ones(out_channel, num_E)
    end

    @testset "copy_xj" begin
        
        n = 128
        A = sprand(n, n, 0.1)
        Adj = map(x -> x > 0 ? 1 : 0, A)
        X = rand(10, n)

        g = GNNGraph(A, ndata=X, graph_type=GRAPH_T)

        function spmm_copyxj_fused(g)
            propagate(
                copy_xj,
                g, +; xj=g.ndata.x
                )
        end

        function spmm_copyxj_unfused(g)
            propagate(
                (xi, xj, e) -> xj,
                g, +; xj=g.ndata.x
                )
        end

        @test spmm_copyxj_unfused(g) ≈ X * Adj
        @test spmm_copyxj_fused(g) ≈ X * Adj
    end

    @testset "e_mul_xj for weighted conv" begin
        n = 128
        A = sprand(n, n, 0.1)
        Adj = map(x -> x > 0 ? 1 : 0, A)
        X = rand(10, n)

        g = GNNGraph(A, ndata=X, edata=reshape(A.nzval, 1, :), graph_type=GRAPH_T)

        function spmm_unfused(g)
            propagate(
                (xi, xj, e) -> e .* xj , 
                g, +; xj=g.ndata.x, e=g.edata.e
                )
        end
        function spmm_fused(g)
            propagate(
                e_mul_xj,
                g, +; xj=g.ndata.x, e=vec(g.edata.e)
                )
        end

        @test spmm_unfused(g) ≈ X * A
        @test spmm_fused(g) ≈ X * A
    end
end
