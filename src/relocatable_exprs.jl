# We will need to detect new function bodies, compare function bodies
# to see if they've changed, etc.  This has to be done "blind" to the
# line numbers at which the functions are defined.
#
# Now, we could just discard line numbers from expressions, but that
# would have a very negative effect on the quality of backtraces. So
# we keep them, but introduce machinery to compare expressions without
# concern for line numbers.
#
# To reduce the performance overhead of this package, we try to
# achieve this goal with minimal copying of data.

"""
A `RelocatableExpr` is exactly like an `Expr` except that comparisons
between `RelocatableExpr`s ignore line numbering information.
"""
mutable struct RelocatableExpr
    head::Symbol
    args::Vector{Any}
    typ::Any

    RelocatableExpr(head::Symbol, args::Vector{Any}) = new(head, args)
    RelocatableExpr(head::Symbol, args...) = new(head, [args...])
end

# Works in-place and hence is unsafe. Only for internal use.
Base.convert(::Type{RelocatableExpr}, ex::Expr) = relocatable!(ex)

function relocatable!(ex::Expr)
    rex = RelocatableExpr(ex.head, relocatable!(ex.args))
    rex.typ = ex.typ
    rex
end

function relocatable!(args::Vector{Any})
    for (i, a) in enumerate(args)
        if isa(a, Expr)
            args[i] = relocatable!(a::Expr)
        end   # do we need to worry about QuoteNodes?
    end
    args
end

function Base.convert(::Type{Expr}, rex::RelocatableExpr)
    # This makes a copy. Used for `eval`, where we don't want to
    # mutate the cached represetation.
    ex = Expr(rex.head)
    ex.args = Base.copy_exprargs(rex.args)
    if isdefined(rex, :typ)
        ex.typ = rex.typ
    end
    ex
end
Base.copy_exprs(rex::RelocatableExpr) = convert(Expr, rex)

# Implement the required comparison functions. `hash` is needed for Dicts.
function Base.:(==)(a::RelocatableExpr, b::RelocatableExpr)
    a.head == b.head && isequal(LineSkippingIterator(a.args), LineSkippingIterator(b.args))
end

const hashrex_seed = UInt == UInt64 ? 0x7c4568b6e99c82d9 : 0xb9c82fd8
Base.hash(x::RelocatableExpr, h::UInt) = hash(LineSkippingIterator(x.args),
                                              hash(x.head, h + hashrex_seed))

# We could just collect all the non-line statements to a Vector, but
# doing things in-place will be more efficient.

struct LineSkippingIterator
    args::Vector{Any}
end

Base.start(iter::LineSkippingIterator) = skip_to_nonline(iter.args, 1)
Base.done(iter::LineSkippingIterator, i) = i > length(iter.args)
Base.next(iter::LineSkippingIterator, i) = (iter.args[i], skip_to_nonline(iter.args, i+1))

function skip_to_nonline(args, i)
    while true
        i > length(args) && return i
        ex = args[i]
        if isa(ex, RelocatableExpr) && (ex::RelocatableExpr).head == :line
            i += 1
        elseif isa(ex, LineNumberNode)
            i += 1
        else
            return i
        end
    end
end

function Base.isequal(itera::LineSkippingIterator, iterb::LineSkippingIterator)
    # We could use `zip` here except that we want to insist that the
    # iterators also have the same length.
    ia, ib = start(itera), start(iterb)
    while !done(itera, ia) && !done(iterb, ib)
        vala, ia = next(itera, ia)
        valb, ib = next(iterb, ib)
        if isa(vala, RelocatableExpr) && isa(valb, RelocatableExpr)
            vala = vala::RelocatableExpr
            valb = valb::RelocatableExpr
            vala.head == valb.head || return false
            isequal(LineSkippingIterator(vala.args), LineSkippingIterator(valb.args)) || return false
        else
            isequal(vala, valb) || return false
        end
    end
    done(itera, ia) && done(iterb, ib)
end

const hashlsi_seed = UInt == UInt64 ? 0x533cb920dedccdae : 0x2667c89b
function Base.hash(iter::LineSkippingIterator, h::UInt)
    h += hashlsi_seed
    for x in iter
        h += hash(x, h)
    end
    h
end
