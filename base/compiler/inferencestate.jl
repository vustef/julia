# This file is a part of Julia. License is MIT: https://julialang.org/license

# The type of a variable load is either a value or an UndefVarError
# (only used in abstractinterpret, doesn't appear in optimize)
struct VarState
    typ
    undef::Bool
    VarState(@nospecialize(typ), undef::Bool) = new(typ, undef)
end

"""
    const VarTable = Vector{VarState}

The extended lattice that maps local variables to inferred type represented as `AbstractLattice`.
Each index corresponds to the `id` of `SlotNumber` which identifies each local variable.
Note that `InferenceState` will maintain multiple `VarTable`s at each SSA statement
to enable flow-sensitive analysis.
"""
const VarTable = Vector{VarState}

mutable struct BitSetBoundedMinPrioritySet <: AbstractSet{Int}
    elems::BitSet
    min::Int
    # Stores whether min is exact or a lower bound
    # If exact, it is not set in elems
    min_exact::Bool
    max::Int
end

function BitSetBoundedMinPrioritySet(max::Int)
    bs = BitSet()
    bs.offset = 0
    BitSetBoundedMinPrioritySet(bs, max+1, true, max)
end

@noinline function _advance_bsbmp!(bsbmp::BitSetBoundedMinPrioritySet)
    @assert !bsbmp.min_exact
    bsbmp.min = _bits_findnext(bsbmp.elems.bits, bsbmp.min)::Int
    bsbmp.min < 0 && (bsbmp.min = bsbmp.max + 1)
    bsbmp.min_exact = true
    delete!(bsbmp.elems, bsbmp.min)
    return nothing
end

function isempty(bsbmp::BitSetBoundedMinPrioritySet)
    if bsbmp.min > bsbmp.max
        return true
    end
    bsbmp.min_exact && return false
    _advance_bsbmp!(bsbmp)
    return bsbmp.min > bsbmp.max
end

function popfirst!(bsbmp::BitSetBoundedMinPrioritySet)
    bsbmp.min_exact || _advance_bsbmp!(bsbmp)
    m = bsbmp.min
    m > bsbmp.max && throw(ArgumentError("BitSetBoundedMinPrioritySet must be non-empty"))
    bsbmp.min = m+1
    bsbmp.min_exact = false
    return m
end

function push!(bsbmp::BitSetBoundedMinPrioritySet, idx::Int)
    if idx <= bsbmp.min
        if bsbmp.min_exact && bsbmp.min < bsbmp.max && idx != bsbmp.min
            push!(bsbmp.elems, bsbmp.min)
        end
        bsbmp.min = idx
        bsbmp.min_exact = true
        return nothing
    end
    push!(bsbmp.elems, idx)
    return nothing
end

function in(idx::Int, bsbmp::BitSetBoundedMinPrioritySet)
    if bsbmp.min_exact && idx == bsbmp.min
        return true
    end
    return idx in bsbmp.elems
end

function append!(bsbmp::BitSetBoundedMinPrioritySet, itr)
    for val in itr
        push!(bsbmp, val)
    end
end

mutable struct InferenceState
    #= information about this method instance =#
    linfo::MethodInstance
    world::UInt
    mod::Module
    sptypes::Vector{Any}
    slottypes::Vector{Any}
    src::CodeInfo
    cfg::CFG

    #= intermediate states for local abstract interpretation =#
    currbb::Int
    currpc::Int
    ip::BitSet#=TODO BoundedMinPrioritySet=# # current active instruction pointers
    handler_at::Vector{Int} # current exception handler info
    ssavalue_uses::Vector{BitSet} # ssavalue sparsity and restart info
    # TODO: Could keep this sparsely by doing structural liveness analysis ahead of time.
    bb_vartables::Vector{Union{Nothing,VarTable}} # nothing if not analyzed yet
    ssavaluetypes::Vector{Any}
    stmt_edges::Vector{Union{Nothing,Vector{Any}}}
    stmt_info::Vector{CallInfo}

    #= intermediate states for interprocedural abstract interpretation =#
    pclimitations::IdSet{InferenceState} # causes of precision restrictions (LimitedAccuracy) on currpc ssavalue
    limitations::IdSet{InferenceState} # causes of precision restrictions (LimitedAccuracy) on return
    cycle_backedges::Vector{Tuple{InferenceState, Int}} # call-graph backedges connecting from callee to caller
    callers_in_cycle::Vector{InferenceState}
    dont_work_on_me::Bool
    parent::Union{Nothing, InferenceState}
    inferred::Bool # TODO move this to InferenceResult?

    #= results =#
    result::InferenceResult # remember where to put the result
    valid_worlds::WorldRange
    bestguess #::Type
    ipo_effects::Effects

    #= flags =#
    params::InferenceParams
    # Whether to restrict inference of abstract call sites to avoid excessive work
    # Set by default for toplevel frame.
    restrict_abstract_call_sites::Bool
    cached::Bool # TODO move this to InferenceResult?

    # The interpreter that created this inference state. Not looked at by
    # NativeInterpreter. But other interpreters may use this to detect cycles
    interp::AbstractInterpreter

    # src is assumed to be a newly-allocated CodeInfo, that can be modified in-place to contain intermediate results
    function InferenceState(result::InferenceResult, src::CodeInfo, cache::Symbol,
        interp::AbstractInterpreter)
        linfo = result.linfo
        world = get_world_counter(interp)
        def = linfo.def
        mod = isa(def, Method) ? def.module : def
        sptypes = sptypes_from_meth_instance(linfo)
        code = src.code::Vector{Any}
        cfg = compute_basic_blocks(code)

        currbb = currpc = 1
        ip = BitSet(1) # TODO BitSetBoundedMinPrioritySet(1)
        handler_at = compute_trycatch(code, BitSet())
        nssavalues = src.ssavaluetypes::Int
        ssavalue_uses = find_ssavalue_uses(code, nssavalues)
        nstmts = length(code)
        stmt_edges = Union{Nothing, Vector{Any}}[ nothing for i = 1:nstmts ]
        stmt_info = CallInfo[ NoCallInfo() for i = 1:nstmts ]

        nslots = length(src.slotflags)
        slottypes = Vector{Any}(undef, nslots)
        bb_vartables = Union{Nothing,VarTable}[ nothing for i = 1:length(cfg.blocks) ]
        bb_vartable1 = bb_vartables[1] = VarTable(undef, nslots)
        argtypes = result.argtypes
        nargtypes = length(argtypes)
        for i = 1:nslots
            argtyp = (i > nargtypes) ? Bottom : argtypes[i]
            slottypes[i] = argtyp
            bb_vartable1[i] = VarState(argtyp, i > nargtypes)
        end
        src.ssavaluetypes = ssavaluetypes = Any[ NOT_FOUND for i = 1:nssavalues ]

        pclimitations = IdSet{InferenceState}()
        limitations = IdSet{InferenceState}()
        cycle_backedges = Vector{Tuple{InferenceState,Int}}()
        callers_in_cycle = Vector{InferenceState}()
        dont_work_on_me = false
        parent = nothing
        inferred = false

        valid_worlds = WorldRange(src.min_world, src.max_world == typemax(UInt) ? get_world_counter() : src.max_world)
        bestguess = Bottom
        # TODO: Currently, any :inbounds declaration taints consistency,
        #       because we cannot be guaranteed whether or not boundschecks
        #       will be eliminated and if they are, we cannot be guaranteed
        #       that no undefined behavior will occur (the effects assumptions
        #       are stronger than the inbounds assumptions, since the latter
        #       requires dynamic reachability, while the former is global).
        inbounds = inbounds_option()
        noinbounds = inbounds === :on || (inbounds === :default && !any_inbounds(code))
        consistent = noinbounds ? ALWAYS_TRUE : ALWAYS_FALSE
        ipo_effects = Effects(EFFECTS_TOTAL; consistent, noinbounds)

        params = InferenceParams(interp)
        restrict_abstract_call_sites = isa(linfo.def, Module)
        @assert cache === :no || cache === :local || cache === :global
        cached = cache === :global

        frame = new(
            linfo, world, mod, sptypes, slottypes, src, cfg,
            currbb, currpc, ip, handler_at, ssavalue_uses, bb_vartables, ssavaluetypes, stmt_edges, stmt_info,
            pclimitations, limitations, cycle_backedges, callers_in_cycle, dont_work_on_me, parent, inferred,
            result, valid_worlds, bestguess, ipo_effects,
            params, restrict_abstract_call_sites, cached,
            interp)

        # some more setups
        params.unoptimize_throw_blocks && mark_throw_blocks!(src, handler_at)
        result.result = frame
        cache !== :no && push!(get_inference_cache(interp), result)

        return frame
    end
end

Effects(state::InferenceState) = state.ipo_effects

function merge_effects!(::AbstractInterpreter, caller::InferenceState, effects::Effects)
    caller.ipo_effects = merge_effects(caller.ipo_effects, effects)
end

merge_effects!(interp::AbstractInterpreter, caller::InferenceState, callee::InferenceState) =
    merge_effects!(interp, caller, Effects(callee))
merge_effects!(interp::AbstractInterpreter, caller::IRCode, effects::Effects) = nothing

is_effect_overridden(sv::InferenceState, effect::Symbol) = is_effect_overridden(sv.linfo, effect)
function is_effect_overridden(linfo::MethodInstance, effect::Symbol)
    def = linfo.def
    return isa(def, Method) && is_effect_overridden(def, effect)
end
is_effect_overridden(method::Method, effect::Symbol) = is_effect_overridden(decode_effects_override(method.purity), effect)
is_effect_overridden(override::EffectsOverride, effect::Symbol) = getfield(override, effect)

add_remark!(::AbstractInterpreter, sv::Union{InferenceState, IRCode}, remark) = return

function bail_out_toplevel_call(::AbstractInterpreter, @nospecialize(callsig), sv::Union{InferenceState, IRCode})
    return isa(sv, InferenceState) && sv.restrict_abstract_call_sites && !isdispatchtuple(callsig)
end
function bail_out_call(::AbstractInterpreter, @nospecialize(rt), sv::Union{InferenceState, IRCode})
    return rt === Any
end
function bail_out_apply(::AbstractInterpreter, @nospecialize(rt), sv::Union{InferenceState, IRCode})
    return rt === Any
end

function any_inbounds(code::Vector{Any})
    for i = 1:length(code)
        stmt = code[i]
        if isexpr(stmt, :inbounds)
            return true
        end
    end
    return false
end

was_reached(sv::InferenceState, pc::Int) = sv.ssavaluetypes[pc] !== NOT_FOUND

function compute_trycatch(code::Vector{Any}, ip::BitSet)
    # The goal initially is to record the frame like this for the state at exit:
    # 1: (enter 3) # == 0
    # 3: (expr)    # == 1
    # 3: (leave 1) # == 1
    # 4: (expr)    # == 0
    # then we can find all trys by walking backwards from :enter statements,
    # and all catches by looking at the statement after the :enter
    n = length(code)
    empty!(ip)
    ip.offset = 0 # for _bits_findnext
    push!(ip, n + 1)
    handler_at = fill(0, n)

    # start from all :enter statements and record the location of the try
    for pc = 1:n
        stmt = code[pc]
        if isexpr(stmt, :enter)
            l = stmt.args[1]::Int
            handler_at[pc + 1] = pc
            push!(ip, pc + 1)
            handler_at[l] = pc
            push!(ip, l)
        end
    end

    # now forward those marks to all :leave statements
    pc´´ = 0
    while true
        # make progress on the active ip set
        pc = _bits_findnext(ip.bits, pc´´)::Int
        pc > n && break
        while true # inner loop optimizes the common case where it can run straight from pc to pc + 1
            pc´ = pc + 1 # next program-counter (after executing instruction)
            if pc == pc´´
                pc´´ = pc´
            end
            delete!(ip, pc)
            cur_hand = handler_at[pc]
            @assert cur_hand != 0 "unbalanced try/catch"
            stmt = code[pc]
            if isa(stmt, GotoNode)
                pc´ = stmt.label
            elseif isa(stmt, GotoIfNot)
                l = stmt.dest::Int
                if handler_at[l] != cur_hand
                    @assert handler_at[l] == 0 "unbalanced try/catch"
                    handler_at[l] = cur_hand
                    if l < pc´´
                        pc´´ = l
                    end
                    push!(ip, l)
                end
            elseif isa(stmt, ReturnNode)
                @assert !isdefined(stmt, :val) "unbalanced try/catch"
                break
            elseif isa(stmt, Expr)
                head = stmt.head
                if head === :enter
                    cur_hand = pc
                elseif head === :leave
                    l = stmt.args[1]::Int
                    for i = 1:l
                        cur_hand = handler_at[cur_hand]
                    end
                    cur_hand == 0 && break
                end
            end

            pc´ > n && break # can't proceed with the fast-path fall-through
            if handler_at[pc´] != cur_hand
                @assert handler_at[pc´] == 0 "unbalanced try/catch"
                handler_at[pc´] = cur_hand
            elseif !in(pc´, ip)
                break  # already visited
            end
            pc = pc´
        end
    end

    @assert first(ip) == n + 1
    return handler_at
end

"""
    Iterate through all callers of the given InferenceState in the abstract
    interpretation stack (including the given InferenceState itself), vising
    children before their parents (i.e. ascending the tree from the given
    InferenceState). Note that cycles may be visited in any order.
"""
struct InfStackUnwind
    inf::InferenceState
end
iterate(unw::InfStackUnwind) = (unw.inf, (unw.inf, 0))
function iterate(unw::InfStackUnwind, (infstate, cyclei)::Tuple{InferenceState, Int})
    # iterate through the cycle before walking to the parent
    if cyclei < length(infstate.callers_in_cycle)
        cyclei += 1
        infstate = infstate.callers_in_cycle[cyclei]
    else
        cyclei = 0
        infstate = infstate.parent
    end
    infstate === nothing && return nothing
    (infstate::InferenceState, (infstate, cyclei))
end

function InferenceState(result::InferenceResult, cache::Symbol, interp::AbstractInterpreter)
    # prepare an InferenceState object for inferring lambda
    src = retrieve_code_info(result.linfo)
    src === nothing && return nothing
    validate_code_in_debug_mode(result.linfo, src, "lowered")
    return InferenceState(result, src, cache, interp)
end

function sptypes_from_meth_instance(linfo::MethodInstance)
    toplevel = !isa(linfo.def, Method)
    if !toplevel && isempty(linfo.sparam_vals) && isa(linfo.def.sig, UnionAll)
        # linfo is unspecialized
        sp = Any[]
        sig = linfo.def.sig
        while isa(sig, UnionAll)
            push!(sp, sig.var)
            sig = sig.body
        end
    else
        sp = collect(Any, linfo.sparam_vals)
    end
    for i = 1:length(sp)
        v = sp[i]
        if v isa TypeVar
            temp = linfo.def.sig
            for j = 1:i-1
                temp = temp.body
            end
            vᵢ = (temp::UnionAll).var
            while temp isa UnionAll
                temp = temp.body
            end
            sigtypes = (temp::DataType).parameters
            for j = 1:length(sigtypes)
                sⱼ = sigtypes[j]
                if isType(sⱼ) && sⱼ.parameters[1] === vᵢ
                    # if this parameter came from `arg::Type{T}`,
                    # then `arg` is more precise than `Type{T} where lb<:T<:ub`
                    ty = fieldtype(linfo.specTypes, j)
                    @goto ty_computed
                end
            end
            ub = v.ub
            while ub isa TypeVar
                ub = ub.ub
            end
            if has_free_typevars(ub)
                ub = Any
            end
            lb = v.lb
            while lb isa TypeVar
                lb = lb.lb
            end
            if has_free_typevars(lb)
                lb = Bottom
            end
            if Any <: ub && lb <: Bottom
                ty = Any
            else
                tv = TypeVar(v.name, lb, ub)
                ty = UnionAll(tv, Type{tv})
            end
        elseif isvarargtype(v)
            ty = Int
        else
            ty = Const(v)
        end
        @label ty_computed
        sp[i] = ty
    end
    return sp
end

_topmod(sv::InferenceState) = _topmod(sv.mod)

# work towards converging the valid age range for sv
function update_valid_age!(sv::InferenceState, worlds::WorldRange)
    sv.valid_worlds = intersect(worlds, sv.valid_worlds)
    @assert(sv.world in sv.valid_worlds, "invalid age range update")
    nothing
end

update_valid_age!(edge::InferenceState, sv::InferenceState) = update_valid_age!(sv, edge.valid_worlds)

function record_ssa_assign!(𝕃ᵢ::AbstractLattice, ssa_id::Int, @nospecialize(new), frame::InferenceState)
    ssavaluetypes = frame.ssavaluetypes
    old = ssavaluetypes[ssa_id]
    if old === NOT_FOUND || !⊑(𝕃ᵢ, new, old)
        # typically, we expect that old ⊑ new (that output information only
        # gets less precise with worse input information), but to actually
        # guarantee convergence we need to use tmerge here to ensure that is true
        ssavaluetypes[ssa_id] = old === NOT_FOUND ? new : tmerge(𝕃ᵢ, old, new)
        W = frame.ip
        for r in frame.ssavalue_uses[ssa_id]
            if was_reached(frame, r)
                usebb = block_for_inst(frame.cfg, r)
                # We're guaranteed to visit the statement if it's in the current
                # basic block, since SSA values can only ever appear after their
                # def.
                if usebb != frame.currbb
                    push!(W, usebb)
                end
            end
        end
    end
    return nothing
end

function add_cycle_backedge!(caller::InferenceState, frame::InferenceState, currpc::Int)
    update_valid_age!(frame, caller)
    backedge = (caller, currpc)
    contains_is(frame.cycle_backedges, backedge) || push!(frame.cycle_backedges, backedge)
    add_backedge!(caller, frame.linfo)
    return frame
end

# temporarily accumulate our edges to later add as backedges in the callee
function add_backedge!(caller::InferenceState, li::MethodInstance)
    edges = get_stmt_edges!(caller)
    if edges !== nothing
        push!(edges, li)
    end
    return nothing
end

function add_invoke_backedge!(caller::InferenceState, @nospecialize(invokesig::Type), li::MethodInstance)
    edges = get_stmt_edges!(caller)
    if edges !== nothing
        push!(edges, invokesig, li)
    end
    return nothing
end

# used to temporarily accumulate our no method errors to later add as backedges in the callee method table
function add_mt_backedge!(caller::InferenceState, mt::Core.MethodTable, @nospecialize(typ))
    edges = get_stmt_edges!(caller)
    if edges !== nothing
        push!(edges, mt, typ)
    end
    return nothing
end

function get_stmt_edges!(caller::InferenceState)
    if !isa(caller.linfo.def, Method)
        return nothing # don't add backedges to toplevel exprs
    end
    edges = caller.stmt_edges[caller.currpc]
    if edges === nothing
        edges = caller.stmt_edges[caller.currpc] = []
    end
    return edges
end

function empty_backedges!(frame::InferenceState, currpc::Int = frame.currpc)
    edges = frame.stmt_edges[currpc]
    edges === nothing || empty!(edges)
    return nothing
end

function print_callstack(sv::InferenceState)
    while sv !== nothing
        print(sv.linfo)
        !sv.cached && print("  [uncached]")
        println()
        for cycle in sv.callers_in_cycle
            print(' ', cycle.linfo)
            println()
        end
        sv = sv.parent
    end
end

get_curr_ssaflag(sv::InferenceState) = sv.src.ssaflags[sv.currpc]

function narguments(sv::InferenceState)
    def = sv.linfo.def
    isva = isa(def, Method) && def.isva
    nargs = length(sv.result.argtypes) - isva
    return nargs
end
