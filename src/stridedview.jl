const FN = typeof(identity)
const FC = typeof(conj)
const FA = typeof(adjoint)
const FT = typeof(transpose)

# StridedView
struct StridedView{T,N,A<:DenseArray{T},F<:Union{FN,FC,FA,FT}} <: DenseArray{T,N}
    parent::A
    size::NTuple{N,Int}
    strides::NTuple{N,Int}
    offset::Int
    op::F
end

StridedView(a::A, size::NTuple{N,Int}, strides::NTuple{N,Int}, offset::Int, op::F = identity) where {T,N,A<:DenseArray{T},F<:Union{FN,FC,FA,FT}} = StridedView{T,N,A,F}(a, size, strides, offset, op)

StridedView(a::StridedArray) = StridedView(parent(a), size(a), strides(a), offset(a), identity)

offset(a::DenseArray) = 0
offset(a::SubArray) = Base.first_index(a) - 1
offset(a::Base.ReshapedArray) = 0
# if VERSION >= v"0.7-"
#     offset(a::ReinterpretedArray) = 0
# end

# Methods for StridedView
Base.parent(a::StridedView) = a.parent
Base.size(a::StridedView) = a.size
Base.strides(a::StridedView) = a.strides
Base.stride(a::StridedView, n::Int) = a.strides[n]
offset(a::StridedView) = a.offset
Base.first_index(a::StridedView) = a.offset + 1

Base.IndexStyle(::Type{<:StridedView}) = Base.IndexCartesian()

# Indexing with N integer arguments
@inline function Base.getindex(a::StridedView{<:Any,N}, I::Vararg{Int,N}) where {N}
    @boundscheck checkbounds(a, I...)
    @inbounds r = a.op(a.parent[a.offset+_computeind(I, a.strides)])
    return r
end
@inline function Base.setindex!(a::StridedView{<:Any,N}, v, I::Vararg{Int,N}) where {N}
    @boundscheck checkbounds(a, I...)
    @inbounds a.parent[a.offset+_computeind(I, a.strides)] = a.op(v)
    return a
end

# ParentIndex: index directly into parent array
struct ParentIndex
    i::Int
end

@propagate_inbounds @inline Base.getindex(a::StridedView, I::ParentIndex) = a.op(getindex(a.parent, I.i))
@propagate_inbounds @inline Base.setindex!(a::StridedView, v, I::ParentIndex) = (setindex!(a.parent, a.op(v), I.i); return a)

Base.similar(a::StridedView, ::Type{T}, dims::NTuple{N,Int}) where {N,T}  = StridedView(similar(a.parent, T, dims))
Base.copy(a::StridedView) = copy!(similar(a), a)

# Specialized methods for `StridedView` which produce views/share data
Base.conj(a::StridedView{<:Real}) = a
Base.conj(a::StridedView{T,N,A,FN}) where {T,N,A} = StridedView{T,N,A,FC}(a.parent, a.size, a.strides, a.offset, conj)
Base.conj(a::StridedView{T,N,A,FC}) where {T,N,A} = StridedView{T,N,A,FN}(a.parent, a.size, a.strides, a.offset, identity)
Base.conj(a::StridedView{T,N,A,FT}) where {T,N,A} = StridedView{T,N,A,FA}(a.parent, a.size, a.strides, a.offset, adjoint)
Base.conj(a::StridedView{T,N,A,FA}) where {T,N,A} = StridedView{T,N,A,FT}(a.parent, a.size, a.strides, a.offset, transpose)

function Base.permutedims(a::StridedView{<:Any,N}, p) where {N}
    (length(p) == N && TupleTools.isperm(p)) || throw(ArgumentError("Invalid permutation of length $N: $p"))
    newsize = TupleTools._permute(a.size, p)
    newstrides = TupleTools._permute(a.strides, p)
    return StridedView(a.parent, newsize, newstrides, a.offset, a.op)
end

Base.transpose(a::StridedView{<:Any,2}) = permutedims(a,(2,1))
adjoint(a::StridedView{<:Number,2}) = permutedims(conj(a),(2,1))
function adjoint(a::StridedView{<:Any,2}) # act recursively, like base
    if isa(a.f, FN)
        return permutedims(StridedView(a.parent, a.size, a.strides, a.offset, adjoint), (2,1))
    elseif isa(a.f, FC)
        return permutedims(StridedView(a.parent, a.size, a.strides, a.offset, transpose), (2,1))
    elseif isa(a.f, FA)
        return permutedims(StridedView(a.parent, a.size, a.strides, a.offset, identity), (2,1))
    else
        return permutedims(StridedView(a.parent, a.size, a.strides, a.offset, conj), (2,1))
    end
end

function Base.reshape(a::StridedView, newsize::Dims)
    if any(equalto(0), newsize)
        any(equalto(0), size(a)) || throw(DimensionMismatch())
        newstrides = _defaultstrides(newsize)
    else
        newstrides = _computereshapestrides(newsize, size(a), strides(a))
    end
    StridedView(a.parent, newsize, newstrides, a.offset, a.op)
end
_defaultstrides(sz::Tuple{}, s = 1) = ()
_defaultstrides(sz::Dims, s = 1) = (s, _defaultstrides(tail(sz), s*sz[1])...)

struct ReshapeException <: Exception
end
Base.show(io::IO, e::ReshapeException) = print(io, "Cannot produce a reshaped StridedView without allocating, try reshape(copy(array), newsize)")

# Methods based on map!
Base.copy!(dst::StridedView{<:Any,N}, src::StridedView{<:Any,N}) where {N} = map!(identity, dst, src)
Base.conj!(a::StridedView) = map!(conj, a, a)
adjoint!(dst::StridedView{<:Any,N}, src::StridedView{<:Any,N}) where {N} = copy!(dst, adjoint(src))
Base.permutedims!(dst::StridedView{<:Any,N}, src::StridedView{<:Any,N}, p) where {N} = copy!(dst, permutedims(src, p))

# Converting back to other DenseArray type:
Base.convert(T::Type{<:StridedView}, a::StridedView) = a
function Base.convert(T::Type{<:DenseArray}, a::StridedView)
    b = T(uninitialized, size(a))
    copy!(StridedView(b), a)
    return b
end
function Base.convert(::Type{Array}, a::StridedView{T}) where {T}
    b = Array{T}(uninitialized, size(a))
    copy!(StridedView(b), a)
    return b
end
Base.unsafe_convert(::Type{Ptr{T}}, a::StridedView{T}) where {T} = pointer(a.parent, a.offset+1)

const StridedMatVecView{T} = Union{StridedView{T,1},StridedView{T,2}}

@static if isdefined(LinearAlgebra, :mul!)
    import LinearAlgebra: mul!
else
    const mul! = Base.A_mul_B!
    export mul!
    Base.Ac_mul_B!(C::StridedView, A::StridedView, B::StridedView) = mul!(C, A', B)
    Base.A_mul_Bc!(C::StridedView, A::StridedView, B::StridedView) = mul!(C, A, B')
    Base.Ac_mul_Bc!(C::StridedView, A::StridedView, B::StridedView) = mul!(C, A', B')
    Base.scale!(C::StridedView{<:Number,N}, a::Number, B::StridedView{<:Number,N}) where {N} = mul!(C, a, B)
    Base.scale!(C::StridedView{<:Number,N}, A::StridedView{<:Number,N}, b::Number) where {N} = mul!(C, A, b)
end

mul!(dst::StridedView{<:Number,N}, α::Number, src::StridedView{<:Number,N}) where {N} = α == 1 ? copy!(dst, src) : map!(x->α*x, dst, src)
mul!(dst::StridedView{<:Number,N}, src::StridedView{<:Number,N}, α::Number) where {N} = α == 1 ? copy!(dst, src) : map!(x->x*α, dst, src)
axpy!(a::Number, X::StridedView{<:Number,N}, Y::StridedView{<:Number,N}) where {N} = a == 1 ? map!(+, Y, X, Y) : map!((x,y)->(a*x+y), Y, X, Y)
axpby!(a::Number, X::StridedView{<:Number,N}, b::Number, Y::StridedView{<:Number,N}) where {N} = b == 1 ? axpy!(a, X, Y) : map!((x,y)->(a*x+b*y), Y, X, Y)

function mul!(C::StridedView{<:Any,2}, A::StridedView{<:Any,2}, B::StridedView{<:Any,2})
    if C.op == conj
        if stride(C,1) < stride(C,2)
            _mul!(conj(C), conj(A), conj(B))
        else
            _mul!(C', B', A')
        end
    elseif stride(C,1) > stride(C,2)
        _mul!(transpose(C), transpose(B), transpose(A))
    else
        _mul!(C, A, B)
    end
    return C
end

_mul!(C::StridedView{<:Any,2}, A::StridedView{<:Any,2}, B::StridedView{<:Any,2}) = __mul!(C, A, B)
function __mul!(C::StridedView{<:Any,2}, A::StridedView{<:Any,2}, B::StridedView{<:Any,2})
    if stride(A,1) < stride(A,2) && stride(B,1) < stride(B,2)
        LinearAlgebra.generic_matmatmul!(C,'N','N',A,B)
    elseif stride(A,1) < stride(A,2)
        LinearAlgebra.generic_matmatmul!(C,'N','T',A,transpose(B))
    elseif stride(B,1) < stride(B,2)
        LinearAlgebra.generic_matmatmul!(C,'T','N',transpose(A),B)
    else
        LinearAlgebra.generic_matmatmul!(C,'T','T',transpose(A),transpose(B))
    end
    return C
end
function _mul!(C::StridedView{T,2}, A::StridedView{T,2}, B::StridedView{T,2}) where {T<:LinearAlgebra.BlasFloat}
    if !(any(equalto(1), strides(A)) && any(equalto(1), strides(B)) && any(equalto(1), strides(C)))
        return __mul!(C,A,B)
    end
    if A.op == identity
        if stride(A,1) == 1
            A2 = A
            cA = 'N'
        else
            A2 = transpose(A)
            cA = 'T'
        end
    else
        if stride(A,1) != 1
            A2 = A'
            cA = 'C'
        else
            return LinearAlgebra.generic_matmatmul!(C,'N','N',A,B)
        end
    end
    if B.op == identity
        if stride(B,1) == 1
            B2 = B
            cB = 'N'
        else
            B2 = transpose(B)
            cB = 'T'
        end
    else
        if stride(B,1) != 1
            B2 = B'
            cB = 'C'
        else
            return LinearAlgebra.generic_matmatmul!(C,'N','N',A,B)
        end
    end
    LinearAlgebra.gemm_wrapper!(C,cA,cB,A2,B2)
end

# Auxiliary routines
@inline _computeind(indices::Tuple{}, strides::Tuple{}) = 1
@inline _computeind(indices::NTuple{N,Int}, strides::NTuple{N,Int}) where {N} = (indices[1]-1)*strides[1] + _computeind(tail(indices), tail(strides))

_computereshapestrides(newsize::Tuple{}, oldsize::Tuple{}, strides::Tuple{}) = ()
function _computereshapestrides(newsize::Tuple{}, oldsize::Dims{N}, strides::Dims{N}) where {N}
    all(equalto(1), oldsize) || throw(DimensionMismatch())
    return ()
end
function _computereshapestrides(newsize::Dims, oldsize::Tuple{}, strides::Tuple{})
    all(equalto(1), newsize)
    return map(n->1, newsize)
end
function _computereshapestrides(newsize::Dims{1}, oldsize::Dims{1}, strides::Dims{1})
    newsize[1] == oldsize[1] || throw(DimensionMismatch())
    return (strides[1],)
end
function _computereshapestrides(newsize::Dims, oldsize::Dims{1}, strides::Dims{1})
    newsize[1] == 1 && return (strides[1], _computereshapestrides(tail(newsize), oldsize, strides)...)

    if newsize[1] <= oldsize[1]
        d,r = divrem(oldsize[1], newsize[1])
        r == 0 || throw(ReshapeException())

        return (strides[1], _computereshapestrides(tail(newsize), (d,), (newsize[1]*strides[1],))...)
    else
        throw(DimensionMismatch())
    end
end

function _computereshapestrides(newsize::Dims, oldsize::Dims{N}, strides::Dims{N}) where {N}
    newsize[1] == 1 && return (strides[1], _computereshapestrides(tail(newsize), oldsize, strides)...)
    oldsize[1] == 1 && return _computereshapestrides(newsize, tail(oldsize), tail(strides))

    d,r = divrem(oldsize[1], newsize[1])
    if r == 0
        return (strides[1], _computereshapestrides(tail(newsize), (d, tail(oldsize)...), (newsize[1]*strides[1], tail(strides)...))...)
    else
        if oldsize[1]*strides[1] == strides[2]
            return _computereshapestrides(newsize, (oldsize[1]*oldsize[2], TupleTools.tail2(oldsize)...), (strides[1], TupleTools.tail2(strides)...))
        else
            throw(ReshapeException())
        end
    end
end
