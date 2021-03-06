#=
        ScalarAffineFunction -in- LessThan
        ScalarAffineFunction -in- GreaterThan
        ScalarAffineFunction -in- EqualTo
        ScalarAffineFunction -in- Interval
=#
constrdict(model::LinQuadOptimizer, ::LCI{LE})  = cmap(model).less_than
constrdict(model::LinQuadOptimizer, ::LCI{GE})  = cmap(model).greater_than
constrdict(model::LinQuadOptimizer, ::LCI{EQ})  = cmap(model).equal_to
constrdict(model::LinQuadOptimizer, ::LCI{IV})  = cmap(model).interval

function MOI.add_constraint(model::LinQuadOptimizer, func::Linear, set::T) where T <: LinSets
    __assert_supported_constraint__(model, Linear, T)
    canonicalized_func = MOIU.canonical(func)
    add_linear_constraint(model, canonicalized_func, set)
    model.last_constraint_reference += 1
    index = LCI{T}(model.last_constraint_reference)
    dict = constrdict(model, index)
    dict[index] = get_number_linear_constraints(model)
    push!(model.constraint_primal_solution, NaN)
    push!(model.constraint_dual_solution, NaN)
    push!(model.constraint_constant, func.constant)
    return index
end

"""
    add_linear_constraint(model::LinQuadOptimizer, func::Linear, set::S)

Add a constraint of type `func`-in-`set` to `model`.
"""
function add_linear_constraint(model::LinQuadOptimizer, func::Linear, set::S) where S <: Union{LE, GE, EQ}
    add_linear_constraint(model, func, backend_type(model, set), MOIU.getconstant(set))
end

function add_linear_constraint(model::LinQuadOptimizer, func::Linear, set::IV)
    columns = [get_column(model, term.variable_index) for term in func.terms]
    coefficients = [term.coefficient for term in func.terms]
    A = CSRMatrix{Float64}([1, length(coefficients) + 1], columns, coefficients)
    add_ranged_constraints!(model, A, [set.lower], [set.upper])
end

function add_linear_constraint(model::LinQuadOptimizer, func::Linear, sense, rhs::Float64)
    if abs(func.constant) > eps(Float64)
        @warn("Constant in scalar function moved into set.")
    end
    columns = [get_column(model, term.variable_index) for term in func.terms]
    coefficients = [term.coefficient for term in func.terms]
    A = CSRMatrix{Float64}([1, length(coefficients) + 1], columns, coefficients)
    add_linear_constraints!(model, A, [sense], [rhs - func.constant])
end

#=
    Add linear constraints (plural)
=#

function MOI.add_constraints(model::LinQuadOptimizer, func::Vector{Linear},
                             set::Vector{S}) where S <: LinSets
    __assert_supported_constraint__(model, Linear, S)
    @assert length(func) == length(set)
    canonicalized_functions = MOIU.canonical.(func)
    num_existing_constraints = get_number_linear_constraints(model)
    add_linear_constraints(model, canonicalized_functions, set)
    indices = Vector{LCI{S}}(undef, length(canonicalized_functions))
    for (i, foo) in enumerate(canonicalized_functions)
        model.last_constraint_reference += 1
        index = LCI{S}(model.last_constraint_reference)
        dict = constrdict(model, index)
        dict[index] = num_existing_constraints + i
        push!(model.constraint_primal_solution, NaN)
        push!(model.constraint_dual_solution, NaN)
        push!(model.constraint_constant, foo.constant)
        indices[i] = index
    end
    return indices
end

function add_linear_constraints(model::LinQuadOptimizer, functions::Vector{Linear},
                                sets::Vector{S}) where S <: LinSets
    return add_linear_constraints(model, functions,
                                  backend_type.(Ref(model), sets),
                                  MOIU.getconstant.(sets))
end

"""
    functions_to_CSRMatrix(model::LinQuadOptimizer, functions::Vector{Linear}, num_non_zeros::Int)

Convert a vector of ScalarAffineFunctions into a CSRMatrix with `num_non_zeros`
non-zero coefficients.
"""
function functions_to_CSRMatrix(model::LinQuadOptimizer, functions::Vector{Linear}, num_non_zeros::Int)
    columns = Vector{Int}(undef, num_non_zeros)
    coefficients  = Vector{Float64}(undef, num_non_zeros)
    # Compute the row pointers in the compressed sparse row matrix. The row
    # pointers are defined recursively:
    #  r[1] = 1
    #  r[i] = r[i - 1] + (number of nonzero elements in the (i - 1)th row)
    #
    # To compute this, we first count up the number of nonzero elements in each
    # row (i - 1), storing the result in r[i]. Then we perform a cumsum on r,
    # storing the result back in r.
    num_rows = length(functions)
    row_pointers = fill(0, num_rows+1)
    row_pointers[1] = 1
    non_zero_index = 0
    for (row, func) in enumerate(functions)
        for term in func.terms
            non_zero_index += 1
            if non_zero_index > num_non_zeros
                error("There were more non-zero entries in the function than " *
                      "indicated: >$(num_non_zeros).")
            end
            columns[non_zero_index] = get_column(model, term.variable_index)
            coefficients[non_zero_index] = term.coefficient
            if row < num_rows
                row_pointers[row + 1] += 1
            end
        end
    end
    cumsum!(row_pointers, row_pointers)
    row_pointers[end] = length(coefficients)+1
    return CSRMatrix{Float64}(row_pointers, columns, coefficients)
end

function add_linear_constraints(model::LinQuadOptimizer, functions::Vector{Linear}, sets::Vector{IV})
    # loop through once to get number of non-zeros and to move rhs across
    lower_bounds = [set.lower for set in sets]
    upper_bounds = [set.upper for set in sets]
    num_non_zeros = 0
    for (i, func) in enumerate(functions)
        if abs(func.constant) > eps(Float64)
            @warn("Constant in scalar function moved into set.")
            lower_bounds[i] -= func.constant
            upper_bounds[i] -= func.constant
        end
        num_non_zeros += length(func.terms)
    end
    A = functions_to_CSRMatrix(model, functions, num_non_zeros)
    add_ranged_constraints!(model, A, lower_bounds, upper_bounds)
end

function add_linear_constraints(model::LinQuadOptimizer, functions::Vector{Linear},
                                senses::Vector, right_hand_sides::Vector{Float64})
    # loop through once to get number of non-zeros and to move rhs across
    nnz = 0
    for (i, func) in enumerate(functions)
        if abs(func.constant) > eps(Float64)
            @warn("Constant in scalar function moved into set.")
            right_hand_sides[i] -= func.constant
        end
        nnz += length(func.terms)
    end
    A = functions_to_CSRMatrix(model, functions, nnz)
    add_linear_constraints!(model, A, senses, right_hand_sides)
end

#=
    Constraint set of Linear function
=#

function MOI.get(model::LinQuadOptimizer, ::MOI.ConstraintSet, index::LCI{S}) where S <: Union{LE, GE, EQ}
    row = model[index]
    rhs = get_rhs(model, row)
    S(rhs + model.constraint_constant[row])
end

function MOI.get(model::LinQuadOptimizer, ::MOI.ConstraintSet, index::LCI{IV})
    row = model[index]
    lowerbound, upperbound = get_range(model, row)
    return IV(lowerbound + model.constraint_constant[row],
              upperbound + model.constraint_constant[row])
end

#=
    Constraint function of Linear function
=#

function MOI.get(model::LinQuadOptimizer, ::MOI.ConstraintFunction, index::LCI{<: LinSets})
    row = model[index]
    columns, coefficients = get_linear_constraint(model, row)
    terms = map(
        (variable, coefficient)->MOI.ScalarAffineTerm{Float64}(coefficient, variable),
        model.variable_references[columns],
        coefficients
    )
    Linear(terms, model.constraint_constant[row])
end

#=
    Scalar Coefficient Change of Linear Constraint
=#

function MOI.modify(model::LinQuadOptimizer, index::LCI{S}, change::MOI.ScalarCoefficientChange{Float64}) where S <: LinSets
    row = model[index]
    column = get_column(model, change.variable)
    change_matrix_coefficient!(model, row, column, change.new_coefficient)
end

"""
    _replace_with_matching_sparsity!(model::LinQuadOptimizer,
        previous::Linear, replacement::Linear, row)

Internal function, not intended for external use.

Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` have exactly the same sparsity pattern w.r.t. which variables
they include and that both constraint functions are in canonical form (as
returned by `MOIU.canonical()`. Neither assumption is checked within the body
of this function.
"""
function _replace_with_matching_sparsity!(model::LinQuadOptimizer, previous::Linear, replacement::Linear, row)
    rows = fill(row, length(replacement.terms))
    cols = [model.variable_mapping[t.variable_index] for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    change_matrix_coefficients!(model, rows, cols, coefs)
end

"""
    _replace_with_different_sparsity!(model::LinQuadOptimizer,
        previous::Linear, replacement::Linear, row)

Internal function, not intended for external use.

Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` may have different sparsity patterns.

This function (and `_replace_with_matching_sparsity!` above) are necessary
because the LQOI API currently *only* allows linear constraint modification
through the `change_matrix_coefficient!` and `change_matrix_coefficients!`
functions. In order to fully replace a linear constraint, we have to zero out
the current matrix coefficients and then set the new matrix coefficients. When
the sparsity patterns match, the zeroing-out step can be skipped.
"""
function _replace_with_different_sparsity!(model::LinQuadOptimizer, previous::Linear, replacement::Linear, row)
    # First, zero out the old constraint function terms
    rows = fill(row, length(previous.terms))
    cols = [model.variable_mapping[t.variable_index] for t in previous.terms]
    coefs = fill(0.0, length(previous.terms))
    change_matrix_coefficients!(model, rows, cols, coefs)

    # Next, set the new constraint function terms
    rows = fill(row, length(replacement.terms))
    cols = [model.variable_mapping[t.variable_index] for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    change_matrix_coefficients!(model, rows, cols, coefs)
end

MOI.supports(::LinQuadOptimizer, ::MOI.ConstraintFunction, ::Type{LCI{S}}) where {S <: Union{LE, GE, EQ}} = true
function MOI.set(model::LinQuadOptimizer, attr::MOI.ConstraintFunction, CI::LCI{S}, replacement::Linear) where {S <: Union{LE, GE, EQ}}
    previous = MOI.get(model, attr, CI)
    MOIU.canonicalize!(previous)
    replacement = MOIU.canonical(replacement)
    # If the previous and replacement constraint functions have exactly
    # the same sparsity pattern, then we can take a faster path by just
    # passing the replacement terms to the model. But if their sparsity
    # patterns differ, then we need to first zero out the previous terms
    # and then set the replacement terms.
    row = model[CI]
    if _matching_sparsity_pattern(previous, replacement)
        _replace_with_matching_sparsity!(model, previous, replacement, row)
    else
        _replace_with_different_sparsity!(model, previous, replacement, row)
    end
    change_rhs_coefficient!(model, row, get_rhs(model, row) - (replacement.constant - previous.constant))
    model.constraint_constant[model[CI]] = replacement.constant
    return
end

#=
    Change RHS of linear constraint without modifying sense
=#
MOI.supports(::LinQuadOptimizer, ::MOI.ConstraintSet, ::Type{LCI{S}}) where S <: LinSets = true
function MOI.set(model::LinQuadOptimizer, ::MOI.ConstraintSet, index::LCI{S},
                  new_set::S) where S <: Union{LE, GE, EQ}
    row = model[index]
    rhs = MOIU.getconstant(new_set) - model.constraint_constant[row]
    change_rhs_coefficient!(model, model[index], rhs)
end

function MOI.set(model::LinQuadOptimizer, ::MOI.ConstraintSet, index::LCI{IV},
                  new_set::IV)
    row = model[index]
    constant = model.constraint_constant[row]
    modify_ranged_constraints!(model, [model[index]],
        [new_set.lower - constant], [new_set.upper - constant])
end

#=
    Delete a linear constraint
=#

function MOI.delete(model::LinQuadOptimizer, index::LCI{<: LinSets})
    __assert_valid__(model, index)
    delete_constraint_name(model, index)
    dict = constrdict(model, index)
    row = dict[index]
    delete_linear_constraints!(model, row, row)
    deleteat!(model.constraint_primal_solution, row)
    deleteat!(model.constraint_dual_solution, row)
    deleteat!(model.constraint_constant, row)
    # shift all the other references
    shift_references_after_delete_affine!(model, row)
    delete!(dict, index)
end

#=
    Transform scalar constraint
=#

function MOI.transform(model::LinQuadOptimizer, index::LCI{S1}, new_set::S2) where S1 where S2 <: Union{LE, GE, EQ}
    __assert_supported_constraint__(model, Linear, S2)
    dict = constrdict(model, index)
    row = dict[index]
    change_linear_constraint_sense!(model, [row], [backend_type(model, new_set)])
    model.last_constraint_reference += 1
    index_2 = LCI{S2}(model.last_constraint_reference)
    dict_2 = constrdict(model, index_2)
    dict_2[index_2] = row
    delete!(dict, index)
    delete_constraint_name(model, index)
    return index_2
end
